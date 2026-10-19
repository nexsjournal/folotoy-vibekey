// 首页:英文词条 + 照 app 状态胶囊 1:1 做的演示。
//
// 使用场景(和 app 一致):光标停在一个输入框里 → 按住快捷键说话 → 胶囊显示滚动波形和实时文字 →
// 松开后识别、处理 → 文字落到输入框的光标处 → 胶囊显示 ✓ 已输入。
// 另一个场景是实时字幕:胶囊展开成字幕条,原文两行、译文三行滚动出现。
// 两个场景循环播放;按住 / 点一下胶囊可以自己玩一遍,之后回到循环。
// 状态只写在 #stage 的 data-state 上,样式在 home.css。
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const stage = $('stage'), pill = $('pill'), bubble = $('bubble');
  const procText = $('procText'), doneText = $('doneText'), status = $('pillStatus');
  const capTargetText = $('capTargetText'), capMethodText = $('capMethodText'), capLinesText = $('capLinesText');
  const capSrcLine = $('capSrcLine'), dstStack = $('dstStack');
  const dictInput = $('dictInput'), dictPh = $('dictPh'), dictText = $('dictText'), dictTitle = $('dictTitle');
  const wave = $('wave'), orbit = $('orbit');
  const screen = document.querySelector('.screen'), cursor = $('demoCursor'), appMenu = $('appMenu'), vidWave = $('vidWave');
  const keycap = $('keycap');

  // 演示文案:中文界面演示英文视频译成中文,英文界面反过来,顺便展示双语字幕
  const demo = {
    zh: {
      live: '帮我把这段会议纪要整理成三点。',
      placeholder: '按住快捷键说话，文字会出现在这里', title: '笔记',
      proc: '识别中', done: '已输入', hint: '按住说话 · 点一下也可以',
      label: '语音输入演示：按住说话，松开输入',
      target: '译 · 中文', method: '系统翻译', lines: '原文 2 行',

    },
    en: {
      live: 'Summarize these meeting notes in three points.',
      placeholder: 'Hold the shortcut and speak — the text lands here', title: 'Notes',
      proc: 'Transcribing', done: 'Typed', hint: 'Hold to talk — or click',
      label: 'Dictation demo: hold to talk, release to type',
      target: '译 · English', method: 'System', lines: '2 source lines',

    },
  };
  const d = () => demo[IB.lang] || demo.zh;

  // 字幕场景的三句台词:原文逐词出现,译文一行行往上滚(和 app 的滚动字幕一样)
  const captionScript = [
    { en: 'We have a few puzzle games you could try,', zh: '我们有几个益智游戏你可以试试，' },
    { en: 'and some of them are pretty hard.', zh: '其中有些还挺难的。' },
    { en: 'Want to play one this weekend?', zh: '这个周末要不要玩一个？' },
  ];
  const captionSource = (line) => (IB.lang === 'en' ? line.zh : line.en);
  const captionTranslation = (line) => (IB.lang === 'en' ? line.en : line.zh);

  IB.i18n.add({
    'doc.title': 'InputBetter — Just say it.',
    'hero.eyebrow': 'Voice input for macOS',
    'hero.title': 'Just say it.',
    'hero.req': 'macOS 26+ · Apple silicon',
    'hero.lede': 'Hold a shortcut and speak — the words land at your cursor. Pick an app and its audio becomes live bilingual captions.',
    'cta.short': 'Download', 'cta.download': 'Download for macOS',
    'nav.passport': 'Passport', 'nav.support': 'Support',
    'meta.line': 'v{{VERSION}} · {{SIZE}} · macOS 26+ · Apple silicon · On-device · MIT open source',
    'geek.title': 'Passport hardware',
    'ft.license': 'MIT open source', 'ft.support': 'Support',
    'menu.title': 'Choose an app’s audio', 'menu.playing': 'Playing',
  }, {
    'hero.eyebrow': 'macOS 语音输入',
    'meta.line': 'v{{VERSION}} · {{SIZE}} · macOS 26+ · Apple 芯片 · 本地识别 · MIT 开源',
    'geek.title': 'Passport 硬件',
    'ft.license': 'MIT 开源', 'ft.support': '支持',
    'menu.title': '选择应用的声音', 'menu.playing': '正在播放',
  });

  let state = 'idle';
  let mode = 'auto';
  let timers = [];
  let liveTimer = 0, liveStart = 0, waveTimer = 0, fieldTimer = 0, headTimer = 0, captionRun = 0;
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

  // 视频里说话人的声波
  for (let i = 0; i < 20; i += 1) {
    const bar = document.createElement('i');
    bar.style.setProperty('--h', (0.3 + 0.7 * Math.abs(Math.sin(i * 1.1))).toFixed(2));
    bar.style.setProperty('--d', `${(-i * 0.05).toFixed(2)}s`);
    vidWave.append(bar);
  }

  // 轨道点(处理中)
  for (let i = 0; i < 6; i += 1) {
    const dot = document.createElement('i');
    dot.style.setProperty('--i', String(i));
    orbit.append(dot);
  }

  // ---------- 输入框:文字最终落到这里 ----------
  function resetInput() {
    clearInterval(fieldTimer);
    fieldTimer = 0;
    dictText.textContent = '';
    dictInput.classList.remove('has-text');
  }
  /** 和 app 把文字粘到光标处一样:处理完后文字逐字落进输入框。 */
  function typeResult() {
    clearInterval(fieldTimer);
    const text = d().live;
    let n = 0;
    dictInput.classList.add('has-text');
    dictText.textContent = '';
    fieldTimer = setInterval(() => {
      n += 1;
      dictText.textContent = text.slice(0, n);
      if (n >= text.length) { clearInterval(fieldTimer); fieldTimer = 0; }
    }, 26);
  }

  // ---------- 文案 ----------
  /** 标题逐字入场:每个字单独裁一段连续的渐变,手机端保持普通标题。 */
  const titleQuery = window.matchMedia('(max-width: 760px)');
  function splitTitle(reflow = false) {
    const h1 = document.querySelector('.hero h1');
    if (!h1) return;
    const text = h1.textContent;
    h1.dataset.text = text;
    if (titleQuery.matches) {
      if (h1.classList.contains('split')) {
        h1.classList.remove('split', 'play');
        h1.textContent = text;
      }
      return;
    }
    h1.textContent = '';
    const chars = [];
    for (const ch of text) {
      if (ch === ' ' || ch === '\n') { h1.append(document.createTextNode(ch)); continue; }
      const span = document.createElement('span');
      span.className = 'char';
      span.textContent = ch;
      h1.append(span);
      chars.push(span);
    }
    h1.classList.add('split');
    h1.classList.remove('play');
    const measure = () => {
      if (!chars.length) return;
      const first = chars[0].getBoundingClientRect();
      const last = chars[chars.length - 1].getBoundingClientRect();
      const width = last.right - first.left;
      if (width <= 0) return;
      h1.style.setProperty('--w', `${width}px`);
      chars.forEach((span, i) => {
        span.style.setProperty('--i', String(i));
        const r = span.getBoundingClientRect();
        span.style.backgroundSize = `${width}px 100%`;
        span.style.setProperty('--off', `${-(r.left - first.left)}px`);
      });
      requestAnimationFrame(refreshTitleFx);
    };
    requestAnimationFrame(measure);
  }

  // ---------- 标题光尘 / 鼠标散开 ----------
  const fx = { el: null, canvas: null, ctx: null, light: null, particles: [], hovered: false, pointer: null, w: 0, h: 0, dpr: 1, sprite: null, raf: 0 };

  function bindTitleFx() {
    const h1 = document.querySelector('.hero h1');
    const el = $('titleFx'), canvas = $('titleCanvas'), light = $('titleLight');
    if (!h1 || !el || !canvas) return;
    fx.el = el; fx.canvas = canvas; fx.light = light;
    fx.ctx = canvas.getContext('2d');
    fx.dpr = Math.min(window.devicePixelRatio || 1, 2);
    fx.sprite = makeParticleSprite();
    h1.addEventListener('pointerenter', (event) => {
      if (!fx.particles.length) return;
      fx.hovered = true;
      fx.pointer = fxPoint(event);
      burstParticles();
      moveLight(fx.pointer);
      if (fx.light) fx.light.style.opacity = '1';
    });
    h1.addEventListener('pointermove', (event) => {
      if (!fx.particles.length) return;
      fx.pointer = fxPoint(event);
      moveLight(fx.pointer);
    });
    h1.addEventListener('pointerleave', () => {
      fx.hovered = false;
      fx.pointer = null;
      if (fx.light) fx.light.style.opacity = '0';
    });
    if (!fx.raf) loopParticles();
  }

  function fxPoint(event) {
    const r = fx.el.getBoundingClientRect();
    return { x: event.clientX - r.left, y: event.clientY - r.top };
  }

  function moveLight(p) {
    if (fx.light) fx.light.style.transform = `translate(${p.x}px, ${p.y}px)`;
  }

  function makeParticleSprite() {
    const c = document.createElement('canvas');
    c.width = c.height = 32;
    const g = c.getContext('2d');
    const gradient = g.createRadialGradient(16, 16, 0, 16, 16, 16);
    gradient.addColorStop(0, 'rgba(255, 255, 255, 1)');
    gradient.addColorStop(0.25, 'rgba(214, 221, 255, 0.9)');
    gradient.addColorStop(0.55, 'rgba(160, 175, 255, 0.35)');
    gradient.addColorStop(1, 'rgba(160, 175, 255, 0)');
    g.fillStyle = gradient;
    g.fillRect(0, 0, 32, 32);
    return c;
  }

  function burstParticles() {
    if (!fx.pointer) return;
    for (const p of fx.particles) {
      const dx = p.x - fx.pointer.x;
      const dy = p.y - fx.pointer.y;
      const d = Math.hypot(dx, dy) || 1;
      const force = 3.4 + Math.random() * 4.6;
      p.vx += (dx / d) * force;
      p.vy += (dy / d) * force;
    }
  }

  /** 从标题字形里采样粒子坐标:粒子组成文字,hover 散开,移出回位。 */
  function sampleTitlePoints(chars) {
    const first = chars[0];
    const last = chars[chars.length - 1];
    const textLeft = first.offsetLeft;
    const textTop = first.offsetTop;
    const width = last.offsetLeft + last.offsetWidth - textLeft;
    const height = Math.max(...chars.map((c) => c.offsetHeight));
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(width * dpr);
    canvas.height = Math.ceil(height * dpr);
    const g = canvas.getContext('2d');
    g.scale(dpr, dpr);
    const style = getComputedStyle(first);
    g.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    g.textAlign = 'left';
    g.textBaseline = 'middle';
    g.fillStyle = '#fff';
    for (const ch of chars) {
      g.fillText(ch.textContent, ch.offsetLeft - textLeft, ch.offsetTop - textTop + ch.offsetHeight / 2);
    }
    const data = g.getImageData(0, 0, canvas.width, canvas.height).data;
    const points = [];
    const step = 3;
    for (let y = 0; y < canvas.height; y += step) {
      for (let x = 0; x < canvas.width; x += step) {
        if (data[(y * canvas.width + x) * 4 + 3] > 110) {
          points.push({ x: x / dpr, y: y / dpr });
        }
      }
    }
    return { points, width, height };
  }

  /** 重新按标题字形排布粒子;跨断点、换语言、窗口缩放时都会重来一次。 */
  function refreshTitleFx() {
    if (!fx.ctx) return;
    const h1 = document.querySelector('.hero h1');
    const chars = h1 ? [...h1.querySelectorAll('.char')] : [];
    const disable = () => {
      h1.classList.remove('fx-ready');
      fx.el.style.display = 'none';
      fx.particles = [];
    };
    if (!chars.length || IB.reduceMotion || window.matchMedia('(max-width: 760px)').matches) {
      disable();
      return;
    }
    fx.el.style.display = '';
    const first = chars[0];
    const last = chars[chars.length - 1];
    const textLeft = first.offsetLeft;
    const textTop = first.offsetTop;
    const textWidth = last.offsetLeft + last.offsetWidth - textLeft;
    const textHeight = Math.max(...chars.map((c) => c.offsetHeight));
    const padX = 54, padTop = 30, padBottom = 30;
    const w = textWidth + padX * 2;
    const h = textHeight + padTop + padBottom;
    fx.el.style.left = `${h1.offsetLeft + textLeft - padX}px`;
    fx.el.style.top = `${h1.offsetTop + textTop - padTop}px`;
    fx.el.style.width = `${w}px`;
    fx.el.style.height = `${h}px`;
    fx.w = w; fx.h = h;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    fx.dpr = dpr;
    fx.canvas.width = Math.round(w * dpr);
    fx.canvas.height = Math.round(h * dpr);
    fx.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const { points } = sampleTitlePoints(chars);
    const area = textWidth * textHeight;
    const baseCount = Math.min(1800, Math.max(650, Math.round(area / 28)));
    const count = window.innerWidth < 1100 ? Math.round(baseCount * 0.7) : baseCount;
    const shuffled = points.slice();
    for (let i = shuffled.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
    }
    fx.particles = shuffled.slice(0, Math.min(count, shuffled.length)).map((pt) => {
      const hx = pt.x + padX;
      const hy = pt.y + padTop;
      return {
        hx, hy,
        x: Math.random() * w,
        y: Math.random() * h,
        vx: 0, vy: 0,
        r: 0.8 + Math.random() * 0.8,
        phase: Math.random() * Math.PI * 2,
        alpha: 0.55 + Math.random() * 0.4,
      };
    });
    h1.classList.add('fx-ready');
    fx.ctx.clearRect(0, 0, w, h);
  }

  let fxLast = 0;
  function loopParticles() {
    fx.raf = requestAnimationFrame(loopParticles);
    const { ctx, sprite } = fx;
    if (!ctx || !sprite || !fx.particles.length) return;
    const now = performance.now();
    if (now - fxLast < 16) return;
    fxLast = now;
    const t = now / 1000;
    ctx.clearRect(0, 0, fx.w, fx.h);
    ctx.globalCompositeOperation = 'lighter';
    for (const p of fx.particles) {
      if (fx.hovered && fx.pointer) {
        const dx = p.x - fx.pointer.x;
        const dy = p.y - fx.pointer.y;
        const d = Math.hypot(dx, dy) || 1;
        if (d < 170) {
          const force = (1 - d / 170) * 0.85;
          p.vx += (dx / d) * force;
          p.vy += (dy / d) * force;
        }
      }
      const tx = p.hx + Math.sin(t * 0.8 + p.phase) * 0.8;
      const ty = p.hy + Math.cos(t * 0.7 + p.phase) * 0.8;
      p.vx += (tx - p.x) * 0.03;
      p.vy += (ty - p.y) * 0.03;
      p.vx *= 0.86;
      p.vy *= 0.86;
      p.x += p.vx;
      p.y += p.vy;
      const flow = 0.72 + 0.28 * Math.sin(p.hx * 0.02 - t * 1.4);
      const twinkle = 0.85 + 0.15 * Math.sin(t * 2 + p.phase);
      ctx.globalAlpha = Math.min(1, p.alpha * flow * twinkle * (fx.hovered ? 1.15 : 1));
      const size = p.r * 5;
      ctx.drawImage(sprite, p.x - size / 2, p.y - size / 2, size, size);
    }
    ctx.globalAlpha = 1;
  }

  function render() {
    const t = d();
    procText.textContent = t.proc;
    doneText.textContent = t.done;
    dictPh.textContent = t.placeholder;
    dictTitle.textContent = t.title;
    capTargetText.textContent = t.target;
    capMethodText.textContent = t.method;
    capLinesText.textContent = t.lines;
    pill.setAttribute('aria-label', t.label);
    if (dictInput.classList.contains('has-text')) {
      clearInterval(fieldTimer);
      fieldTimer = 0;
      dictText.textContent = t.live;
    }
    splitTitle();
    if (state === 'cap') enterCap();
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
    resetInput();
    set('rec');
    startWave();
    startLive();
  }
  function enterProc() {
    stopWave();
    stopLive();
    set('proc');
  }
  function enterDone() {
    set('done');
    typeResult();
  }
  /** 展开字幕条:默认只显示字幕,标题栏只在鼠标悬停时出现(和 app 一样)。 */
  function enterCap() {
    set('cap');
    const run = ++captionRun;
    if (IB.reduceMotion) fillCaptions();
    else playCaptions(run);
  }

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  /** 原文逐字出现,说完一句把译文推进下面的滚动区。 */
  async function playCaptions(run) {
    capSrcLine.textContent = '';
    dstStack.innerHTML = '';
    for (const line of captionScript) {
      if (run !== captionRun) return;
      capSrcLine.textContent = '';
      const text = captionSource(line);
      for (let i = 1; i <= text.length; i += 1) {
        if (run !== captionRun) return;
        capSrcLine.textContent = text.slice(0, i);
        await sleep(18);
      }
      if (run !== captionRun) return;
      await sleep(260);
      if (run !== captionRun) return;
      pushTranslation(captionTranslation(line));
      await sleep(900);
    }
  }

  function fillCaptions() {
    capSrcLine.textContent = captionSource(captionScript[2]);
    dstStack.innerHTML = '';
    captionScript.forEach((line) => {
      const el = document.createElement('span');
      el.className = 'dst-line';
      el.textContent = captionTranslation(line);
      dstStack.append(el);
    });
    updateTranslationColors();
  }

  /** 新译文从下面进,旧的往上滚,只保留三行,亮度按新旧递减。 */
  function pushTranslation(text) {
    const el = document.createElement('span');
    el.className = 'dst-line';
    el.textContent = text;
    dstStack.append(el);
    const lines = [...dstStack.children];
    if (lines.length > 3) {
      const first = lines[0];
      const step = first.getBoundingClientRect().height + 3.8;
      dstStack.style.transform = `translateY(-${step}px)`;
      setTimeout(() => {
        first.remove();
        dstStack.style.transition = 'none';
        dstStack.style.transform = 'none';
        requestAnimationFrame(() => { dstStack.style.transition = ''; });
      }, 360);
    }
    updateTranslationColors();
  }

  function updateTranslationColors() {
    const lines = [...dstStack.children];
    lines.forEach((line, i) => {
      const age = lines.length - 1 - i;
      line.style.color = `rgba(255, 255, 255, ${Math.max(0.6, 1 - age * 0.16).toFixed(2)})`;
    });
  }

  /** 字幕的真实入口:把光标移到胶囊上 → 展开工具条 → 点「录应用声音」→ 选 Chrome → 字幕条出现。 */
  function startCaptionsFlow() {
    resetDemoExtras();
    set('tools');
    const sr = screen.getBoundingClientRect();
    const pr = pill.getBoundingClientRect();
    cursorTo(pr.left - sr.left + pr.width / 2 - 4, pr.top - sr.top - 20);
    cursor.classList.add('on');
    at(420, () => {
      const r = pill.getBoundingClientRect();
      cursorTo(r.left - sr.left + 75, r.top - sr.top + 16);
    });
    at(850, () => {
      cursor.classList.add('click');
      appMenu.classList.add('on');
      at(140, () => cursor.classList.remove('click'));
    });
    at(1400, () => {
      const row = appMenu.querySelector('.menu-row.on');
      if (row) {
        const rr = row.getBoundingClientRect();
        cursorTo(rr.left - sr.left + rr.width / 2 - 6, rr.top - sr.top + rr.height / 2 - 3);
      }
    });
    at(1950, () => {
      cursor.classList.add('click');
      appMenu.classList.remove('on');
      at(140, () => cursor.classList.remove('click'));
    });
    at(2300, () => {
      cursor.classList.remove('on');
      enterCap();
    });
  }
  function cursorTo(x, y) { cursor.style.transform = `translate(${x}px, ${y}px)`; }
  function resetDemoExtras() {
    clearTimeout(headTimer);
    captionRun += 1;
    capSrcLine.textContent = '';
    dstStack.innerHTML = '';
    dstStack.style.transform = 'none';
    cursor.classList.remove('on', 'click');
    appMenu.classList.remove('on');
    keycap.classList.remove('on', 'press');
    stage.classList.remove('show-head');
  }

  // ---------- 自动循环:听写 → 已输入 → 字幕,一遍结束停 1 s 再来 ----------
  function cycle() {
    clearTimers();
    if (IB.reduceMotion) { set('cap'); return; }
    if (document.hidden) { at(2000, cycle); return; }
    resetInput();
    set('idle');
    at(1000, () => keycap.classList.add('on'));
    at(1600, () => keycap.classList.add('press'));
    at(1620, enterRec);
    at(1950, () => keycap.classList.remove('on', 'press'));
    at(3300, enterProc);
    at(4200, enterDone);
    at(5000, () => set('idle'));
    at(5600, startCaptionsFlow);
    at(14800, () => set('idle'));
    at(15800, cycle);
  }

  // ---------- 用户按住 / 点击:自己玩一遍 ----------
  function begin() {
    mode = 'manual';
    clearTimers();
    resetDemoExtras();
    enterRec();
  }
  function finish() {
    if (state !== 'rec') return;
    enterProc();
    at(850, enterDone);
    at(1750, enterCap);
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
  bindTitleFx();
  if (IB.reduceMotion) set('cap');
  else cycle();
})();
