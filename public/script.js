document.addEventListener('DOMContentLoaded', () => {
  const micBtn = document.getElementById('mic-btn');
  const interviewerText = document.getElementById('interviewer-text');
  const avatar = document.querySelector('.interviewer-avatar');
  const mouthImage = document.getElementById('interviewer-mouth');
  const coachPanel = document.getElementById('coach-panel');
  const coachText = document.getElementById('coach-text');
  const modeTitle = document.getElementById('mode-title');
  const difficultyBadge = document.getElementById('difficulty-badge');
  if (!micBtn) return;

  const config = window.INTERVIEW_CONFIG || { mode: 'practice', difficulty: 'normal' };
  const isPracticeMode = config.mode === 'practice';

  const MODE_LABELS = { practice: '練習モード', real: '本番モード' };
  if (modeTitle) modeTitle.textContent = MODE_LABELS[config.mode] || '面接';
  if (difficultyBadge) {
    difficultyBadge.textContent = `難易度：${String(config.difficulty).toUpperCase()}`;
  }

  let isConnected = false;
  let ws = null;
  let mediaStream = null;
  let audioContext = null;
  let recorder = null;
  let player = null;
  let silenceTimer = null;
  let isSpeaking = false;
  let currentResponseText = '';
  let isAITalking = false;
  let mouthTimer = null;
  const mouthFrames = [
    '/images/mouth_1.png',
    '/images/mouth_2.png',
    '/images/mouth_3.png',
    '/images/mouth_4.png',
    '/images/mouth_5.png',
    '/images/mouth_close.png'
  ];

  function setInterviewerMouthState(talking) {
    if (!mouthImage) return;

    if (talking) {
      avatar && avatar.classList.add('talking');
      if (!mouthTimer) {
        mouthTimer = setInterval(() => {
          const randomIndex = Math.floor(Math.random() * mouthFrames.length);
          mouthImage.src = mouthFrames[randomIndex];
        }, 120);
      }
    } else {
      avatar && avatar.classList.remove('talking');
      if (mouthTimer) {
        clearInterval(mouthTimer);
        mouthTimer = null;
      }
      mouthImage.src = '/images/mouth_close.png';
    }
  }

  function showCoachAdvice(advice) {
    if (!coachPanel || !coachText) return;
    coachText.textContent = advice;
    coachPanel.classList.remove('hidden');
  }

  function showEvaluation(result) {
    const modal = document.getElementById('eval-modal');
    if (!modal) return;

    const scoresEl = document.getElementById('eval-score');
    const adviceEl = document.getElementById('eval-advice');
    if (scoresEl) scoresEl.textContent = result.score_text || '評価はありません';
    if (adviceEl) adviceEl.textContent = result.advice_text || '';

    modal.classList.remove('hidden');
  }

  function buildAudioPlayer() {
    return {
      audioContext: null,
      sampleRate: 24000,
      nextStartTime: 0,
      activeNodes: [],
      isPlaying: false,
      leftoverByte: null,
      sampleBuffer: [],
      minSamplesToPlay: 1200,
      flushTimer: null,

      init() {
        if (!this.audioContext) {
          const AudioContextClass = window.AudioContext || window.webkitAudioContext;
          this.audioContext = new AudioContextClass({ latencyHint: 'interactive' });
        }
        if (this.audioContext.state === 'suspended') {
          this.audioContext.resume();
        }
      },

      enqueuePcmChunk(base64Data) {
        this.init();
        if (!base64Data) return;

        try {
          const binaryString = window.atob(base64Data);
          const incomingLen = binaryString.length;
          let bytes;

          if (this.leftoverByte !== null) {
            bytes = new Uint8Array(incomingLen + 1);
            bytes[0] = this.leftoverByte;
            this.leftoverByte = null;
            for (let i = 0; i < incomingLen; i++) {
              bytes[i + 1] = binaryString.charCodeAt(i);
            }
          } else {
            bytes = new Uint8Array(incomingLen);
            for (let i = 0; i < incomingLen; i++) {
              bytes[i] = binaryString.charCodeAt(i);
            }
          }

          if (bytes.length % 2 !== 0) {
            this.leftoverByte = bytes[bytes.length - 1];
            bytes = bytes.subarray(0, bytes.length - 1);
          }

          if (bytes.length === 0) return;

          const samplesCount = bytes.length / 2;
          const dataView = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
          for (let i = 0; i < samplesCount; i++) {
            const int16 = dataView.getInt16(i * 2, true);
            this.sampleBuffer.push(int16 / 32768.0);
          }

          if (this.sampleBuffer.length >= this.minSamplesToPlay) {
            this.flush();
          } else if (!this.flushTimer) {
            this.flushTimer = setTimeout(() => {
              this.flushTimer = null;
              this.flush();
            }, 25);
          }
        } catch (e) {
          console.error('[AudioPlayer] Error decoding/playing PCM audio:', e);
        }
      },

      flush() {
        if (this.flushTimer) {
          clearTimeout(this.flushTimer);
          this.flushTimer = null;
        }
        if (this.sampleBuffer.length === 0 || !this.audioContext) return;

        const samples = new Float32Array(this.sampleBuffer);
        this.sampleBuffer = [];

        const buffer = this.audioContext.createBuffer(1, samples.length, this.sampleRate);
        buffer.getChannelData(0).set(samples);

        const sourceNode = this.audioContext.createBufferSource();
        sourceNode.buffer = buffer;
        sourceNode.connect(this.audioContext.destination);

        const currentTime = this.audioContext.currentTime;
        if (!this.isPlaying || this.nextStartTime < currentTime) {
          this.nextStartTime = currentTime + 0.025;
        }

        sourceNode.start(this.nextStartTime);
        this.nextStartTime += buffer.duration;
        this.activeNodes.push(sourceNode);
        this.isPlaying = true;

        sourceNode.onended = () => {
          const index = this.activeNodes.indexOf(sourceNode);
          if (index > -1) {
            this.activeNodes.splice(index, 1);
          }
          if (this.activeNodes.length === 0 && this.sampleBuffer.length === 0) {
            this.isPlaying = false;
          }
        };
      },

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
        this.isPlaying = false;
      }
    };
  }

  function buildRecorder() {
    return {
      targetSampleRate: 16000,
      mimeType: 'audio/pcm;rate=16000',
      audioContext: null,
      mediaStream: null,
      sourceNode: null,
      processorNode: null,
      silenceThreshold: 0.05,
      silenceDurationMs: 500,
      bufferSize: 2048,
      isRecording: false,
      isSpeaking: false,
      silenceStartTimestamp: null,
      waitingForModel: false,
      preRollChunks: [],
      maxPreRollCount: 6,
      onAudioData: () => {},
      onTurnComplete: () => {},

      async start() {
        if (this.isRecording) return;

        this.mediaStream = await navigator.mediaDevices.getUserMedia({
          audio: {
            channelCount: 1,
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true
          }
        });

        const AudioContextClass = window.AudioContext || window.webkitAudioContext;
        this.audioContext = new AudioContextClass();
        if (this.audioContext.state === 'suspended') {
          await this.audioContext.resume();
        }

        this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream);
        this.processorNode = this.audioContext.createScriptProcessor(this.bufferSize, 1, 1);
        this.processorNode.onaudioprocess = (event) => {
          if (!this.isRecording) return;
          const inputData = event.inputBuffer.getChannelData(0);
          this.process(inputData, event.inputBuffer.sampleRate);
        };

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
      },

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
          this.mediaStream.getTracks().forEach((track) => track.stop());
          this.mediaStream = null;
        }
      },

      process(floatData, actualSampleRate) {
        let sumSquares = 0;
        for (let i = 0; i < floatData.length; i++) {
          sumSquares += floatData[i] * floatData[i];
        }
        const rms = Math.sqrt(sumSquares / floatData.length);

        const resampled = this.downsampleTo16k(floatData, actualSampleRate);
        const pcm16 = new Int16Array(resampled.length);
        for (let i = 0; i < resampled.length; i++) {
          const s = Math.max(-1, Math.min(1, resampled[i]));
          pcm16[i] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
        }

        const base64Audio = this.int16ToBase64(pcm16);
        this.handleVAD(rms, base64Audio);
      },

      handleVAD(rms, base64Audio) {
        const now = Date.now();

        if (this.waitingForModel) {
          if (rms >= this.silenceThreshold * 1.5) {
            this.waitingForModel = false;
            this.isSpeaking = true;
            this.silenceStartTimestamp = null;
            this.onAudioData(base64Audio, this.mimeType);
          }
          return;
        }

        if (rms >= this.silenceThreshold) {
          if (!this.isSpeaking) {
            this.isSpeaking = true;
            this.silenceStartTimestamp = null;
            for (const chunk of this.preRollChunks) {
              this.onAudioData(chunk, this.mimeType);
            }
            this.preRollChunks = [];
          }

          this.silenceStartTimestamp = null;
          this.onAudioData(base64Audio, this.mimeType);
        } else if (this.isSpeaking) {
          if (!this.silenceStartTimestamp) {
            this.silenceStartTimestamp = now;
          }

          const elapsed = now - this.silenceStartTimestamp;
          if (elapsed <= 150) {
            this.onAudioData(base64Audio, this.mimeType);
          }

          if (elapsed >= this.silenceDurationMs) {
            this.isSpeaking = false;
            this.waitingForModel = true;
            this.silenceStartTimestamp = null;
            this.onTurnComplete();
          }
        } else {
          this.preRollChunks.push(base64Audio);
          if (this.preRollChunks.length > this.maxPreRollCount) {
            this.preRollChunks.shift();
          }
        }
      },

      downsampleTo16k(floatData, sampleRate) {
        if (sampleRate === this.targetSampleRate) return floatData;

        const ratio = sampleRate / this.targetSampleRate;
        const outputLength = Math.max(1, Math.floor(floatData.length / ratio));
        const output = new Float32Array(outputLength);

        for (let i = 0; i < outputLength; i++) {
          const sourceIndex = Math.min(floatData.length - 1, Math.floor(i * ratio));
          output[i] = floatData[sourceIndex];
        }
        return output;
      },

      int16ToBase64(pcm16) {
        let binary = '';
        const bytes = new Uint8Array(pcm16.buffer, pcm16.byteOffset, pcm16.byteLength);
        for (let i = 0; i < bytes.length; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        return window.btoa(binary);
      }
    };
  }

  async function startLiveSession() {
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error('このブラウザはマイク機能をサポートしていません');
      }

      player = buildAudioPlayer();
      recorder = buildRecorder();
      recorder.onAudioData = (base64Data, mimeType) => {
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'audio', data: base64Data, mimeType: mimeType }));
        }
      };
      recorder.onTurnComplete = () => {
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'turn_complete' }));
        }
      };

      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, sampleRate: 16000 }
      });

      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${location.host}/ws` +
        `?mode=${encodeURIComponent(config.mode)}` +
        `&difficulty=${encodeURIComponent(config.difficulty)}`;

      ws = new WebSocket(wsUrl);
      ws.onopen = async () => {
        isConnected = true;
        micBtn.classList.add('recording');
        micBtn.style.backgroundColor = '#ff4d4d';
        micBtn.textContent = '通話終了';
        try {
          await recorder.start();
        } catch (err) {
          console.error('[App] Recorder start failed:', err);
          stopLiveSession();
        }
      };

      ws.onmessage = async (event) => {
        let messageData;
        try {
          if (event.data instanceof Blob) {
            messageData = JSON.parse(await event.data.text());
          } else {
            messageData = JSON.parse(event.data);
          }
        } catch (e) {
          console.error('JSONパースエラー:', e);
          return;
        }

        if (isPracticeMode && messageData.type === 'coach_advice' && messageData.advice) {
          showCoachAdvice(messageData.advice);
        }

        if (messageData.type === 'evaluation' && messageData.result) {
          showEvaluation(messageData.result);
        }

        if (messageData.message && !messageData.text && !messageData.audio_chunks) {
          interviewerText.textContent = messageData.message;
        }

        if (messageData.text && messageData.text.trim() !== '') {
          if (!isAITalking) {
            currentResponseText = '';
            isAITalking = true;
          }
          currentResponseText += messageData.text;
          interviewerText.textContent = currentResponseText;
        }

        if (messageData.audio_chunks && Array.isArray(messageData.audio_chunks)) {
          setInterviewerMouthState(true);
          for (const chunk of messageData.audio_chunks) {
            if (chunk && chunk.data) {
              player.enqueuePcmChunk(chunk.data);
            }
          }
        }

        if (messageData.turn_complete) {
          avatar.classList.remove('talking');
          isAITalking = false;
          setInterviewerMouthState(false);
          if (player) player.flush();
        }
      };

      ws.onerror = (err) => {
        console.error('WebSocketエラー:', err);
        stopLiveSession();
      };

      ws.onclose = () => {
        stopLiveSession();
      };
    } catch (e) {
      console.error('マイクの取得または接続に失敗しました:', e);
      alert('マイクの取得または接続に失敗しました: ' + e.message);
      stopLiveSession();
    }
  }

  function stopLiveSession() {
    if (isConnected && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'turn_complete' }));
    }

    isConnected = false;
    micBtn.classList.remove('recording');
    micBtn.style.backgroundColor = '';
    micBtn.textContent = '音声対話スタート';
    avatar.classList.remove('talking');
    isAITalking = false;
    setInterviewerMouthState(false);

    if (silenceTimer) {
      clearTimeout(silenceTimer);
      silenceTimer = null;
    }

    if (recorder) {
      recorder.stop();
      recorder = null;
    }
    if (player) {
      player.stop();
      player = null;
    }
    if (ws) {
      ws.close();
      ws = null;
    }
    if (mediaStream) {
      mediaStream.getTracks().forEach((track) => track.stop());
      mediaStream = null;
    }
  }

  micBtn.addEventListener('click', () => {
    if (!isConnected) {
      startLiveSession();
    } else {
      stopLiveSession();
    }
  });
});
