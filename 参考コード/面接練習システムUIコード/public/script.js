document.addEventListener('DOMContentLoaded', () => {
  let currentStep = 1;
  const maxSteps = 5;
  let handleClickToSkipRef = null; // スキップ用イベントの保持変数

  const sendBtn = document.getElementById('send-btn');
  const userInput = document.getElementById('user-input');
  const interviewerText = document.getElementById('interviewer-text');
  const avatar = document.querySelector('.interviewer-avatar');
  const evalModal = document.getElementById('eval-modal');
  const settingsModal = document.getElementById('settings-modal');

  if (!sendBtn || !userInput) {
    console.error('送信ボタンまたは入力欄が見つかりません');
    return;
  }

  // ===== すべてのモーダルを閉じる共通関数 =====
  function closeAllModals() {
    const modals = document.querySelectorAll('.modal-overlay');
    modals.forEach(modal => {
      modal.classList.add('hidden');
    });
    // 評価画面スキップ用のクリックイベントが残っていれば解除
    if (handleClickToSkipRef) {
      document.removeEventListener('click', handleClickToSkipRef);
      handleClickToSkipRef = null;
    }
  }

  // ===== ボタン操作のイベント設定 =====

  // 1. 各種モーダルの閉じるボタン（×ボタン）
  document.querySelectorAll('.close-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      closeAllModals();
    });
  });

  // 2. モーダルの背景（黒い部分）をクリックしたときに閉じる
  document.querySelectorAll('.modal-overlay').forEach(overlay => {
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        closeAllModals();
      }
    });
  });

  // 3. タイトルへ戻る・もう一度面接するボタンなどの画面遷移
  const backToTitleBtns = document.querySelectorAll('#back-to-title-btn, .btn-secondary, .back-link');
  backToTitleBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      // 1. すべてのモーダルを閉じる
      closeAllModals();

      // 2. ステップリセット
      currentStep = 1;
      updateUI();

      // 3. 画面の表示切り替え（画面IDが存在する場合）
      const interviewScreen = document.getElementById('interview-screen');
      const titleScreen = document.getElementById('title-screen');
      if (interviewScreen) interviewScreen.classList.add('hidden');
      if (titleScreen) titleScreen.classList.remove('hidden');
    });
  });

  // ===== 送信処理 =====
  function handleSend() {
    const text = userInput.value.trim();
    if (!text) return;

    userInput.value = '';
    sendBtn.disabled = true;

    showThinkingState();

    setTimeout(() => {
      if (currentStep < maxSteps) {
        currentStep++;
        updateUI();
        speakText(`第${currentStep}問目：ご回答ありがとうございます。次の質問に入ります。`);
        sendBtn.disabled = false;
      } else {
        // 5問目完了処理
        showCompletion();
      }
    }, 2000);
  }

  sendBtn.addEventListener('click', (e) => {
    e.preventDefault();
    handleSend();
  });

  userInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  });

  function updateUI() {
    document.querySelectorAll('.step-box').forEach((box, index) => {
      if (index + 1 === currentStep) {
        box.classList.add('active');
      } else {
        box.classList.remove('active');
      }
    });

    const percent = Math.round((currentStep / maxSteps) * 100);
    const fill = document.getElementById('progress-bar-fill');
    const percentText = document.getElementById('progress-percent');
    if (fill) fill.style.width = `${percent}%`;
    if (percentText) percentText.textContent = `${percent}%`;
  }

  function showThinkingState() {
    if (interviewerText) {
      interviewerText.innerHTML = '<span class="thinking">面接官が回答を考えています...</span>';
    }
  }

  function speakText(text) {
    if (interviewerText) {
      interviewerText.textContent = text;
    }
    if (avatar) {
      avatar.classList.add('talking');
      setTimeout(() => {
        avatar.classList.remove('talking');
      }, 3000);
    }
  }

  // ===== 面接完了＆評価画面表示 =====
  function showCompletion() {
    const percentText = document.getElementById('progress-percent');
    const fill = document.getElementById('progress-bar-fill');
    if (fill) fill.style.width = '100%';
    if (percentText) percentText.textContent = '100%';
    if (interviewerText) {
      interviewerText.textContent = 'お疲れ様でした！本日の面接はすべて終了となります。';
    }

    let modalOpened = false;
    const openModal = () => {
      if (modalOpened) return;
      modalOpened = true;
      if (evalModal) {
        evalModal.classList.remove('hidden');
      }
      if (handleClickToSkipRef) {
        document.removeEventListener('click', handleClickToSkipRef);
        handleClickToSkipRef = null;
      }
    };

    // 3秒後に自動表示
    const timer = setTimeout(openModal, 3000);

    // 3秒待たずにクリックで即表示
    handleClickToSkipRef = (e) => {
      if (e.target.tagName === 'BUTTON' || e.target.tagName === 'A') return;
      clearTimeout(timer);
      openModal();
    };

    setTimeout(() => {
      if (handleClickToSkipRef) {
        document.addEventListener('click', handleClickToSkipRef);
      }
    }, 300);
  }
});