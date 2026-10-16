// Passport 网页刷写:Web Serial + Espressif 官方的 esptool-js(本站自带一份,不加载外部资源)。
//
// 为什么不用 ESP Web Tools:它在「全新安装」时默认擦除整片 Flash,会抹掉 Passport 的设备身份数据(cardid 分区)。
// 这里只做 app 里同样的事:
//   1. 选择串口(必须在点击里直接调用);
//   2. 从 /firmware/manifest.json 取最新固件,逐个下载镜像并校验大小与 SHA-256;
//   3. 连接下载模式,确认芯片是 ESP32-C3、Flash 是 8 MB、分区表里有 cardid(0x356000),否则停止;
//   4. 可选:先读出整片 8 MB Flash 存成文件(可用于恢复原固件);
//   5. 只按清单地址分段写入(eraseAll: false,flash 参数 keep),每段都必须落在 cardid 之前;
//   6. 硬复位,设备重启进入新固件。
const ESPTOOL_URL = '/assets/vendor/esptool-js-0.7.0.js';
const MANIFEST_URL = '/firmware/manifest.json';
const CARDID_START = 0x356000;
const FLASH_BYTES = 0x800000;
const ESPRESSIF_VID = 0x303a;

const $ = (id) => document.getElementById(id);
const ui = { version: $('fwVersion'), start: $('fwStart'), backup: $('fwBackup'), bar: $('fwBar'), progress: $('fwProgress'), status: $('fwStatus') };

// 动态状态文字;静态文字在 HTML 里(data-i18n,由 main.js 切换语言)。
const strings = {
  zh: {
    unsupported: '当前浏览器不支持 Web Serial。请用电脑上的 Chrome 或 Edge 打开本页。',
    insecure: '网页刷写只能在 HTTPS 页面使用。',
    noManifest: '暂时无法获取固件，请稍后再试。',
    fetching: '正在下载固件…',
    connecting: '正在连接设备的下载模式…',
    busy: '串口被占用。请先退出 InputBetter app 或其他串口工具，再试一次。',
    wrongChip: '这不是 AI Passport（芯片是 {chip}），已停止。',
    wrongSize: '这台设备的 Flash 不是 8 MB（{size}），已停止。',
    notPassport: '没有在这台设备上找到 Passport 的身份分区，为安全起见已停止。',
    backingUp: '正在备份整片 Flash… {p}%',
    backupSaved: '备份已保存为 {file}，请妥善保管（含设备身份数据，不要分享）。',
    writing: '正在写入固件… {p}%',
    restarting: '正在重启设备…',
    done: '完成！Passport 已运行 InputBetter 固件 {version}。打开 InputBetter app 即可使用。',
    failed: '刷写失败：{msg}',
    badManifest: '固件清单有误（{msg}），已停止。',
    checksum: '下载的 {file} 校验不通过，请重试。',
    leave: '正在刷写固件，离开页面可能导致设备无法启动。',
  },
  en: {
    unsupported: 'This browser doesn’t support Web Serial. Open this page in Chrome or Edge on a computer.',
    insecure: 'Web flashing only works on HTTPS pages.',
    noManifest: 'Firmware is unavailable right now. Please try again later.',
    fetching: 'Downloading firmware…',
    connecting: 'Connecting to the device’s download mode…',
    busy: 'The serial port is in use. Quit the InputBetter app or any serial tool, then try again.',
    wrongChip: 'This isn’t an AI Passport (chip: {chip}). Stopped.',
    wrongSize: 'This device doesn’t have 8 MB of flash ({size}). Stopped.',
    notPassport: 'Couldn’t find the Passport identity partition on this device. Stopped to be safe.',
    backingUp: 'Backing up the full flash… {p}%',
    backupSaved: 'Backup saved as {file}. Keep it safe — it contains the device identity, don’t share it.',
    writing: 'Writing firmware… {p}%',
    restarting: 'Restarting the device…',
    done: 'Done! Passport is running InputBetter firmware {version}. Open the InputBetter app to use it.',
    failed: 'Flashing failed: {msg}',
    badManifest: 'The firmware manifest is invalid ({msg}). Stopped.',
    checksum: 'The downloaded {file} failed verification. Please try again.',
    leave: 'Firmware is being written. Leaving now may leave the device unable to boot.',
  },
};
const tr = (key, vars = {}) => {
  const table = document.documentElement.lang.startsWith('zh') ? strings.zh : strings.en;
  return Object.entries(vars).reduce((s, [k, v]) => s.replaceAll(`{${k}}`, v), table[key]);
};

