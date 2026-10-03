// public/js/audio-player.js

class AudioPlayer {
  constructor(options = {}) {
    this.audioContext = null;
    this.sampleRate = 24000; // Gemini Live API output sample rate
    this.nextStartTime = 0;
    this.activeNodes = [];
    this.isPlaying = false;
    this.onPlaybackStateChange = options.onPlaybackStateChange || (() => {});

    // Leftover byte from odd-length chunks
    this.leftoverByte = null;

    // Buffer accumulation for smooth streaming without node churn
    this.sampleBuffer = [];
    this.minSamplesToPlay = 1200; // 50ms at 24kHz
    this.flushTimer = null;
  }

  init() {
    if (!this.audioContext) {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      this.audioContext = new AudioContextClass({ latencyHint: 'interactive' });
    }
    if (this.audioContext.state === 'suspended') {
      this.audioContext.resume();
    }
  }

  // Enqueue a base64 encoded 24kHz 16-bit PCM chunk
  enqueuePcmChunk(base64Data) {
    this.init();
    if (!base64Data) return;

    try {
      const binaryString = atob(base64Data);
      const incomingLen = binaryString.length;
      let offset = 0;

      // Check if we had a leftover byte from previous chunk
      let totalBytes;
      let bytes;
      if (this.leftoverByte !== null) {
        totalBytes = incomingLen + 1;
        bytes = new Uint8Array(totalBytes);
        bytes[0] = this.leftoverByte;
        this.leftoverByte = null;
        for (let i = 0; i < incomingLen; i++) {
          bytes[i + 1] = binaryString.charCodeAt(i);
        }
      } else {
        totalBytes = incomingLen;
        bytes = new Uint8Array(totalBytes);
        for (let i = 0; i < incomingLen; i++) {
          bytes[i] = binaryString.charCodeAt(i);
        }
      }

      // If odd number of bytes, save the last byte for next chunk
      if (bytes.length % 2 !== 0) {
        this.leftoverByte = bytes[bytes.length - 1];
        bytes = bytes.subarray(0, bytes.length - 1);
      }

      if (bytes.length === 0) return;

      // Convert 16-bit signed PCM (Little-Endian) to Float32
      const samplesCount = bytes.length / 2;
      const dataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

      for (let i = 0; i < samplesCount; i++) {
        const int16 = dataView.getInt16(i * 2, true); // true = Little-Endian
        this.sampleBuffer.push(int16 / 32768.0);
      }

      // Schedule playback if we have accumulated enough samples
      if (this.sampleBuffer.length >= this.minSamplesToPlay) {
        this._flushBuffer();
      } else {
        // Guarantee playback within 25ms even for small chunks
        if (!this.flushTimer) {
          this.flushTimer = setTimeout(() => {
            this.flushTimer = null;
            this._flushBuffer();
          }, 25);
        }
      }
    } catch (e) {
      console.error('[AudioPlayer] Error decoding/playing PCM audio:', e);
    }
  }

  // Force play any remaining buffered samples
  flush() {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this._flushBuffer();
  }

  _flushBuffer() {
    if (this.sampleBuffer.length === 0 || !this.audioContext) return;

    const samples = new Float32Array(this.sampleBuffer);
    this.sampleBuffer = [];

    const audioBuffer = this.audioContext.createBuffer(1, samples.length, this.sampleRate);
    audioBuffer.getChannelData(0).set(samples);

    const sourceNode = this.audioContext.createBufferSource();
    sourceNode.buffer = audioBuffer;
    sourceNode.connect(this.audioContext.destination);

    const currentTime = this.audioContext.currentTime;

    // If starting a fresh playback or fallen behind, start with tiny 25ms jitter buffer
    if (!this.isPlaying || this.nextStartTime < currentTime) {
      this.nextStartTime = currentTime + 0.025;
      console.log(`[AudioPlayer] 🔊 turn_complete を待たずに即時再生開始 (遅延: ${Math.round((this.nextStartTime - currentTime) * 1000)}ms, サンプル数: ${samples.length})`);
    }

    sourceNode.start(this.nextStartTime);
    this.nextStartTime += audioBuffer.duration;

    this.activeNodes.push(sourceNode);
    this._updatePlaybackState(true);

    sourceNode.onended = () => {
      const index = this.activeNodes.indexOf(sourceNode);
      if (index > -1) {
        this.activeNodes.splice(index, 1);
      }
      if (this.activeNodes.length === 0 && this.sampleBuffer.length === 0) {
        this._updatePlaybackState(false);
      }
    };
  }

  // Stop all active playback immediately (used on interruption)
  stop() {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    this.sampleBuffer = [];
    this.leftoverByte = null;

    for (const node of this.activeNodes) {
      try {
        node.stop();
        node.disconnect();
      } catch (e) {
        // Ignore already stopped nodes
      }
    }
    this.activeNodes = [];
    if (this.audioContext) {
      this.nextStartTime = this.audioContext.currentTime;
    }
    this._updatePlaybackState(false);
  }

  _updatePlaybackState(playing) {
    if (this.isPlaying !== playing) {
      this.isPlaying = playing;
      this.onPlaybackStateChange(playing);
    }
  }
}

window.AudioPlayer = AudioPlayer;
