// InputBetter 官网公共脚本:中英文切换、导航状态、滚动进度、滚动浮现、卡片光斑、跟随指针的柔光。
// 三个页面共用;每页自己的动画在各自的脚本里。
//
// 中英文机制:中文写在 HTML 里(data-i18n 的元素,其文本即中文原文),英文在这里的 en 字典;
// 页面脚本用 IB.i18n.add(en, zh) 追加自己的词条,用 IB.i18n.onChange(fn) 订阅切换。
// 默认跟随浏览器语言;手动切换后记在 localStorage(隐私模式等场景不可用时静默忽略)。
(() => {
  'use strict';
  document.documentElement.classList.add('js');

  // 旧链接 input.0os.io/#firmware 指向首页的刷写区,现在刷写区在 /passport/。
  if (location.pathname === '/' && location.hash === '#firmware') location.replace('/passport/#firmware');

  const en = {
    'doc.title': 'InputBetter — Just say it.',
    'nav.home': 'Home', 'nav.passport': 'Passport', 'nav.support': 'Support',
    'cta.short': 'Download', 'cta.download': 'Download for macOS', 'cta.source': 'View on GitHub',
    'ft.license': 'MIT open source', 'ft.support': 'Support', 'ft.passport': 'Passport',
  };
  const zh = {};
  const listeners = [];
  let lang = '';

  document.querySelectorAll('[data-i18n]').forEach((el) => { zh[el.dataset.i18n] = el.textContent; });
  zh['doc.title'] = document.title;  // 中文标题写在 HTML 的 <title> 里
  document.querySelectorAll('[data-i18n-attr]').forEach((el) => {
    el.dataset.i18nAttr.split(/\s+/).forEach((pair) => { const [attr, key] = pair.split(':'); if (attr && key) zh[key] = el.getAttribute(attr) || ''; });
  });
  try { lang = localStorage.getItem('lang') || ''; } catch { /* 不可用时跟随浏览器 */ }
  if (lang !== 'zh' && lang !== 'en') lang = /^zh/i.test(navigator.language) ? 'zh' : 'en';

  const t = (key) => {
    const table = lang === 'en' ? en : zh;
    return table[key] ?? zh[key] ?? en[key] ?? '';
  };

  function apply() {
    document.documentElement.lang = lang === 'zh' ? 'zh-Hans' : 'en';
    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const v = t(el.dataset.i18n);
      if (v) el.textContent = v;
    });
    document.querySelectorAll('[data-i18n-attr]').forEach((el) => {
      // data-i18n-attr="placeholder:key aria-label:key2"
      el.dataset.i18nAttr.split(/\s+/).forEach((pair) => {
        const [attr, key] = pair.split(':');
        const v = t(key);
        if (attr && v) el.setAttribute(attr, v);
      });
    });
    const title = t('doc.title');
    if (title) document.title = title;
    document.querySelectorAll('.lang').forEach((b) => {
      b.textContent = lang === 'zh' ? 'EN' : '中文';
      b.setAttribute('aria-label', lang === 'zh' ? 'Switch to English' : '切换到中文');
    });
    listeners.forEach((fn) => fn(lang));
  }

  window.IB = {
    get lang() { return lang; },
    t,
    reduceMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
    i18n: {
      add(enTable, zhTable) { Object.assign(en, enTable); if (zhTable) Object.assign(zh, zhTable); },
      onChange(fn) { listeners.push(fn); },
      apply,
    },
    /** 为卡片记录鼠标位置,驱动 CSS 里的跟随光斑。 */
    glow(selector) {
      document.querySelectorAll(selector).forEach((card) => {
        card.addEventListener('pointermove', (e) => {
          const r = card.getBoundingClientRect();
          card.style.setProperty('--x', `${e.clientX - r.left}px`);
          card.style.setProperty('--y', `${e.clientY - r.top}px`);
        });
      });
    },
  };

  document.querySelectorAll('.lang').forEach((b) => b.addEventListener('click', () => {
    lang = lang === 'zh' ? 'en' : 'zh';
    try { localStorage.setItem('lang', lang); } catch { /* 忽略 */ }
    apply();
  }));

  // 跟随指针的一团柔光:只在精确指针、允许动效时开启;用 rAF 缓动,避免直接跟手显得生硬。
  function cursorGlow() {
    if (IB.reduceMotion || !matchMedia('(pointer: fine)').matches) return;
    const backdrop = document.querySelector('.backdrop') || document.body;
    const glow = document.createElement('div');
    glow.className = 'cursor-glow';
    glow.setAttribute('aria-hidden', 'true');
    backdrop.append(glow);
    document.documentElement.classList.add('has-cursor');
    let x = innerWidth / 2, y = innerHeight * 0.35, tx = x, ty = y, raf = 0;
    const move = (e) => { tx = e.clientX; ty = e.clientY; if (!raf) raf = requestAnimationFrame(tick); };
    function tick() {
      raf = 0;
      x += (tx - x) * 0.12;
      y += (ty - y) * 0.12;
      glow.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
      if (Math.abs(tx - x) > 0.5 || Math.abs(ty - y) > 0.5) raf = requestAnimationFrame(tick);
    }
    addEventListener('pointermove', move, { passive: true });
    addEventListener('pointerdown', move, { passive: true });
  }

  // 顶部阅读进度:只给能滚动的页面(首页一屏,不会出现)。
  function scrollProgress() {
    const bar = document.createElement('div');
    bar.className = 'scroll-progress';
    bar.setAttribute('aria-hidden', 'true');
    document.body.append(bar);
    let raf = 0;
    const update = () => {
      raf = 0;
      const max = document.documentElement.scrollHeight - innerHeight;
      bar.style.width = max > 8 ? `${Math.min(100, (scrollY / max) * 100)}%` : '0%';
      bar.style.opacity = max > 8 ? '0.85' : '0';
    };
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(update); };
    addEventListener('scroll', onScroll, { passive: true });
    addEventListener('resize', onScroll, { passive: true });
    update();
  }

  // 页面脚本(defer,排在本脚本之后)注册完词条后再统一应用一次,避免先中文后英文的闪烁。
  addEventListener('DOMContentLoaded', () => {
    apply();

    const nav = document.querySelector('.nav');
    const onScroll = () => nav && nav.classList.toggle('scrolled', scrollY > 8);
    onScroll();
    addEventListener('scroll', onScroll, { passive: true });

    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('visible'); io.unobserve(e.target); } });
    }, { threshold: 0.15, rootMargin: '0px 0px -5% 0px' });
    document.querySelectorAll('.reveal').forEach((el, i) => {
      el.style.transitionDelay = `${(Number(el.dataset.delay) || (i % 3) * 80)}ms`;
      io.observe(el);
    });
    IB.glow('.card');
    cursorGlow();
    scrollProgress();
  });
})();
