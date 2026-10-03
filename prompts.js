document.addEventListener('DOMContentLoaded', () => {
  const micBtn = document.getElementById('mic-btn');
  const userInput = document.getElementById('user-input');

  if (!micBtn || !userInput) return;

  // ブラウザの音声認識 API (Web Speech API) のサポートチェック
  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  if (!SpeechRecognition) {
    micBtn.addEventListener('click', () => {
      alert('お使いのブラウザは音声認識に対応していません。ChromeまたはEdgeをご利用ください。');
    });
    return;
  }

  const recognition = new SpeechRecognition();
  recognition.lang = 'ja-JP';
  recognition.interimResults = true; // 途中経過を表示
  recognition.continuous = true;     // 連続認識

  let isRecording = false;

  // マイクボタンクリックで録音のON/OFF切り替え
  micBtn.addEventListener('click', () => {
    if (!isRecording) {
      try {
        recognition.start();
        isRecording = true;
        micBtn.classList.add('recording');
        micBtn.style.backgroundColor = '#ff4d4d';
        micBtn.textContent = '⏹️'; // 停止アイコンに変更
      } catch (err) {
        console.error('音声認識の開始エラー:', err);
      }
    } else {
      recognition.stop();
      isRecording = false;
      micBtn.classList.remove('recording');
      micBtn.style.backgroundColor = '';
      micBtn.textContent = '🎤';
    }
  });

  // 音声認識の結果が得られたとき
  recognition.onresult = (event) => {
    let transcript = '';
    for (let i = event.resultIndex; i < event.results.length; i++) {
      transcript += event.results[i][0].transcript;
    }
    userInput.value = transcript;
  };

  // エラー処理
  recognition.onerror = (event) => {
    console.error('音声認識エラー:', event.error);
    isRecording = false;
    micBtn.classList.remove('recording');
    micBtn.style.backgroundColor = '';
    micBtn.textContent = '🎤';
  };

  // 音声認識が終了したとき
  recognition.onend = () => {
    if (isRecording) {
      // 途中で切れた場合は自動再開（連続入力のため）
      try {
        recognition.start();
      } catch (e) {
        isRecording = false;
        micBtn.classList.remove('recording');
        micBtn.style.backgroundColor = '';
        micBtn.textContent = '🎤';
      }
    }
  };
});
