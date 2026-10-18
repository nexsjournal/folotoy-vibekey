// 支持页:英文词条、常见问题手风琴动画、留言表单(POST /api/support)。依赖 main.js 的 IB。
//
// 表单约定(与后台一致):JSON {email, message};邮箱可选(填了就校验格式),留言必填、最多 4000 字;
// 提交中禁用按钮、防重复;201 → 成功面板显示编号(可复制);403 / 429 / 5xx / 网络错误各给对应提示。
// 蜜罐字段 website 被填了 = 机器人:不发请求、假装成功。只用相对路径,由服务器转发到后台。
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const MAX = 4000;

  IB.i18n.add({
    'doc.title': 'Support — InputBetter',
    'sp.eyebrow': 'Support', 'sp.title': 'Need a hand?',
    'sp.lead': 'Leave us a message — common questions are answered below.',
    'sp.issues': 'GitHub Issues', 'sp.write': 'Leave a message',
    'faq.title': 'Frequently asked questions',
    'q1': 'Which system permissions does it need?',
    'a1.1': 'Two: Microphone, to hear you (recording only happens while the shortcut is held), and Accessibility, to listen for the shortcut and paste the text at your cursor (dictation writes to the clipboard, simulates ⌘V, then restores what was on the clipboard before).',
    'a1.2': 'When you start live captions and capture an app’s audio for the first time, macOS asks for system audio recording permission. There is no public API to query that permission, so the app can’t check it ahead of time.',
    'a1.3': 'If nothing shows up after dictating, Accessibility is usually missing, or the target field doesn’t accept paste — the text then stays on the clipboard, the status pill shows “Copied”, and you can paste it yourself.',
    'q2': 'Model download is slow or fails. What now?',
    'a2.1': 'Models come from Hugging Face; if one source fails the app automatically switches to the mirror (hf-mirror) and only reports an error when both fail — just retry. You can also prefer the mirror under Settings › Models.',
    'a2.2': 'To get going quickly: Apple Speech needs no download; SenseVoice Small is only about 240 MB and very fast for Chinese; the default Whisper Large v3 Turbo (compressed) is about 650 MB.',
    'a2.3': 'The first time Whisper loads, CoreML optimizes the model for your chip, which takes 2–3 minutes. After that it loads in about 1.6 seconds.',
    'q3': 'Passport won’t connect to my Mac.',
    'a3.1': 'Hold the power button to turn it on and connect it with a USB-C cable that carries data (many are charge-only). USB takes priority; unplug it and the device falls back to Bluetooth, advertising as “InputBetter” with no pairing required. Bluetooth can be turned off under Settings › Passport.',
    'a3.2': 'If the device isn’t running the InputBetter firmware, the app offers to flash it under Settings › Passport. Only one program can hold the serial port at a time, so quit other serial tools or other Passport companion apps first.',
    'a3.3': 'When no Mac is connected the device shows a clock and keys only wake the screen — they won’t do anything else.',
    'q4': 'Is flashing safe? Can I restore the original firmware?',
    'a4.1': 'All three methods — in the app, in the browser, and the command-line script — write only the bootloader, partition table and application. The flash is never erased and the device identity partition (cardid) is never written.',
    'a4.2': 'Before flashing a device for the first time, the app backs up the full 8 MB flash to ~/Library/Application Support/InputBetter/Backups/. The browser flasher can download a backup to your computer first (passport-<MAC>-flash.bin). The backup contains the device identity — keep it safe and don’t share it.',
    'a4.3': 'Browser flashing needs Chrome or Edge on a computer (Web Serial). Quit the InputBetter app first, since it holds the serial port, and don’t unplug or close the page while flashing.',
    'q5': 'What do cloud recognition and AI services upload?',
    'a5.1': 'By default all recognition runs on your Mac and audio never leaves it. Only when you pick a cloud model under Settings › Models (Volcengine, Alibaba Cloud Bailian, ElevenLabs, Soniox or an OpenAI-compatible endpoint) is the recording sent to that provider.',
    'a5.2': 'AI polish, AI translation and caption summaries send text to the AI service you configured (any OpenAI-compatible API); online machine translation (DeepL, Google, Microsoft, Volcengine, Tencent Cloud, Baidu) works the same way. System translation runs offline on your Mac.',
    'a5.3': 'All API keys are stored only on your Mac in ~/Library/Application Support/InputBetter/credentials.json (mode 600) and are never uploaded. Transcripts live in memory only; the app keeps no history.',
    'q6': 'System requirements and pricing?',
    'a6.1': 'A Mac with Apple silicon running macOS 26 or later. The installer is signed and notarized by Apple; drag it into Applications and you’re done.',
    'a6.2': 'InputBetter and the Passport firmware are open source under the MIT license and free to use. Cloud recognition, online translation and AI services are billed by their providers with your own keys.',
    'q7': 'How do I update to a new version?',
    'a7.1': 'Builds downloaded from this website check for updates once a day and show what’s new when a version is available. You can also click “Check Now” in Settings › General › About & Updates, or choose “Check for Updates…” in the menu bar menu.',
    'a7.2': 'Open the new disk image and drag InputBetter to Applications to replace the old version — your settings and downloaded models are kept. Self-built open-source builds don’t check for updates by default; see the README on GitHub to point them at your own update feed.',
    // 留言区
    'ct.title': 'Message',
    'ct.lead': 'It goes to the developer and is never public. Leave your email if you’d like a reply.',
    'ct.gh': 'Code issues can also go to GitHub →',
    'ct.f1.t': 'Replies go to your email',
    'ct.f1.d': 'Leave an email and we’ll write back. You can send without one — we just won’t be able to reply.',
    'ct.f2.t': 'A reference number',
    'ct.f2.d': 'A successful send returns a reference number. Quote it next time and we’ll know which message you mean.',
    'ct.f3.t': 'Bugs and feature ideas belong on GitHub Issues',
    'ct.f3.d': 'They can be discussed and tracked in the open. Use this form for anything private (logs, screenshots, accounts) or when you just want to say hi.',
    'ct.f3.link': 'Open an issue on GitHub →',
    'ct.email': 'Email', 'ct.optional': 'optional', 'ct.emailHint': 'Used only to reply to this message.',
    'ct.message': 'Message',
    'ct.placeholder': 'What went wrong? Which step, what you saw, your macOS and InputBetter versions…',
    'ct.privacy': 'Only the developer sees your message; your email is used for nothing but the reply.',
    'ct.send': 'Send', 'ct.sending': 'Sending…',
    'ct.done.t': 'Got it, thank you!',
    'ct.done.withEmail': 'We’ll read it soon. The reply will go to {email}.',
    'ct.done.noEmail': 'We’ll read it soon. You didn’t leave an email, so we can’t reply — send another message with one if you’d like an answer.',
    'ct.done.ref': 'Reference', 'ct.copy': 'Copy', 'ct.copied': 'Copied', 'ct.again': 'Write another',
    'ct.badEmail': 'That doesn’t look like a valid email address.',
    'ct.empty': 'Please write a message.',
    'ct.tooLong': 'Please keep it under 4000 characters.',
    'ct.e403': 'The submission was rejected. Please try again later, or {link}.',
    'ct.e403.link': 'open an issue on GitHub',
    'ct.e429': 'Too many submissions in a short time. Please wait a bit and try again.',
    'ct.e5xx': 'The server is temporarily unavailable. Please try again in a few minutes.',
    'ct.eNet': 'Network error — check your connection and try again. Your text is still here.',
    'ct.eOther': 'Something went wrong ({status}). Please try again.',
  }, {
    'ct.sending': '发送中…',
    'ct.done.withEmail': '我们会尽快看。回复会发到 {email}。',
    'ct.done.noEmail': '我们会尽快看。你没有留邮箱，所以我们无法回复；需要回复的话，可以再发一条附上邮箱。',
    'ct.copied': '已复制',
    'ct.badEmail': '邮箱格式不对。',
    'ct.empty': '请写点什么。',
    'ct.tooLong': '留言最多 4000 字。',
    'ct.e403': '提交被拒绝，请稍后再试，或{link}。',
    'ct.e403.link': '到 GitHub 提 issue',
    'ct.e429': '提交太频繁，请稍等片刻再试。',
    'ct.e5xx': '服务器暂时不可用，请过几分钟再试。',
    'ct.eNet': '网络错误，请检查连接后重试。你写的内容还在。',
    'ct.eOther': '出错了（{status}），请重试。',
  });

  // ---------- 常见问题:details 始终 open,用 class 控制高度过渡 ----------
  document.querySelectorAll('.qa').forEach((qa) => {
    const summary = qa.querySelector('summary');
    if (!qa.open) qa.classList.add('closed');
    qa.open = true;
    summary.setAttribute('aria-expanded', String(!qa.classList.contains('closed')));
    summary.addEventListener('click', (e) => {
      e.preventDefault();
      const closed = qa.classList.toggle('closed');
      summary.setAttribute('aria-expanded', String(!closed));
    });
  });

  // ---------- 留言表单 ----------
  const form = $('supportForm'), body = $('formBody'), done = $('formDone');
  const email = $('email'), message = $('message'), count = $('count'), status = $('formStatus');
  const submit = $('submit'), sendLabel = $('sendLabel');
  let sending = false;
  let lastEmail = '';

  const setErr = (input, errEl, text) => {
    errEl.textContent = text;
    input.closest('.field').classList.toggle('invalid', !!text);
    input.setAttribute('aria-invalid', text ? 'true' : 'false');
  };
  /// 状态条:kind 为 '' 隐藏;'error' / 'info' 显示。文案里的 {link} 换成 GitHub Issues 链接。
  function setStatus(text, kind = '') {
    status.textContent = '';
    status.dataset.kind = kind;
    if (!text) return;
    const [before, after] = text.split('{link}');
    status.append(before);
    if (after !== undefined) {
      const a = document.createElement('a');
      a.href = 'https://github.com/racall/InputBetter/issues/new'; a.target = '_blank'; a.rel = 'noopener';
      a.textContent = IB.t('ct.e403.link');
      status.append(a, after);
    }
  }

  function updateCount() {
    const n = [...message.value].length;
    count.textContent = String(n);
    count.closest('.count').classList.toggle('near', n > MAX - 200);
  }
  message.addEventListener('input', () => { updateCount(); if ($('messageErr').textContent) validate(); });
  email.addEventListener('input', () => { if ($('emailErr').textContent) validate(); });
  updateCount();

  // 与后端一致的宽松校验:有且只有一个 @,两侧非空,域名带点
  const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  function validate() {
    let ok = true;
    const e = email.value.trim(), m = message.value.trim();
    if (e && !EMAIL.test(e)) { setErr(email, $('emailErr'), IB.t('ct.badEmail')); ok = false; } else setErr(email, $('emailErr'), '');
    if (!m) { setErr(message, $('messageErr'), IB.t('ct.empty')); ok = false; }
    else if ([...m].length > MAX) { setErr(message, $('messageErr'), IB.t('ct.tooLong')); ok = false; }
    else setErr(message, $('messageErr'), '');
    return ok;
  }

  /// 成功:表单换成成功面板(编号 + 回复去向),焦点移过去让读屏播报。
  function showDone(id) {
    $('doneId').textContent = id || '—';
    renderDoneLead();
    body.hidden = true; done.hidden = false;
    form.classList.remove('sent'); void form.offsetWidth; form.classList.add('sent');
    done.focus({ preventScroll: true });
  }
  function renderDoneLead() {
    const lead = $('doneLead');
    lead.textContent = '';
    if (lastEmail) {
      const [before, after] = IB.t('ct.done.withEmail').split('{email}');
      const b = document.createElement('b'); b.textContent = lastEmail;
      lead.append(before, b, after ?? '');
    } else {
      lead.textContent = IB.t('ct.done.noEmail');
    }
  }
  $('again').addEventListener('click', () => {
    done.hidden = true; body.hidden = false;
    setStatus('');
    message.focus();
  });
  $('copyId').addEventListener('click', async () => {
    const btn = $('copyId'), id = $('doneId').textContent;
    try { await navigator.clipboard.writeText(id); } catch {
      // 剪贴板不可用(非安全上下文等):选中编号让用户自己复制
      const range = document.createRange(); range.selectNodeContents($('doneId'));
      const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range);
    }
    btn.textContent = IB.t('ct.copied'); btn.classList.add('ok');
    setTimeout(() => { btn.textContent = IB.t('ct.copy'); btn.classList.remove('ok'); }, 1600);
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (sending) return;
    if (!validate()) {
      form.classList.remove('shake'); void form.offsetWidth; form.classList.add('shake');
      ($('emailErr').textContent ? email : message).focus();
      return;
    }
    lastEmail = email.value.trim();
    // 蜜罐被填了:多半是机器人,假装成功,不发请求。
    if ($('website').value) { form.reset(); updateCount(); showDone(''); return; }
    sending = true;
    submit.disabled = true; submit.classList.add('sending');
    sendLabel.textContent = IB.t('ct.sending');
    setStatus('');
    try {
      const res = await fetch('/api/support', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: lastEmail, message: message.value.trim() }),
      });
      if (res.status === 201) {
        let id = '';
        try { id = (await res.json()).id || ''; } catch { /* 没有正文也算成功 */ }
        form.reset(); updateCount();
        showDone(id);
      } else if (res.status === 403) setStatus(IB.t('ct.e403'), 'error');
      else if (res.status === 429) setStatus(IB.t('ct.e429'), 'error');
      else if (res.status >= 500) setStatus(IB.t('ct.e5xx'), 'error');
      else { setStatus(IB.t('ct.eOther').replace('{status}', String(res.status)), 'error'); validate(); }
    } catch {
      setStatus(IB.t('ct.eNet'), 'error');
    } finally {
      sending = false;
      submit.disabled = false; submit.classList.remove('sending');
      sendLabel.textContent = IB.t('ct.send');
    }
  });

  IB.i18n.onChange(() => {
    if (!sending) sendLabel.textContent = IB.t('ct.send');
    if (!done.hidden) renderDoneLead();
  });
})();
