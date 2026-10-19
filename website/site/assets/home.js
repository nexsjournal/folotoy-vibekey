// 首页:英文词条 + 照 app 状态胶囊 1:1 做的演示。
//
// 形态与 app 一致(见 app/InputBetter/Pill):idle 细胶囊 → tools 悬停工具条 → rec 录音(红点 + 波形,上方实时文字气泡)
// → proc 识别中(轨道点 + 流光文字)→ done ✓ 已输入 → cap 展开成字幕条(原文 + 译文)。
// 进页面约 0.8 s 后自己演示一遍,之后停在细胶囊;按住 / 点一下胶囊可以随时再演一次。
// 状态只写在 #stage 的 data-state 上,样式在 home.css;这里只管时序与文案。
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const stage = $('stage'), pill = $('pill'), bubble = $('bubble');
  const procText = $('procText'), doneText = $('doneText'), capChip = $('capChip');
  const capSrc = $('capSrc'), capDst = $('capDst'), stageHint = $('stageHint'), status = $('pillStatus');
  const wave = $('wave'), orbit = $('orbit');

  // 演示文案:原文 / 译文按当前界面语言互换,同时演示双语字幕
  const demo = {
    zh: {
      bubble: '帮我把这段会议纪要整理成三点。',
      proc: '正在识别…', done: '已输入', hint: '按住说话 · 点一下也可以',
      label: '语音输入演示：按住说话，松开输入',
      chip: '译 · 中文',
      src: 'We have a few puzzle games you could try.',
      dst: '我们有几个益智游戏你可以试试，其中有些还挺难的。',
    },
    en: {
      bubble: 'Summarize these meeting notes in three points.',
      proc: 'Recognizing…', done: 'Typed', hint: 'Hold to talk — or click',
      label: 'Dictation demo: hold to talk, release to type',
      chip: '译 · English',
      src: '我们有几个益智游戏你可以试试。',
      dst: 'Some of these puzzle games are pretty hard.',
    },
  };
  const d = () => demo[IB.lang] || demo.zh;

  IB.i18n.add({
    'doc.title': 'InputBetter — Just say it.',
    'hero.title': 'Just say it.',
    'hero.req': 'macOS 26+ · Apple silicon',
    'hero.lede': 'Hold a shortcut and speak — the words land at your cursor. Pick an app and its audio becomes live bilingual captions.',
    'cta.short': 'Download', 'cta.download': 'Download for macOS',
    'nav.passport': 'Passport', 'nav.support': 'Support',
    'meta.line': 'v{{VERSION}} · macOS 26+ · Apple silicon · On-device · MIT open source',
    'geek.title': 'Passport hardware',
    'geek.sub': 'Optional hardware for tinkerers',
  }, {
    'meta.line': 'v{{VERSION}} · macOS 26+ · Apple 芯片 · 本地识别 · MIT 开源',
    'geek.title': 'Passport 硬件',
    'geek.sub': '可选的配套硬件，给爱折腾的人',
  });

  let state = 'idle';
  let timers = [];
  let interacted = false;

  function at(ms, fn) { timers.push(setTimeout(fn, ms)); }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function set(next) {
    state = next;
    stage.dataset.state = next;
  }

  // ---------- 波形与轨道点 ----------
  for (let i = 0; i < 23; i += 1) {
    const bar = document.createElement('i');
    const h = 0.24 + 0.76 * Math.abs(Math.sin(i * 0.9 + 0.4) * Math.cos(i * 0.37));
    bar.style.setProperty('--h', h.toFixed(2));
    bar.style.setProperty('--d', `${(-i * 0.045).toFixed(2)}s`);
    bar.style.setProperty('--dur', `${(0.45 + (i % 5) * 0.08).toFixed(2)}s`);
    wave.append(bar);
  }
  for (let i = 0; i < 6; i += 1) {
    const dot = document.createElement('i');
    dot.style.setProperty('--i', String(i));
    orbit.append(dot);
  }

  // ---------- 文案 ----------
  function render() {
    const t = d();
    bubble.textContent = t.bubble;
    procText.textContent = t.proc;
    doneText.textContent = t.done;
    stageHint.textContent = t.hint;
    capChip.textContent = t.chip;
    capSrc.textContent = t.src;
    capDst.textContent = t.dst;
    pill.setAttribute('aria-label', t.label);
  }

  // ---------- 演示时序 ----------
  function autoDemo() {
    if (IB.reduceMotion || document.hidden || interacted) return;
    at(800, () => { if (!interacted) set('tools'); });
    at(1700, () => { if (!interacted) set('rec'); });
    at(3000, () => { if (!interacted) set('proc'); });
    at(3900, () => { if (!interacted) set('done'); });
    at(4700, () => { if (!interacted) set('cap'); });
  }

  function begin() {
    interacted = true;
    clearTimers();
    set('rec');
  }

  function finish() {
    if (state !== 'rec') return;
    clearTimers();
    set('proc');
    at(850, () => set('done'));
    at(1750, () => set('cap'));
    status.textContent = `${d().done}：${d().bubble}`;
  }

  // ---------- 事件 ----------
  pill.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    try { pill.setPointerCapture(e.pointerId); } catch { /* 不支持捕获时不影响使用 */ }
    begin();
  });
  pill.addEventListener('pointerup', (e) => {
    try { if (pill.hasPointerCapture(e.pointerId)) pill.releasePointerCapture(e.pointerId); } catch { /* 已释放 */ }
    finish();
  });
  pill.addEventListener('pointercancel', finish);

  // 键盘 / 读屏软件直接触发的点击(鼠标与触屏的点击 detail > 0,在 pointerup 时已经处理过)
  pill.addEventListener('click', (e) => {
    if (e.detail !== 0) return;
    begin();
    at(600, finish);
  });
  pill.addEventListener('keydown', (e) => {
    if (e.key !== ' ' && e.key !== 'Enter') return;
    if (e.repeat) return;
    e.preventDefault();
    begin();
  });
  pill.addEventListener('keyup', (e) => {
    if (e.key !== ' ' && e.key !== 'Enter') return;
    e.preventDefault();
    finish();
  });

  IB.i18n.onChange(render);
  render();
  autoDemo();
})();
