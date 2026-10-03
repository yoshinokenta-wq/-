// public/js/app.js

document.addEventListener('DOMContentLoaded', () => {
  // Elements
  const statusDot = document.getElementById('status-dot');
  const statusText = document.getElementById('status-text');
  const statusSubtext = document.getElementById('status-subtext');
  const startBtn = document.getElementById('start-btn');
  const stopBtn = document.getElementById('stop-btn');
  const meterFill = document.getElementById('meter-fill');
  const thresholdLine = document.getElementById('threshold-line');
  const silenceFill = document.getElementById('silence-fill');
  const silenceProgressText = document.getElementById('silence-progress-text');
  const thresholdSlider = document.getElementById('threshold-slider');
  const thresholdVal = document.getElementById('threshold-val');
  const durationSlider = document.getElementById('duration-slider');
  const durationVal = document.getElementById('duration-val');
  const chatLogs = document.getElementById('chat-logs');
  const waveVisualizer = document.getElementById('wave-visualizer');
  const waveBars = document.querySelectorAll('.wave-bar');
  const vadBadge = document.getElementById('vad-badge');

  // Instances
  let ws = null;
  let player = null;
  let recorder = null;
  let isConnected = false;
  let currentGeminiEntry = null;

  // Initialize Audio Player
  player = new AudioPlayer({
    onPlaybackStateChange: (isPlaying) => {
      if (recorder) {
        recorder.setWaitingForModel(isPlaying);
      }
      if (isPlaying) {
        setIndicatorState('speaking', 'Gemini が発話中...', '音声を受信・再生しています');
        setVisualizerActive(true);
      } else {
        if (isConnected) {
          setIndicatorState('listening', 'リスニング中', 'マイクに向かって話しかけてください');
        }
        setVisualizerActive(false);
      }
    }
  });

  const volumeRmsText = document.getElementById('volume-rms-text');
  const packetsSentText = document.getElementById('packets-sent-text');
  const sampleRateText = document.getElementById('sample-rate-text');
  let packetsSentCount = 0;

  // Initialize Audio Recorder
  recorder = new AudioRecorder({
    silenceThreshold: parseFloat(thresholdSlider.value),
    silenceDurationMs: parseInt(durationSlider.value, 10),

    onAudioData: (base64Data, mimeType) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'audio', data: base64Data, mimeType: mimeType }));
        packetsSentCount++;
        packetsSentText.textContent = packetsSentCount;
      }
    },

    onVolumeChange: (rms) => {
      volumeRmsText.textContent = rms.toFixed(4);
      // Scale RMS (typically 0.00 to ~0.2) to percentage for UI bar (0% - 100%)
      const percentage = Math.min(100, Math.round((rms / 0.15) * 100));
      meterFill.style.width = `${percentage}%`;
    },

    onSpeechStart: () => {
      vadBadge.textContent = '🗣️ 発話検知中';
      vadBadge.className = 'badge badge-voice';
      // If user speaks, stop any leftover audio immediately
      if (player) {
        player.stop();
      }
      setIndicatorState('listening', '発話を検知しました', '音声を送信中...');
    },

    onSilenceProgress: (elapsedMs, maxMs) => {
      const pct = Math.min(100, Math.round((elapsedMs / maxMs) * 100));
      silenceFill.style.width = `${pct}%`;
      if (elapsedMs > 0) {
        silenceProgressText.textContent = `沈黙検知: ${elapsedMs}ms / ${maxMs}ms`;
        vadBadge.textContent = '⏳ 沈黙カウント中';
        vadBadge.className = 'badge badge-silence';
      } else {
        silenceProgressText.textContent = `待機中 (${maxMs}ms無音でターン終了)`;
      }
    },

    onTurnComplete: () => {
      console.log('[App] Silence detected! Sending turn_complete to server.');
      addLogEntry('system', '無音を検知しました。ターンをGeminiへ交代します。');
      vadBadge.textContent = '✨ ターン交代';
      vadBadge.className = 'badge';

      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'turn_complete' }));
      }

      setIndicatorState('silence', 'Gemini の応答待ち...', '無音判定によりターン終了シグナルを送信しました');
    }
  });

  // Slider event listeners
  thresholdSlider.addEventListener('input', (e) => {
    const val = parseFloat(e.target.value);
    thresholdVal.textContent = val.toFixed(3);
    recorder.setSilenceThreshold(val);
    updateThresholdLine(val);
  });

  durationSlider.addEventListener('input', (e) => {
    const val = parseInt(e.target.value, 10);
    durationVal.textContent = `${val} ms`;
    recorder.setSilenceDurationMs(val);
  });

  function updateThresholdLine(threshold) {
    const pos = Math.min(100, Math.round((threshold / 0.15) * 100));
    thresholdLine.style.left = `${pos}%`;
  }
  updateThresholdLine(parseFloat(thresholdSlider.value));

  // Connect WebSocket & start session
  async function startSession() {
    startBtn.disabled = true;
    setIndicatorState('connected', '接続中...', 'サーバーおよびGemini Liveに接続しています');
    addLogEntry('system', 'セッションを開始しています...');

    try {
      // 1. Initialize Player and Recorder
      player.init();
      await recorder.start();

      // 2. Open WebSocket
      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${location.host}/ws`;
      ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        isConnected = true;
        stopBtn.disabled = false;
        packetsSentCount = 0;
        packetsSentText.textContent = '0';
        sampleRateText.textContent = `16.0kHz (${(recorder.audioContext.sampleRate / 1000).toFixed(1)}kHzより変換)`;
        console.log('[App] Connected to server WebSocket');
        addLogEntry('system', `サーバーに接続しました (マイク: ${(recorder.audioContext.sampleRate / 1000).toFixed(1)}kHz → Gemini: 16.0kHz)。Gemini Liveの起動を待機中...`);
      };

      ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          handleServerMessage(data);
        } catch (e) {
          console.error('[App] Failed to parse message from server:', e);
        }
      };

      ws.onclose = (event) => {
        console.log('[App] WebSocket closed:', event.code, event.reason);
        stopSession();
        addLogEntry('system', `切断されました (${event.code})`);
      };

      ws.onerror = (err) => {
        console.error('[App] WebSocket error:', err);
        addLogEntry('system', 'WebSocketエラーが発生しました');
      };
    } catch (err) {
      console.error('[App] Could not start audio/session:', err);
      alert('マイクの初期化に失敗しました。マイクのアクセス許可を確認してください。');
      stopSession();
    }
  }

  function stopSession() {
    isConnected = false;
    startBtn.disabled = false;
    stopBtn.disabled = true;

    if (recorder) {
      recorder.stop();
    }
    if (player) {
      player.stop();
    }
    if (ws) {
      ws.close();
      ws = null;
    }

    meterFill.style.width = '0%';
    silenceFill.style.width = '0%';
    setVisualizerActive(false);
    setIndicatorState('', '未接続', '「会話を開始」ボタンを押してください');
  }

  function handleServerMessage(data) {
    switch (data.type) {
      case 'status':
        addLogEntry('system', data.message);
        break;

      case 'setup_complete':
        addLogEntry('system', data.message);
        setIndicatorState('connected', '接続完了', 'Geminiからの最初の挨拶を待っています...');
        break;

      case 'gemini_response':
        // Interruption
        if (data.interrupted) {
          console.log('[App] Gemini speech was interrupted.');
          player.stop();
          addLogEntry('system', '⚡ 発話の割り込みを検知しました');
          currentGeminiEntry = null;
        }

        // Real-time User speech transcription from Gemini
        if (data.user_transcript && data.user_transcript.length > 0) {
          appendUserTranscript(data.user_transcript);
        }

        // Model Text handling
        if (data.text && data.text.length > 0) {
          appendGeminiText(data.text);
        }

        // Audio chunks - Immediate streaming playback!
        if (data.audio_chunks && data.audio_chunks.length > 0) {
          setIndicatorState('speaking', 'Gemini が発話中...', '音声を受信・再生しています');
          setVisualizerActive(true);

          console.log(`[App] 📥 受信: 音声チャンク=${data.audio_chunks.length}, テキスト='${data.text || ''}' (turn_complete=${data.turn_complete})`);

          data.audio_chunks.forEach((chunk) => {
            player.enqueuePcmChunk(chunk.data);
          });
        }

        // Turn complete
        if (data.turn_complete) {
          player.flush();
          currentGeminiEntry = null;
          currentUserEntry = null;
          if (recorder) {
            recorder.setWaitingForModel(false);
          }
        }
        break;

      case 'error':
        addLogEntry('system', `エラー: ${data.message}`);
        console.error('[App] Server error:', data.message);
        break;

      default:
        console.log('[App] Unhandled message:', data);
    }
  }

  function setIndicatorState(type, title, subtitle) {
    statusDot.className = 'pulsing-dot';
    if (type) statusDot.classList.add(type);
    statusText.textContent = title;
    statusSubtext.textContent = subtitle;
  }

  function setVisualizerActive(active) {
    waveBars.forEach((bar) => {
      if (active) {
        bar.classList.add('active');
      } else {
        bar.classList.remove('active');
      }
    });
  }

  let currentUserEntry = null;

  function addLogEntry(role, text) {
    const entry = document.createElement('div');
    entry.className = `log-entry ${role}`;

    const sender = document.createElement('span');
    sender.className = 'sender';
    sender.textContent = role === 'gemini' ? 'Gemini 3.8 Live' : (role === 'user' ? 'あなた' : 'システム');

    const content = document.createElement('span');
    content.className = 'content';
    content.textContent = text;

    entry.appendChild(sender);
    entry.appendChild(content);

    chatLogs.appendChild(entry);
    chatLogs.scrollTop = chatLogs.scrollHeight;
    return content;
  }

  function appendGeminiText(text) {
    if (!currentGeminiEntry) {
      currentGeminiEntry = addLogEntry('gemini', text);
    } else {
      currentGeminiEntry.textContent += text;
      chatLogs.scrollTop = chatLogs.scrollHeight;
    }
  }

  function appendUserTranscript(text) {
    if (!currentUserEntry) {
      currentUserEntry = addLogEntry('user', text);
    } else {
      currentUserEntry.textContent += text;
      chatLogs.scrollTop = chatLogs.scrollHeight;
    }
  }

  // Button Listeners
  startBtn.addEventListener('click', startSession);
  stopBtn.addEventListener('click', stopSession);
});
