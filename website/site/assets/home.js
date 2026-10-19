// 首页:英文词条 + 照 app 状态胶囊 1:1 做的演示。
//
// 形态与 app 一致(见 app/InputBetter/Pill):idle 细胶囊 → tools 悬停工具条 → rec 录音(红点 + 滚动波形,
// 上方实时文字气泡逐字出现)→ proc 识别中(轨道点 + 流光文字)→ done ✓ 已输入 → cap 展开成字幕条
// (标题栏:应用名 / 翻译目标 / 翻译方式 / 原文行数 / 工具;正文:原文两行、译文两行依次出现)。
// 听写和字幕两个场景循环播放;按住 / 点一下胶囊可以自己玩一遍,之后回到循环。
// 状态只写在 #stage 的 data-state 上,样式在 home.css。
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const stage = $('stage'), pill = $('pill'), bubble = $('bubble');
  const procText = $('procText'), doneText = $('doneText'), hint = $('stageHint'), status = $('pillStatus');
  const capTarget = $('capTarget'), capMethod = $('capMethod'), capLines = $('capLines');
  const capSrc1 = $('capSrc1'), capSrc2 = $('capSrc2'), capDst1 = $('capDst1'), capDst2 = $('capDst2');
  const wave = $('wave'), orbit = $('orbit');

  // 演示文案:中文界面演示英文视频译成中文,英文界面反过来,顺便展示双语字幕
  const demo = {
    zh: {
      live: '帮我把这段会议纪要整理成三点。',
      proc: '识别中', done: '已输入', hint: '按住说话 · 点一下也可以',
      label: '语音输入演示：按住说话，松开输入',
      target: '译 · 中文', method: '系统翻译', lines: '原文 2 行',
      src: ['We have a few puzzle games you could try,', 'and some of them are pretty hard.'],
      dst: ['我们有几个益智游戏你可以试试，', '其中有些还挺难的。'],
    },
    en: {
      live: 'Summarize these meeting notes in three points.',
      proc: 'Transcribing', done: 'Typed', hint: 'Hold to talk — or click',
      label: 'Dictation demo: hold to talk, release to type',
      target: '译 · English', method: 'System', lines: '2 source lines',
      src: ['我们有几个益智游戏你可以试试，', '其中有些还挺难的。'],
      dst: ['We have a few puzzle games you could try,', 'and some of them are pretty hard.'],
    },
  };
  const d = () => demo[IB.lang] || demo.zh;

  IB.i18n.add({
    'doc.title': 'InputBetter — Just say it.',
    'hero.eyebrow': 'Voice input for macOS',
    'hero.title': 'Just say it.',
    'hero.req': 'macOS 26+ · Apple silicon',
    'hero.lede': 'Hold a shortcut and speak — the words land at your cursor. Pick an app and its audio becomes live bilingual captions.',
    'cta.short': 'Download', 'cta.download': 'Download for macOS',
    'nav.passport': 'Passport', 'nav.support': 'Support',
    'meta.line': 'v{{VERSION}} · macOS 26+ · Apple silicon · On-device · MIT open source',
    'geek.title': 'Passport hardware',
    'ft.license': 'MIT open source', 'ft.support': 'Support',
  }, {
    'hero.eyebrow': 'macOS 语音输入',
    'meta.line': 'v{{VERSION}} · macOS 26+ · Apple 芯片 · 本地识别 · MIT 开源',
    'geek.title': 'Passport 硬件',
    'ft.license': 'MIT 开源', 'ft.support': '支持',
  });

  let state = 'idle';
  let mode = 'auto';
  let timers = [];
  let liveTimer = 0, liveStart = 0, waveTimer = 0;
  const levels = Array.from({ length: 23 }, () => 0.2);
  const bars = [];

  function at(ms, fn) { timers.push(setTimeout(fn, ms)); }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function set(next) { state = next; stage.dataset.state = next; }

  // ---------- 波形(每 45 ms 向左滚动一格,和 app 的 WaveformView 一样) ----------
  for (let i = 0; i < 23; i += 1) {
    const bar = document.createElement('i');
    bar.style.setProperty('--h', '0.2');
    wave.append(bar);
    bars.push(bar);
  }
  function waveTick() {
    levels.shift();
    const t = performance.now() / 1000;
    const level = 0.22 + 0.72 * Math.abs(Math.sin(t * 7.2) * Math.cos(t * 2.6)) * (0.55 + Math.random() * 0.45);
    levels.push(Math.min(1, level));
    bars.forEach((bar, i) => bar.style.setProperty('--h', levels[i].toFixed(2)));
  }
  function startWave() { clearInterval(waveTimer); waveTick(); waveTimer = setInterval(waveTick, 45); }
  function stopWave() { clearInterval(waveTimer); waveTimer = 0; }

  // 轨道点(处理中)
  for (let i = 0; i < 6; i += 1) {
    const dot = document.createElement('i');
    dot.style.setProperty('--i', String(i));
    orbit.append(dot);
  }

  // ---------- 文案 ----------
  function render() {
    const t = d();
    procText.textContent = t.proc;
    doneText.textContent = t.done;
    hint.textContent = t.hint;
    capTarget.textContent = t.target;
    capMethod.textContent = t.method;
    capLines.textContent = t.lines;
    capSrc1.textContent = t.src[0];
    capSrc2.textContent = t.src[1];
    capDst1.textContent = t.dst[0];
    capDst2.textContent = t.dst[1];
    pill.setAttribute('aria-label', t.label);
    if (state === 'rec') startLive();
    else if (state !== 'proc') bubble.textContent = t.live;
  }

  // ---------- 实时文字(录音时逐字出现,模拟流式识别) ----------
  function startLive() {
    clearInterval(liveTimer);
    const text = d().live;
    let n = 0;
    bubble.textContent = '';
    liveStart = setTimeout(() => {
      liveTimer = setInterval(() => {
        n += 1;
        bubble.textContent = text.slice(0, n);
        if (n >= text.length) { clearInterval(liveTimer); liveTimer = 0; }
      }, 65);
    }, 220);
  }
  function stopLive() {
    clearTimeout(liveStart);
    clearInterval(liveTimer);
    liveStart = 0;
    liveTimer = 0;
  }

  function enterRec() {
    set('rec');
    startWave();
    startLive();
  }
  function enterProc() {
    stopWave();
    stopLive();
    set('proc');
  }

  // ---------- 自动循环:听写 → 已输入 → 字幕,一遍结束停 1 s 再来 ----------
  function cycle() {
    clearTimers();
    if (IB.reduceMotion) { set('cap'); return; }
    if (document.hidden) { at(2000, cycle); return; }
    set('idle');
    at(900, () => set('tools'));
    at(1600, enterRec);
    at(3300, enterProc);
    at(4200, () => set('done'));
    at(5000, () => set('idle'));
    at(5600, () => set('cap'));
    at(12400, () => set('idle'));
    at(13400, cycle);
  }

  // ---------- 用户按住 / 点击:自己玩一遍 ----------
  function begin() {
    mode = 'manual';
    clearTimers();
    enterRec();
  }
  function finish() {
    if (state !== 'rec') return;
    enterProc();
    at(850, () => set('done'));
    at(1750, () => set('cap'));
    at(7000, () => set('idle'));
    at(11000, () => { if (mode === 'manual') { mode = 'auto'; cycle(); } });
    status.textContent = `${d().done}：${d().live}`;
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
    at(700, finish);
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
  if (IB.reduceMotion) set('cap');
  else cycle();
})();
