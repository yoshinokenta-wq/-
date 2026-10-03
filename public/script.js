document.addEventListener('DOMContentLoaded', () => {
  const micBtn = document.getElementById('mic-btn');
  const interviewerText = document.getElementById('interviewer-text');
  const avatar = document.querySelector('.interviewer-avatar');
  if (!micBtn) return;

  let isConnected = false;
  let ws = null;
  let audioContext = null;
  let mediaStream = null;
  let audioInputProcessor = null;
  let nextPlayTime = 0;

  // AIの発話文を蓄積・保持するための変数
  let currentResponseText = "";
  let isAITalking = false;

  // 無音検知用の変数
  let silenceTimer = null;
  let isSpeaking = false;

  async function startLiveSession() {
    try {
      mediaStream = await navigator.mediaDevices.getUserMedia({ 
        audio: { channelCount: 1, sampleRate: 16000 } 
      });

      audioContext = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 16000 });
      const source = audioContext.createMediaStreamSource(mediaStream);
      audioInputProcessor = audioContext.createScriptProcessor(4096, 1, 1);
      
      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${location.host}/ws`;
      
      ws = new WebSocket(wsUrl);

      ws.onopen = () => {
        isConnected = true;
        micBtn.classList.add('recording');
        micBtn.style.backgroundColor = '#ff4d4d';
        micBtn.textContent = '通話終了';
        console.log("自サーバーのWebSocketに接続しました");
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
          console.error("JSONパースエラー:", e);
          return;
        }

        console.log("サーバーから受信したデータ:", messageData);

        // ステータスや初期化メッセージの表示（まだAIの返答が始まっていない時）
        if (messageData.message && !messageData.text) {
          interviewerText.textContent = messageData.message;
        }

        // Geminiからの返答テキストを蓄積して表示（ストリーミング対策）
        if (messageData.text && messageData.text.trim() !== "") {
          if (!isAITalking) {
            currentResponseText = "";
            isAITalking = true;
          }
          currentResponseText += messageData.text;
          interviewerText.textContent = currentResponseText;
          avatar.classList.add('talking');
        }

        // 音声データ（audio_chunks配列）の順次再生
        if (messageData.audio_chunks && Array.isArray(messageData.audio_chunks)) {
          for (const chunk of messageData.audio_chunks) {
            if (chunk.data) {
              playAudioChunk(chunk.data);
            }
          }
        }

        // 発話ターンが終了した場合の処理
        if (messageData.turn_complete) {
          avatar.classList.remove('talking');
          isAITalking = false;
        }
      };

      ws.onerror = (err) => {
        console.error("WebSocketエラー:", err);
        stopLiveSession();
      };

      ws.onclose = () => {
        stopLiveSession();
      };

      audioInputProcessor.onaudioprocess = (e) => {
        if (!isConnected || ws.readyState !== WebSocket.OPEN) return;
        const inputData = e.inputBuffer.getChannelData(0);

        // 音量（RMS）を計算して、ユーザーが話しているかを簡易判定
        let sum = 0;
        for (let i = 0; i < inputData.length; i++) {
          sum += inputData[i] * inputData[i];
        }
        let rms = Math.sqrt(sum / inputData.length);

        // 一定以上の音量（声）が検知された場合
        if (rms > 0.012) {
          isSpeaking = true;
          if (silenceTimer) {
            clearTimeout(silenceTimer);
            silenceTimer = null;
          }
        } else if (isSpeaking) {
          // 話した後に無音が続いた場合、1.5秒後に自動で「話し終わり」を通知する
          if (!silenceTimer) {
            silenceTimer = setTimeout(() => {
              if (isConnected && ws && ws.readyState === WebSocket.OPEN) {
                console.log("無音を検知したため、発話終了(turn_complete)を送信します");
                ws.send(JSON.stringify({ type: 'turn_complete' }));
                isSpeaking = false;
              }
              silenceTimer = null;
            }, 1500); // 1.5秒無音で終了とみなす
          }
        }

        const pcm16 = convertFloat32ToInt16(inputData);
        const base64Audio = arrayBufferToBase64(pcm16.buffer);

        const audioMessage = {
          type: "audio",
          data: base64Audio
        };
        ws.send(JSON.stringify(audioMessage));
      };

      source.connect(audioInputProcessor);
      audioInputProcessor.connect(audioContext.destination);

    } catch (e) {
      alert("マイクの取得または接続に失敗しました: " + e.message);
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
    if (silenceTimer) { clearTimeout(silenceTimer); silenceTimer = null; }

    if (ws) { ws.close(); ws = null; }
    if (mediaStream) { mediaStream.getTracks().forEach(t => t.stop()); mediaStream = null; }
    if (audioContext) { audioContext.close(); audioContext = null; }
  }

  micBtn.addEventListener('click', () => {
    if (!isConnected) {
      startLiveSession();
    } else {
      stopLiveSession();
    }
  });

  function convertFloat32ToInt16(buffer) {
    let l = buffer.length;
    let buf = new Int16Array(l);
    for (let i = 0; i < l; i++) {
      let s = Math.max(-1, Math.min(1, buffer[i]));
      buf[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
    }
    return buf;
  }

  function arrayBufferToBase64(buffer) {
    let binary = '';
    let bytes = new Uint8Array(buffer);
    let len = bytes.byteLength;
    for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return window.bota(binary);
  }

  async function playAudioChunk(base64Data) {
    if (!audioContext) return;
    try {
      const binaryString = window.atob(base64Data);
      const len = binaryString.length;
      const bytes = new Uint8Array(len);
      for (let i = 0; i < len; i++) {
        bytes[i] = binaryString.charCodeAt(i);
      }
      
      const pcm16 = new Int16Array(bytes.buffer);
      const float32 = new Float32Array(pcm16.length);
      for (let i = 0; i < pcm16.length; i++) {
        float32[i] = pcm16[i] / (pcm16[i] < 0 ? 0x8000 : 0x7FFF);
      }

      const buffer = audioContext.createBuffer(1, float32.length, 24000);
      buffer.getChannelData(0).set(float32);

      const sourceNode = audioContext.createBufferSource();
      sourceNode.buffer = buffer;
      sourceNode.connect(audioContext.destination);

      const currentTime = audioContext.currentTime;
      if (nextPlayTime < currentTime) {
        nextPlayTime = currentTime;
      }
      sourceNode.start(nextPlayTime);
      nextPlayTime += buffer.duration;
    } catch (e) {
      console.error("音声再生エラー:", e);
    }
  }
});