/** 显示一行状态;kind 为 'error' / 'ok' 时换颜色。progress 为 0...1 时显示进度条,null 隐藏。 */
function setStatus(message, { kind = '', progress = null } = {}) {
  ui.status.textContent = message;
  ui.status.dataset.kind = kind;
  ui.progress.hidden = progress === null;
  if (progress !== null) ui.bar.style.width = `${Math.round(progress * 100)}%`;
}

class FlashError extends Error {}

// ---------- 固件清单(与 app 的 FirmwareManifest 同样的校验规则) ----------
const SAFE_PATH = /^[A-Za-z0-9_+-][A-Za-z0-9._+-]*(\/[A-Za-z0-9_+-][A-Za-z0-9._+-]*)*$/;

async function fetchManifest() {
  const res = await fetch(MANIFEST_URL, { cache: 'no-store' });
  if (!res.ok) throw new FlashError(tr('noManifest'));
  return res.json();
}

/** 校验清单并返回按地址排序的镜像列表;任何一项不合规都整体拒绝。 */
function partsOf(manifest) {
  const bad = (msg) => { throw new FlashError(tr('badManifest', { msg })); };
  if (manifest.chip !== 'ESP32-C3') bad(`chip ${manifest.chip}`);
  if (!Array.isArray(manifest.images) || manifest.images.length === 0) bad('no images');
  const parts = manifest.images.map((img) => {
    if (!/^0x[0-9a-f]+$/i.test(img.offset)) bad(`offset ${img.offset}`);
    const offset = parseInt(img.offset, 16);
    if (!(img.size > 0) || offset + img.size > CARDID_START) bad(`${img.path} reaches the protected partition`);
    if (!SAFE_PATH.test(img.path) || img.path.split('/').some((s) => s === '..' || s === '.')) bad(`path ${img.path}`);
    if (!/^[0-9a-f]{64}$/i.test(img.sha256)) bad(`sha256 ${img.path}`);
    return { offset, size: img.size, sha256: img.sha256.toLowerCase(), url: new URL(img.path, new URL(MANIFEST_URL, location.href)).href, name: img.path.split('/').pop() };
  }).sort((a, b) => a.offset - b.offset);
  parts.slice(1).forEach((p, i) => { if (parts[i].offset + parts[i].size > p.offset) bad('overlapping images'); });
  return parts;
}

const hex = (buffer) => [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, '0')).join('');

/** 下载全部镜像并校验大小与 SHA-256。 */
async function download(parts) {
  const files = [];
  for (const part of parts) {
    const res = await fetch(part.url);
    if (!res.ok) throw new FlashError(tr('noManifest'));
    const buffer = await res.arrayBuffer();
    const digest = hex(await crypto.subtle.digest('SHA-256', buffer));
    if (buffer.byteLength !== part.size || digest !== part.sha256) throw new FlashError(tr('checksum', { file: part.name }));
    files.push({ data: new Uint8Array(buffer), address: part.offset });
  }
  return files;
}

// ---------- 设备检查 ----------
/** 解析 ESP-IDF 分区表(每项 32 字节,魔数 0xAA 0x50),返回 { label, offset, size } 列表。 */
function parsePartitions(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = [];
  for (let i = 0; i + 32 <= bytes.length; i += 32) {
    if (bytes[i] !== 0xaa || bytes[i + 1] !== 0x50) break;
    const label = new TextDecoder().decode(bytes.subarray(i + 12, i + 28)).replace(/\0.*$/s, '');
    out.push({ label, offset: view.getUint32(i + 4, true), size: view.getUint32(i + 8, true) });
  }
  return out;
}

function saveFile(bytes, name) {
  const url = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));
  const a = Object.assign(document.createElement('a'), { href: url, download: name });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

// ---------- 刷写 ----------
let running = false;
const guardLeave = (e) => { e.preventDefault(); e.returnValue = tr('leave'); };

