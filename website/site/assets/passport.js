// Passport 页:英文词条 + 首屏设备画面轮播(真实固件截图交叉淡入,按键随画面"按下")+ 指针悬停时的轻微倾斜。
// 依赖 main.js 的 IB;刷写逻辑在 flasher.js。
(() => {
  'use strict';

  IB.i18n.add({
    'doc.title': 'Passport — InputBetter',
    'cta.short': 'Download', 'cta.download': 'Download for macOS',
    'nav.home': 'Home', 'nav.passport': 'Passport', 'nav.support': 'Support',
    'ft.license': 'MIT open source', 'ft.support': 'Support',
    'pp.eyebrow': 'Optional companion hardware',
    'pp.title': 'A vibe-coding remote in your hand.',
    'pp.lead': 'Flash the InputBetter firmware onto a FoloToy AI Passport and it becomes a three-button remote with a screen: hold to talk and the words land at your cursor on the Mac; Up is Return, Down is Esc; and it chimes when Claude Code or Codex finishes or needs your input.',
    'pp.flash': 'Flash firmware in your browser',
    'pp.optional': 'No hardware? No problem — InputBetter is complete on its own. Passport is just one more input method for people who like to tinker.',
    'pp.fact1': 'USB-C or Bluetooth', 'pp.fact1d': 'Plug in and go — no pairing',
    'pp.fact2': 'Hints follow your keys', 'pp.fact2d': 'Remap a key and the icon updates',
    'pp.fact3': 'Open-source firmware', 'pp.fact3d': 'MIT, written for this project',
    'pp.k.up': 'Up', 'pp.k.upd': 'Return · hold to switch mode',
    'pp.k.down': 'Down', 'pp.k.downd': 'Esc · hold to switch apps',
    'pp.k.okd': 'Hold to talk',
    'pp.feat.eyebrow': 'What it does', 'pp.feat.title': 'Three keys turn speech into action.',
    'pp.feat.lead': 'The device only reports key presses and renders what the Mac sends. Every meaning is decided by InputBetter on the Mac, so behavior improves with each app update.',
    'pp.c1.t': 'Hold OK to talk', 'pp.c1.d': 'Let go and the text is typed at the Mac’s cursor. Tap once to start and again to stop for hands-free use. The Passport mic can also be your dictation input.',
    'pp.c2.t': 'Up is Return, Down is Esc', 'pp.c2.d': 'The default mapping: Return sends the prompt, Esc interrupts the agent. In Settings › Passport you can switch either to ⌫ Backspace, ⌦ Delete, ⌘Z Undo, Tab, ⇧Tab, ⌘↩, ⌃C, “approve the first option”, or “type the last dictation again”.',
    'pp.c3.t': 'Hold Up to switch mode', 'pp.c3.d': 'Dictate → Translate → Captions, in a loop; the dot-matrix icon rearranges into the new mode and the mode name flips over. In Captions mode, OK starts or stops captions, Up toggles translation and Down collapses the caption bar.',
    'pp.c4.t': 'Hold Down to switch apps', 'pp.c4.d': 'The screen lists the apps running on your Mac. Pick one with Up / Down, confirm with OK, and its window comes to the front with focus. While recording, holding Down cancels the take.',
    'pp.c5.t': 'A chime when the agent is done', 'pp.c5.d': 'Set up Claude Code / Codex hooks with one click in Settings › Vibe Coding. DONE plus a chime when a task finishes; YOUR TURN, repeated every 20 seconds, when it needs your input. Any key dismisses it.',
    'pp.c6.t': 'A dot-matrix screen', 'pp.c6.d': 'The whole screen is drawn with one kind of dot: mode icons, a waveform that moves with your voice, the scanning light while processing and the done state are the same dots, rearranging as you go. It never shows what you said; color is reserved for recording, done and agent alerts. Offline, it’s a dot-matrix clock.',
    'pp.keys.eyebrow': 'Key reference', 'pp.keys.title': 'Default mapping',
    'pp.keys.lead': 'Up and Down actions can be changed in InputBetter’s Settings › Passport; the hint icons next to the keys follow along.',
    'pp.kt.dict': 'Dictate / Translate mode', 'pp.kt.rec': 'While recording', 'pp.kt.sub': 'Captions mode',
    'pp.kt.short': 'tap', 'pp.kt.long': 'hold',
    'pp.kt.r1a': 'Return (send)', 'pp.kt.r1c': 'Toggle translation for this session',
    'pp.kt.r2a': 'Switch mode',
    'pp.kt.r3a': 'Esc (interrupt)', 'pp.kt.r3c': 'Collapse / expand the caption bar',
    'pp.kt.r4a': 'Switch apps', 'pp.kt.r4b': 'Cancel this take',
    'pp.kt.r5a': 'Hold to talk; tap to start', 'pp.kt.r5b': 'Release / tap to finish', 'pp.kt.r5c': 'Start / stop captions',
    'pp.keys.note': 'After an agent alert, the first key press only dismisses the alert and triggers nothing else.',
    'pp.spec.eyebrow': 'Hardware & firmware', 'pp.spec.title': 'Specs',
    'pp.s1': 'SoC', 'pp.s2': 'Storage', 'pp.s3': 'Display', 'pp.s4': 'Keys', 'pp.s4d': 'Three keys (single ADC) + power',
    'pp.s5': 'Audio', 'pp.s5d': 'ES8311 microphone / speaker', 'pp.s6': 'Fuel gauge',
    'pp.s7': 'Connectivity', 'pp.s7d': 'USB-C (USB Serial/JTAG) · Bluetooth LE',
    'pp.s8': 'Mic uplink', 'pp.s8d': '16 kHz mono · IMA ADPCM', 'pp.s9': 'Firmware',
    'pp.s10': 'License', 'pp.s10d': 'MIT (drivers from FoloToy, MIT; icons from Material Icons Round, Apache-2.0)',
    'fw.eyebrow': 'Firmware', 'fw.title': 'Flash firmware in your browser',
    'fw.lead': 'Plug in a USB-C cable and flash right from Chrome or Edge on a computer — nothing to install. Or do it in one click in the InputBetter app under Settings › Passport; both use the same firmware.',
    'fw.s1': 'Hold the power button to turn it on, then connect it with a USB-C data cable',
    'fw.s2': 'Quit the InputBetter app first — it holds the serial port',
    'fw.s3': 'Click “Connect & Flash” and pick Passport in the dialog',
    'fw.note': 'The page first checks that the chip is an ESP32-C3 with 8 MB of flash and that the partition table has Passport’s identity partition; otherwise it stops.',
    'fw.latest': 'Latest firmware', 'fw.start': 'Connect & Flash',
    'fw.backup': 'Back up the full flash first (recommended the first time · 8 MB · 1–3 min · can restore the original firmware)',
    'fw.safe': 'Only the firmware area is written — the flash is never erased and the device identity is left untouched.',
    'scr.idle': 'Idle: current mode and recognition engine', 'scr.rec': 'Holding OK — recording', 'scr.done': 'Released — typed at the Mac’s cursor',
    'scr.sub': 'Captions running, showing the app name', 'scr.list': 'Hold Down — switch apps', 'scr.agentDone': 'Claude Code is done',
    'scr.agentInput': 'The agent is waiting for you', 'scr.offline': 'Not connected to a Mac? It’s a clock.',
  }, {
    'scr.idle': '待机：当前模式与识别引擎', 'scr.rec': '按住 OK，正在录音', 'scr.done': '松开，已输入到 Mac 的光标处',
    'scr.sub': '字幕运行中，显示应用名', 'scr.list': '长按下键：切换应用', 'scr.agentDone': 'Claude Code 完成了',
    'scr.agentInput': 'Agent 在等你确认', 'scr.offline': '没连 Mac 的时候，是一只小时钟',
  });

  // ---------- 设备画面轮播 ----------
  const device = document.getElementById('device');
  const shots = [...document.querySelectorAll('#screen img')];
  const cap = document.getElementById('screenCap');
  let index = 0, timer = 0;

  function show(i) {
    index = i;
    shots.forEach((img, j) => img.classList.toggle('on', j === i));
    const img = shots[i];
    device.dataset.key = img.dataset.key || '';
    device.dataset.screen = img.dataset.screen;
    cap.style.opacity = 0;
    setTimeout(() => { cap.textContent = IB.t(`scr.${img.dataset.screen}`); cap.style.opacity = 1; }, 160);
  }
  function start() {
    clearInterval(timer);
    if (IB.reduceMotion) return;
    timer = setInterval(() => { if (!document.hidden) show((index + 1) % shots.length); }, 2600);
  }
  // 悬停时停在当前画面,方便看清
  device.addEventListener('pointerenter', () => clearInterval(timer));
  device.addEventListener('pointerleave', start);

  // ---------- 指针悬停时的轻微倾斜(手机壳跟着鼠标转一点点) ----------
  const stage = document.getElementById('ppStage');
  if (stage && !IB.reduceMotion && matchMedia('(pointer: fine)').matches) {
    stage.addEventListener('pointermove', (e) => {
      const r = stage.getBoundingClientRect();
      const px = (e.clientX - r.left) / r.width - 0.5;
      const py = (e.clientY - r.top) / r.height - 0.5;
      device.style.setProperty('--ry', `${(px * 9).toFixed(2)}deg`);
      device.style.setProperty('--rx', `${(-py * 7).toFixed(2)}deg`);
    }, { passive: true });
    stage.addEventListener('pointerleave', () => {
      device.style.setProperty('--ry', '0deg');
      device.style.setProperty('--rx', '0deg');
    });
  }

  addEventListener('DOMContentLoaded', () => {
    show(0);
    start();
    IB.i18n.onChange(() => show(index));
  });
})();
