// public/js/audio-recorder.js

class AudioRecorder {
  constructor(options = {}) {
    this.targetSampleRate = 16000; // Gemini Live API native requirement
    this.mimeType = 'audio/pcm;rate=16000';
    this.audioContext = null;
    this.mediaStream = null;
    this.sourceNode = null;
    this.processorNode = null;

    // VAD (Voice Activity Detection) configurations
    this.silenceThreshold = options.silenceThreshold || 0.010; // Default sensitive threshold
    this.silenceDurationMs = options.silenceDurationMs || 500; // Duration of silence to trigger turn complete
    this.bufferSize = 2048;

    // State management
    this.isRecording = false;
    this.isSpeaking = false;
    this.silenceStartTimestamp = null;
    this.waitingForModel = false; // When true, pauses streaming so Gemini can speak uninterrupted

    // Pre-roll buffer to prevent cutting off the start of words (~250ms of audio)
    this.preRollChunks = [];
    this.maxPreRollCount = 6;

    // Callbacks
    this.onAudioData = options.onAudioData || (() => {});
    this.onVolumeChange = options.onVolumeChange || (() => {});
    this.onSpeechStart = options.onSpeechStart || (() => {});
    this.onSilenceProgress = options.onSilenceProgress || (() => {});
    this.onTurnComplete = options.onTurnComplete || (() => {});
  }

