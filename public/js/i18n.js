const translations = {};

// 保存されている言語を取得する関数
function getSavedLang() {
  return localStorage.getItem('app_language') || 'ja';
}

window.setLanguage = async function(lang) {
  console.log("i18n: setLanguageが呼ばれました ->", lang);
  try {
    if (!translations[lang]) {
      console.log(`i18n: /locales/${lang}.json を取得しに行きます...`);
      const response = await fetch(`/locales/${lang}.json`);
      if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
      translations[lang] = await response.json();
      console.log("i18n: JSONの取得に成功しました", translations[lang]);
    }

    const dict = translations[lang];

    // data-i18n 属性を持つ要素のテキストを書き換える
    document.querySelectorAll('[data-i18n]').forEach(el => {
      const key = el.getAttribute('data-i18n');
      const text = getNestedValue(dict, key);
      if (text) {
        el.textContent = text;
      }
    });

    localStorage.setItem('app_language', lang);
    
    // セレクトボックスの選択状態を確実に合わせる
    const langSelect = document.getElementById('language-select');
    if (langSelect) {
      langSelect.value = lang;
    }

    document.documentElement.lang = lang;
    console.log("i18n: 言語の切り替えが完了しました ->", lang);

  } catch (error) {
    console.error("i18n: 言語ファイルの読み込みに失敗しました:", error);
  }
};

function getNestedValue(obj, path) {
  return path.split('.').reduce((acc, part) => acc && acc[part], obj);
}

// 外部（行動並び替えなどのスクリプト）から文言を取得するヘルパー
window.getI18nText = function(key) {
  const currentLang = getSavedLang();
  const dict = translations[currentLang];
  return getNestedValue(dict, key) || key;
};

// 共通の初期化・適用処理
function initI18n() {
  const lang = getSavedLang();
  console.log("i18n: 初期化実行 (言語: " + lang + ")");
  window.setLanguage(lang);
}

// 通常のページ読み込み時
document.addEventListener('DOMContentLoaded', initI18n);

// 💡 ブラウザの「戻る」「進む」ボタンでキャッシュからページが復元されたときの対策
window.addEventListener('pageshow', (event) => {
  if (event.persisted) {
    console.log("i18n: ページがキャッシュから復元されました。言語を再適用します。");
    initI18n();
  }
});
