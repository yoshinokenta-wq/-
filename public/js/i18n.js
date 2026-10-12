const translations = {};
let currentLang = localStorage.getItem('app_language') || 'ja';

async function setLanguage(lang) {
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

    currentLang = lang;
    localStorage.setItem('app_language', lang);
    
    const langSelect = document.getElementById('language-select');
    if (langSelect) {
      langSelect.value = lang;
    } else {
      console.warn("i18n: #language-select が見つかりませんでした。");
    }

    document.documentElement.lang = lang;
    console.log("i18n: 言語の切り替えが完了しました ->", lang);

  } catch (error) {
    console.error("i18n: 言語ファイルの読み込みに失敗しました:", error);
  }
}

function getNestedValue(obj, path) {
  return path.split('.').reduce((acc, part) => acc && acc[part], obj);
}

document.addEventListener('DOMContentLoaded', () => {
  console.log("i18n: DOMContentLoaded 初期化開始 (言語: " + currentLang + ")");
  setLanguage(currentLang);

  const langSelect = document.getElementById('language-select');
  if (langSelect) {
    langSelect.addEventListener('change', (e) => {
      console.log("i18n: セレクトボックスが変更されました ->", e.target.value);
      setLanguage(e.target.value);
    });
  } else {
    console.warn("i18n: ⚠️ HTML内に #language-select が存在しません！");
  }
});