  async start() {
    if (this.isRecording) return;

    try {
      this.mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true
        }
      });

      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      // Initialize AudioContext at native rate for browser stability
      this.audioContext = new AudioContextClass();
      if (this.audioContext.state === 'suspended') {
        await this.audioContext.resume();
      }

      const nativeRate = this.audioContext.sampleRate;
      console.log(`[AudioRecorder] Native AudioContext: ${nativeRate}Hz -> Resampling to ${this.targetSampleRate}Hz for Gemini`);

      this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream);
      this.processorNode = this.audioContext.createScriptProcessor(this.bufferSize, 1, 1);

      this.processorNode.onaudioprocess = (event) => {
        if (!this.isRecording) return;
        const inputData = event.inputBuffer.getChannelData(0);
        this._processAudioFrame(inputData, event.inputBuffer.sampleRate);
      };

      // Connect through a zero-gain node to avoid feedback into speakers while keeping processor active
      const silenceGain = this.audioContext.createGain();
      silenceGain.gain.value = 0;

      this.sourceNode.connect(this.processorNode);
      this.processorNode.connect(silenceGain);
      silenceGain.connect(this.audioContext.destination);

      this.isRecording = true;
      this.isSpeaking = false;
      this.waitingForModel = false;
      this.silenceStartTimestamp = null;
      this.preRollChunks = [];
    } catch (err) {
      console.error('[AudioRecorder] Failed to start microphone:', err);
      throw err;
    }
  }

  stop() {
    this.isRecording = false;
    this.isSpeaking = false;
    this.waitingForModel = false;
    this.silenceStartTimestamp = null;
    this.preRollChunks = [];

    if (this.processorNode) {
      this.processorNode.disconnect();
      this.processorNode = null;
    }
    if (this.sourceNode) {
      this.sourceNode.disconnect();
      this.sourceNode = null;
    }
    if (this.audioContext && this.audioContext.state !== 'closed') {
      this.audioContext.close();
      this.audioContext = null;
    }
    if (this.mediaStream) {
      this.mediaStream.getTracks().forEach((t) => t.stop());
      this.mediaStream = null;
    }
  }

  setSilenceThreshold(val) {
    this.silenceThreshold = parseFloat(val);
  }

  setSilenceDurationMs(val) {
    this.silenceDurationMs = parseInt(val, 10);
  }

  // Called when Gemini starts or finishes speaking
  setWaitingForModel(waiting) {
    this.waitingForModel = waiting;
    if (!waiting) {
      this.isSpeaking = false;
      this.silenceStartTimestamp = null;
    }
  }

  _processAudioFrame(floatData, actualSampleRate) {
    // 1. Calculate RMS volume
    let sumSquares = 0;
    for (let i = 0; i < floatData.length; i++) {
      sumSquares += floatData[i] * floatData[i];
    }
    const rms = Math.sqrt(sumSquares / floatData.length);
    this.onVolumeChange(rms);

    // 2. High-quality box-accumulation resampling to 16,000Hz (anti-aliased)
    const resampled = this._downsampleTo16k(floatData, actualSampleRate);

    // 3. Convert to 16-bit linear PCM (little-endian)
    const pcm16 = new Int16Array(resampled.length);
    for (let i = 0; i < resampled.length; i++) {
      const s = Math.max(-1, Math.min(1, resampled[i]));
      pcm16[i] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
    }

    const base64Audio = this._int16ToBase64(pcm16);

    // 4. Voice Activity Detection & Stream transmission
    this._handleVAD(rms, base64Audio);
  }

  _handleVAD(rms, base64Audio) {
    const now = Date.now();

    // If waiting for Gemini to respond or speak, allow interruption only if user speaks clearly
    if (this.waitingForModel) {
      if (rms >= this.silenceThreshold * 1.5) {
        // User interrupted!
        this.waitingForModel = false;
        this.isSpeaking = true;
        this.silenceStartTimestamp = null;
        this.onSpeechStart();
        this.onAudioData(base64Audio, this.mimeType);
      }
      return;
    }

    if (rms >= this.silenceThreshold) {
      // User is speaking!
      if (!this.isSpeaking) {
        this.isSpeaking = true;
        this.silenceStartTimestamp = null;
        this.onSpeechStart();

        // Flush pre-roll chunks so we never cut off the first phoneme
        for (const chunk of this.preRollChunks) {
          this.onAudioData(chunk, this.mimeType);
        }
        this.preRollChunks = [];
      }

      this.silenceStartTimestamp = null;
      this.onSilenceProgress(0, this.silenceDurationMs);

      // Transmit active voice chunk
      this.onAudioData(base64Audio, this.mimeType);
    } else {
      // Below threshold (silence or trail-off)
      if (this.isSpeaking) {
        if (!this.silenceStartTimestamp) {
          this.silenceStartTimestamp = now;
        }

        const elapsed = now - this.silenceStartTimestamp;
        this.onSilenceProgress(elapsed, this.silenceDurationMs);

        // Keep sending audio during the first 150ms of silence to capture word endings
        if (elapsed <= 150) {
          this.onAudioData(base64Audio, this.mimeType);
        }

        if (elapsed >= this.silenceDurationMs) {
          // Silence threshold reached! User finished speaking this turn.
          console.log('[AudioRecorder] Silence detected. Turn finished. Signaling activityEnd to Gemini.');
          this.isSpeaking = false;
          this.waitingForModel = true; // Pause audio streaming so Gemini can speak uninterrupted
          this.silenceStartTimestamp = null;
          this.onSilenceProgress(this.silenceDurationMs, this.silenceDurationMs);
          this.onTurnComplete();
        }
      } else {
        // Idle silence: keep short pre-roll buffer in memory, do NOT send empty noise
        this.preRollChunks.push(base64Audio);
        if (this.preRollChunks.length > this.maxPreRollCount) {
          this.preRollChunks.shift();
        }
        this.onSilenceProgress(0, this.silenceDurationMs);
      }
    }
  }

  // Anti-aliased decimation resampler to 16,000Hz
  _downsampleTo16k(inputData, inputSampleRate) {
    if (inputSampleRate === this.targetSampleRate) {
      return inputData;
    }

    const ratio = inputSampleRate / this.targetSampleRate;
    const newLength = Math.round(inputData.length / ratio);
    const result = new Float32Array(newLength);
    let offsetResult = 0;
    let offsetBuffer = 0;

    while (offsetResult < result.length) {
      const nextOffsetBuffer = Math.round((offsetResult + 1) * ratio);
      let accum = 0;
      let count = 0;
      for (let i = offsetBuffer; i < nextOffsetBuffer && i < inputData.length; i++) {
        accum += inputData[i];
        count++;
      }
      result[offsetResult] = count > 0 ? accum / count : 0;
      offsetResult++;
      offsetBuffer = nextOffsetBuffer;
    }

    return result;
  }

  _int16ToBase64(int16Array) {
    const bytes = new Uint8Array(int16Array.buffer, int16Array.byteOffset, int16Array.byteLength);
    let binary = '';
    const len = bytes.length;
    for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }
}

window.AudioRecorder = AudioRecorder;