async function flash() {
  if (running) return;
  // 选择串口必须在点击里直接调用(浏览器要求用户手势),所以放在所有异步操作之前。
  let port;
  try {
    port = await navigator.serial.requestPort({ filters: [{ usbVendorId: ESPRESSIF_VID }] });
  } catch {
    return;  // 用户关掉了选择框
  }
  running = true;
  ui.start.disabled = true;
  ui.backup.disabled = true;
  addEventListener('beforeunload', guardLeave);
  let transport;
  try {
    setStatus(tr('fetching'), { progress: 0 });
    const esptool = await import(ESPTOOL_URL);
    const manifest = await fetchManifest();
    const files = await download(partsOf(manifest));

    setStatus(tr('connecting'), { progress: 0 });
    transport = new esptool.Transport(port, false);
    const loader = new esptool.ESPLoader({ transport, baudrate: 921600, terminal: { clean() {}, writeLine: (l) => console.debug(l), write: (l) => console.debug(l) } });
    try {
      await loader.main();
    } catch (err) {
      if (/open|lock|busy|access/i.test(String(err?.message))) throw new FlashError(tr('busy'));
      throw err;
    }
    if (loader.chip.CHIP_NAME !== 'ESP32-C3') throw new FlashError(tr('wrongChip', { chip: loader.chip.CHIP_NAME }));
    const size = await loader.detectFlashSize();
    if (size !== '8MB') throw new FlashError(tr('wrongSize', { size: size ?? '?' }));
    const table = parsePartitions(await loader.readFlash(0x8000, 0xc00));
    if (!table.some((p) => p.label === 'cardid' && p.offset === CARDID_START)) throw new FlashError(tr('notPassport'));

    if (ui.backup.checked) {
      const mac = (await loader.chip.readMac(loader)).replaceAll(':', '').toLowerCase();
      setStatus(tr('backingUp', { p: 0 }), { progress: 0 });
      const image = await loader.readFlash(0, FLASH_BYTES, (_packet, done, total) => {
        const p = done / total;
        setStatus(tr('backingUp', { p: Math.floor(p * 100) }), { progress: p });
      });
      if (image.length !== FLASH_BYTES) throw new FlashError(tr('failed', { msg: 'backup incomplete' }));
      const file = `passport-${mac}-flash.bin`;
      saveFile(image, file);
      setStatus(tr('backupSaved', { file }), { kind: 'ok' });
      await new Promise((r) => setTimeout(r, 1800));
    }

    // 再确认一次:每段都在 cardid 之前(partsOf 已校验,这里针对实际下载到的数据)。
    if (files.some((f) => f.address + f.data.length > CARDID_START)) throw new FlashError(tr('badManifest', { msg: 'protected partition' }));
    const total = files.reduce((n, f) => n + f.data.length, 0);
    const before = files.map((_, i) => files.slice(0, i).reduce((n, f) => n + f.data.length, 0));
    setStatus(tr('writing', { p: 0 }), { progress: 0 });
    await loader.writeFlash({
      fileArray: files,
      flashMode: 'keep', flashFreq: 'keep', flashSize: 'keep',
      eraseAll: false,
      compress: true,
      reportProgress: (index, written, length) => {
        const p = (before[index] + (written / length) * files[index].data.length) / total;
        setStatus(tr('writing', { p: Math.floor(p * 100) }), { progress: p });
      },
    });
    setStatus(tr('restarting'), { progress: 1 });
    await loader.after('hard_reset');
    setStatus(tr('done', { version: manifest.version }), { kind: 'ok' });
  } catch (err) {
    console.error(err);
    const message = err instanceof FlashError ? err.message : tr('failed', { msg: err?.message || String(err) });
    setStatus(message, { kind: 'error' });
  } finally {
    try { await transport?.disconnect(); } catch { /* 已断开 */ }
    try { await port.close(); } catch { /* 已关闭 */ }
    removeEventListener('beforeunload', guardLeave);
    running = false;
    ui.start.disabled = false;
    ui.backup.disabled = false;
  }
}

// ---------- 初始化 ----------
if (!window.isSecureContext) {
  ui.start.disabled = true;
  setStatus(tr('insecure'), { kind: 'error' });
} else if (!('serial' in navigator)) {
  ui.start.disabled = true;
  setStatus(tr('unsupported'), { kind: 'error' });
} else {
  ui.start.addEventListener('click', flash);
}
fetchManifest()
  .then((m) => { partsOf(m); ui.version.textContent = `${m.version} · ${m.build}`; })
  .catch(() => { ui.version.textContent = '—'; });
