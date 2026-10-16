// InputBetter 官网:中英文、标题逐字浮现、滚动浮现、卡片光斑、胶囊变形演示。无依赖。
(() => {
  'use strict';
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  document.documentElement.classList.add('js');
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ---------- 中英文 ----------
  // 中文写在 HTML 里,英文在这里;默认跟随浏览器语言,切换后记在本浏览器(localStorage)。
  const en = {
    'cta.short': 'Download', 'cta.download': 'Download for macOS', 'cta.source': 'View Source',
    'hero.title': 'Just say it.', 'hero.lead': 'Local voice input and live bilingual captions for macOS.',
    'demo.typed': 'Typed', 'demo.tag': 'Translating · Chinese',
    'f1.title': 'Dictate anywhere', 'f1.body': 'Hold ⌥ Space and talk. Let go and it’s typed at your cursor. Optional AI polish.',
    'f2.title': 'Any sound, bilingual captions', 'f2.body': 'The original follows the speech; translations land sentence by sentence. Offline system translation, refined by AI.',
    'f2.src': '“The extra thinking solves the hard problems.”', 'f2.tr': '“正是这些额外的思考，解决了难题。”',
    'f3.title': 'One-click summaries', 'f3.body': 'Key points every few minutes, and a full summary when it ends.',
    'f3.p1': 'Reasoning models check many plans', 'f3.p2': 'Extra compute buys the right answer', 'f3.p3': 'A new generation of AI infrastructure',
    'f4.body': 'Hold to talk, Return, Esc, switch apps — and a ping when your agent is done.',
    't1': 'On-device', 't1d': 'Audio never leaves your Mac', 't2': 'Local keys', 't2d': 'Readable only by you',
    't3': 'No history', 't3d': 'Transcripts stay in memory', 't4': 'Open source', 't4d': 'MIT · incl. Passport firmware',
    'dl.title': 'Start talking.',
    'dl.meta': 'Version {{VERSION}} · {{SIZE}} · macOS 26+ · Apple silicon · Signed and notarized by Apple',
    'ft.license': 'MIT open source',
    'stage.idle': 'Always there, never in the way', 'stage.rec': 'Hold ⌥ Space and talk',
    'stage.done': 'Typed where your cursor is', 'stage.cap': 'Any app’s audio, captioned live',
  };
  const zh = { 'stage.idle': '安静地待在屏幕底部', 'stage.rec': '按住 ⌥ 空格说话', 'stage.done': '松开，文字就在光标处', 'stage.cap': '任何应用的声音，实时双语字幕' };
  document.querySelectorAll('[data-i18n]').forEach((el) => { zh[el.dataset.i18n] = el.textContent; });
  let lang = '';
  try { lang = localStorage.getItem('lang') || ''; } catch { /* 隐私模式等情况不可用 */ }
  if (lang !== 'zh' && lang !== 'en') lang = /^zh/i.test(navigator.language) ? 'zh' : 'en';
  const t = (key) => (lang === 'en' ? en : zh)[key] || zh[key] || '';

  // 标题逐字浮现(最后几个字带流光,见 CSS)
  function splitTitle() {
    document.querySelectorAll('[data-split] span[data-i18n]').forEach((el) => {
      const text = el.textContent;
      el.textContent = '';
      [...text].forEach((ch, i) => {
        const s = document.createElement('span');
        s.className = 'ch';
        s.textContent = ch === ' ' ? ' ' : ch;
        s.style.animationDelay = `${0.1 + i * 0.045}s`;
        el.appendChild(s);
      });
    });
  }

  function applyLanguage() {
    document.documentElement.lang = lang === 'zh' ? 'zh-Hans' : 'en';
    document.querySelectorAll('[data-i18n]').forEach((el) => { const v = t(el.dataset.i18n); if (v) el.textContent = v; });
    $('lang').textContent = lang === 'zh' ? 'EN' : '中文';
    document.title = lang === 'zh' ? 'InputBetter — 说出来，就写好了' : 'InputBetter — Just say it.';
    splitTitle();
  }
  $('lang').addEventListener('click', () => {
    lang = lang === 'zh' ? 'en' : 'zh';
    try { localStorage.setItem('lang', lang); } catch { /* 忽略 */ }
    applyLanguage();
    restart();
  });
  applyLanguage();

  // ---------- 滚动浮现与卡片光斑 ----------
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('visible'); io.unobserve(e.target); } });
  }, { threshold: 0.18 });
  document.querySelectorAll('.reveal').forEach((el, i) => { el.style.transitionDelay = `${(i % 2) * 90}ms`; io.observe(el); });
  document.querySelectorAll('.card').forEach((card) => {
    card.addEventListener('pointermove', (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty('--x', `${e.clientX - r.left}px`);
      card.style.setProperty('--y', `${e.clientY - r.top}px`);
    });
  });

  // ---------- 演示 ----------
  const speech = { zh: '明天下午三点开会，记得带上新版设计稿。', en: 'Meeting at 3 pm tomorrow — bring the new design.' };
  const captions = [
    { en: 'Reasoning models think longer and check many plans.', zh: '推理模型思考得更久，会检查多种方案。' },
    { en: 'That extra thinking solves the hard problems.', zh: '正是这些额外的思考，解决了难题。' },
  ];

  // 波形:24 根细条,录音时按包络随机起伏
  const wave = $('wave');
  for (let i = 0; i < 24; i++) wave.appendChild(document.createElement('i'));
  const bars = [...wave.children];
  let waveTimer = 0;
  function animateWave(on) {
    clearInterval(waveTimer);
    if (!on) { bars.forEach((b) => { b.style.height = '4px'; }); return; }
    waveTimer = setInterval(() => {
      bars.forEach((b, i) => {
        const envelope = Math.sin(((i + 1) / (bars.length + 1)) * Math.PI);
        b.style.height = `${4 + Math.random() * 24 * envelope}px`;
      });
    }, 110);
  }

  let generation = 0;
  const alive = (g) => g === generation;

  function setState(state) {
    $('morph').dataset.state = state;
    const label = $('stageLabel');
    label.style.opacity = 0;
    setTimeout(() => { label.textContent = t(`stage.${state}`); label.style.opacity = 1; }, 200);
  }

  // 胶囊:空闲 → 录音(上方浮出识别文字)→ 已输入 → 字幕条(原文逐词、译文逐句)→ 收回
  async function heroLoop(g) {
    const bubble = $('bubble'), src = $('capSrc'), tr = $('capTr');
    while (alive(g)) {
      setState('idle'); bubble.classList.remove('on'); bubble.textContent = '';
      await sleep(1800); if (!alive(g)) return;

      setState('rec'); animateWave(true);
      await sleep(600);
      bubble.classList.add('on');
      const text = speech[lang];
      const step = lang === 'zh' ? 1 : 3;
      for (let i = step; i < text.length + step && alive(g); i += step) {
        bubble.textContent = text.slice(0, i);
        await sleep(lang === 'zh' ? 110 : 90);
      }
      await sleep(500); if (!alive(g)) return;

      animateWave(false); bubble.classList.remove('on'); setState('done');
      await sleep(1700); if (!alive(g)) return;

      src.innerHTML = ''; tr.innerHTML = '';
      setState('cap');
      await sleep(700);
      for (const c of captions) {
        const words = c.en.split(' ');
        for (let i = 1; i <= words.length && alive(g); i++) {
          src.innerHTML = `<div><span class="now">${words.slice(0, i).join(' ')}</span></div>`;
          await sleep(210);
        }
        if (!alive(g)) return;
        src.innerHTML = `<div>${c.en}</div>`;
        await sleep(350);
        tr.innerHTML = `<div><span>${c.zh}</span></div>`;
        await sleep(1600);
      }
      await sleep(900);
    }
  }

  // 卡片里的小输入框:逐字出现
  async function miniLoop(g) {
    const el = $('miniTyped');
    while (alive(g)) {
      el.textContent = '';
      await sleep(900);
      const text = speech[lang];
      for (let i = 1; i <= text.length && alive(g); i++) { el.textContent = text.slice(0, i); await sleep(lang === 'zh' ? 95 : 45); }
      await sleep(2600);
    }
  }

  function restart() {
    generation += 1;
    animateWave(false);
    if (reduceMotion) {
      setState('cap');
      $('capSrc').innerHTML = `<div>${captions[1].en}</div>`;
      $('capTr').innerHTML = `<div><span>${captions[1].zh}</span></div>`;
      $('miniTyped').textContent = speech[lang];
      return;
    }
    heroLoop(generation);
    miniLoop(generation);
  }
  restart();
})();
