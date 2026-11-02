import { CF_TEMPLATE_URL, PANEL_VERSION, panelHash } from '../config.js';
import { BTN, renderConfirm, renderFailure, renderInstallDone, renderProgress, show, termsText, failureText } from '../ui.js';
import { escapeHtml as esc, generateStrongPassword, isSshHost, isSshUser, parsePort, parseServerLine } from '../validate.js';
import { action, connector, hasCredential, hostKeyChangedText, respond, scrub, storeCredential, throttled } from './common.js';

const ADMIN_USER = 'admin';
const ZONE_PAGE = 8;

const PLAN_ERRORS = {
  DOMAIN_TOO_LONG: 'این دامنه برای پنل بیش از حد بلند است. نام تانل حداکثر ۲۴ کاراکتر می‌تواند باشد، پس دامنهٔ کوتاه‌تری انتخاب کنید.',
  NO_FREE_NS_NAME: 'نام آزادی برای نیم‌سرور در این دامنه پیدا نشد. رکوردهای ns-soar و ns-wd را بررسی کنید.',
  NO_FREE_TUNNEL_NAME: 'نام آزادی برای تانل در این دامنه پیدا نشد.',
  NO_FREE_PANEL_NAME: 'نام آزادی برای پنل در این دامنه پیدا نشد.',
  EXISTING_ZONE_CONFLICT: 'رکورد NS تانل فعلی این پنل به نیم‌سرور دیگری اشاره می‌کند. آن را در کلودفلر بررسی کنید.',
};

export function installFlow({ bot, app }) {
  const { store, vault, deps, tasks, steps } = app;
  const zoneCache = new Map();

  const zoneRows = (chatId, page) => {
    const zones = zoneCache.get(chatId) ?? [];
    const pages = Math.max(1, Math.ceil(zones.length / ZONE_PAGE));
    const current = Math.min(Math.max(0, page), pages - 1);
    // An index keeps callback_data under Telegram's 64 bytes for any domain length.
    const rows = zones.slice(current * ZONE_PAGE, (current + 1) * ZONE_PAGE)
      .map((z, i) => [{ text: `🌐 ${z.name}`, data: `zone:${current * ZONE_PAGE + i}` }]);
    const nav = [];
    if (current > 0) nav.push({ text: '◀️ قبلی', data: `zones:${current - 1}` });
    if (current < pages - 1) nav.push({ text: 'بعدی ▶️', data: `zones:${current + 1}` });
    if (nav.length) rows.push(nav);
    rows.push([{ text: '🔙 تغییر اکانت کلودفلر', data: 'back:cf_email' }, BTN.cancel]);
    return rows;
  };

  const cfPromptRows = [
    [{ text: '🚀 باز کردن فرم آماده توکن (۱-کلیک)', url: CF_TEMPLATE_URL }],
    [BTN.repair],
    [BTN.cancel],
  ];
  const cfPrompt = (ctx) => respond(ctx, `👋 <b>شروع فرآیند نصب WhiteDNS Soar Server</b>

📧 <b>مرحله ۱ از ۲: ورود به کلودفلر</b>
لطفاً <b>آدرس ایمیل</b> اکانت کلودفلر را بفرستید.
<i>(مثال: myname@gmail.com)</i>

💡 <i>اگر توکن آماده دارید، می‌توانید همان را مستقیماً بفرستید.</i>`, cfPromptRows);

  async function authenticate(ctx, chatId, authInput) {
    const status = await ctx.reply('⏳ در حال بررسی اتصال به اکانت کلودفلر...');
    const verify = await deps.cf.verifyToken(authInput);
    if (!verify.ok) {
      return show(ctx.telegram, chatId, status.message_id, `❌ <b>اطلاعات کلودفلر نامعتبر است.</b>\n\n<code>${esc(verify.error)}</code>`, [
        [{ text: '🚀 باز کردن فرم آماده ساخت توکن', url: CF_TEMPLATE_URL }],
        [{ text: '🔙 ویرایش ایمیل', data: 'back:cf_email' }, BTN.cancel],
      ]);
    }
    const zones = await deps.cf.listZones(verify.resolvedAuth);
    if (!zones.ok || !zones.zones.length) {
      return show(ctx.telegram, chatId, status.message_id, `⚠️ <b>ارتباط برقرار شد، ولی دامنه‌ای پیدا نشد.</b>\n${esc(zones.error ?? 'ابتدا دامنهٔ خود را در کلودفلر ثبت کنید.')}`, [
        [{ text: '🔙 بازگشت', data: 'back:cf_email' }, BTN.cancel],
      ]);
    }
    vault.set(chatId, { cfAuth: verify.resolvedAuth });
    zoneCache.set(chatId, zones.zones);
    store.saveSession(chatId, { step: 'SELECTING_ZONE' });
    return show(ctx.telegram, chatId, status.message_id, '✅ <b>اتصال به کلودفلر برقرار شد.</b>\n<i>(پیام شما برای امنیت پاک شد)</i>\n\n👇 دامنهٔ مورد نظر را انتخاب کنید:', zoneRows(chatId, 0));
  }

  const serverPrompt = (ctx, domain) => respond(ctx, `🌐 دامنهٔ انتخاب‌شده: <code>${esc(domain)}</code>

📌 لطفاً <b>آی‌پی یا نام میزبان سرور</b> را بفرستید.
<i>(مثال: <code>194.26.11.20</code>)</i>

💡 <i>یا همه را یکجا بفرستید:</i> <code>IP:Port:User:Password</code>`, [
    [{ text: '⚙️ مدیریت رکوردهای DNS این دامنه', data: 'cf_dns' }],
    [{ text: '🔙 تغییر دامنه', data: 'back:select_zone' }, BTN.cancel],
  ]);

  const askPort = (ctx, host) => respond(ctx, `🌐 سرور: <code>${esc(host)}</code>\n\nپورت SSH سرور را مشخص کنید:`, [
    [{ text: '🔘 پورت پیش‌فرض (22)', data: 'port:22' }],
    [{ text: '✏️ ورود پورت سفارشی', data: 'port:custom' }],
    [{ text: '🔙 ویرایش آی‌پی سرور', data: 'back:ssh_ip' }, BTN.cancel],
  ]);
  const askUser = (ctx, port) => respond(ctx, `پورت SSH: <code>${esc(port)}</code>\n\nنام کاربری سرور را انتخاب کنید:`, [
    [{ text: '🔘 کاربر پیش‌فرض (root)', data: 'user:root' }],
    [{ text: '✏️ نام کاربری سفارشی', data: 'user:custom' }],
    [{ text: '🔙 تغییر پورت', data: 'back:ssh_port' }, BTN.cancel],
  ]);
  const askPassword = (ctx, user) => respond(ctx, `نام کاربری: <code>${esc(user)}</code>\n\n🔑 لطفاً <b>رمز عبور</b> یا متن <b>کلید خصوصی SSH</b> را بفرستید.\n<i>(پیام شما بلافاصله حذف می‌شود)</i>`, [
    [{ text: '🔙 تغییر نام کاربری', data: 'back:ssh_user' }, BTN.cancel],
  ]);

  /** Read-only: inspects the server and Cloudflare, then shows what would change. */
  async function prepare(telegram, chatId) {
    const s = store.getSession(chatId);
    const target = { host: s.sshHost, port: s.sshPort, user: s.sshUser };
    const status = await show(telegram, chatId, null, '⏳ در حال اتصال به سرور و بررسی آن. هنوز چیزی تغییر نمی‌کند...');
    let session;
    try {
      session = await connector(app, chatId, target)();
    } catch (err) {
      if (err.code === 'HOST_KEY_CHANGED') {
        store.saveSession(chatId, { pendingFingerprint: err.fingerprint });
        return show(telegram, chatId, status, hostKeyChangedText(target.host, err.fingerprint), [[{ text: '✅ کلید جدید را می‌پذیرم', data: 'hostkey:accept' }], [BTN.cancel]]);
      }
      return show(telegram, chatId, status, `❌ ${esc(failureText(err.code))}\n\n<code>${esc(err.message)}</code>`, [
        [{ text: '🔄 تلاش مجدد', data: 'retry:prepare' }],
        [{ text: '✏️ ویرایش مشخصات سرور', data: 'back:ssh_ip' }, BTN.cancel],
      ]);
    }

    try {
      const facts = await deps.probe(session, target.host);
      const fingerprint = session.fingerprint;
      if (facts.job_active === '1') {
        return show(telegram, chatId, status, '⏳ <b>عملیات دیگری روی این سرور در حال اجراست.</b>\nبرای دیدن نتیجهٔ آن از /repair استفاده کنید. هیچ تغییری انجام نشد.', [[BTN.repair], [BTN.cancel]]);
      }
      const blocked = blockingReason(facts);
      if (blocked) return show(telegram, chatId, status, `❌ <b>نصب روی این سرور ممکن نیست.</b> هیچ تغییری انجام نشد.\n\n${esc(blocked)}`, [[{ text: '🔄 بررسی دوباره', data: 'retry:prepare' }], [BTN.cancel]]);

      const existingZone = facts.installed === '1' ? facts.zone : '';
      if (existingZone && !existingZone.endsWith(`.${s.domain}`) && !s.replaceData) {
        store.saveSession(chatId, { facts });
        return show(telegram, chatId, status, `⚠️ <b>پنل موجود به دامنهٔ دیگری تعلق دارد.</b>

پنل این سرور با تانل <code>${esc(existingZone)}</code> ساخته شده و تانل یک پنل قابل انتقال نیست. برای حفظ حساب‌ها، از همان دامنه استفاده کنید.

اگر نصب تازه می‌خواهید، اطلاعات فعلی به پوشهٔ پشتیبان روی سرور منتقل می‌شود و <b>لینک‌های کاربران فعلی از کار می‌افتند.</b>`, [
          [{ text: '🗄 پشتیبان‌گیری و نصب تازه', data: 'zone_replace' }],
          [{ text: '🔙 تغییر دامنه', data: 'back:select_zone' }, BTN.cancel],
        ]);
      }

      const plan = await deps.cf.planForZone(vault.get(chatId, 'cfAuth'), s.zoneId, s.domain, facts.public_ip, s.replaceData ? '' : existingZone);
      if (!plan.ok) return show(telegram, chatId, status, `❌ ${esc(PLAN_ERRORS[plan.error] ?? plan.error)}`, [[{ text: '🔙 تغییر دامنه', data: 'back:select_zone' }, BTN.cancel]]);

      store.saveSession(chatId, { facts, plan, step: 'CONFIRM_DEPLOY' });
      const rows = [[{ text: '🚀 تأیید و شروع نصب', data: 'deploy' }]];
      if (facts.installed === '1' && !s.replaceData) rows.push([{ text: '🚀 نصب همراه با رمز ادمین تازه', data: 'deploy:reset' }]);
      rows.push([{ text: '⚙️ رکوردهای DNS', data: 'cf_dns' }], [{ text: '🔙 ویرایش مشخصات سرور', data: 'back:ssh_ip' }, BTN.cancel]);
      return show(telegram, chatId, status, renderConfirm({ domain: s.domain, host: target.host, sshPort: target.port, sshUser: target.user, facts, plan, fingerprint }), rows);
    } finally {
      session.close();
    }
  }

  function blockingReason(facts) {
    if (facts.os_supported !== '1') return `${failureText('UNSUPPORTED_OS')} (${facts.os})`;
    if (facts.arch === 'unsupported') return failureText('UNSUPPORTED_ARCH');
    if (facts.systemd !== '1') return failureText('NO_SYSTEMD');
    if (Number(facts.disk_mb) < 200) return failureText('NO_DISK');
    if (facts.port53) return `${failureText('PORT53_BUSY')} (${facts.port53})`;
    if (!facts.public_ip) return 'آی‌پی عمومی IPv4 برای این سرور پیدا نشد. رکورد A به آن نیاز دارد.';
    return null;
  }

  async function deploy(telegram, chatId, { resetAdmin }) {
    const s = store.getSession(chatId);
    const target = { host: s.sshHost, port: s.sshPort, user: s.sshUser };
    const cfAuth = vault.get(chatId, 'cfAuth');
    if (!s.plan || !cfAuth || !hasCredential(vault, chatId)) {
      return show(telegram, chatId, null, '⚠️ اطلاعات این نشست منقضی شده است. لطفاً /start را بزنید.');
    }
    if (!tasks.tryLock(target.host)) return show(telegram, chatId, null, '⏳ عملیات دیگری روی این سرور در حال اجراست.');

    const jobId = store.beginJob(chatId, target.host, 'install');
    const title = 'در حال نصب خودکار WhiteDNS';
    const message = await show(telegram, chatId, null, renderProgress({ title, host: target.host, domain: s.domain, note: 'در حال ثبت رکوردهای DNS...' }));
    const edits = throttled((stage) => show(telegram, chatId, message, renderProgress({ title, host: target.host, domain: s.domain, stage })));
    let session;
    try {
      await deps.cf.applyPlan(cfAuth, s.zoneId, s.plan);

      const needsPassword = s.facts.installed !== '1' || s.replaceData || resetAdmin;
      const adminPass = needsPassword ? generateStrongPassword() : null;
      const connect = connector(app, chatId, target);
      session = await connect();
      const result = await deps.runJob({
        session,
        connect,
        op: 'install',
        arch: s.facts.arch,
        secret: adminPass,
        params: {
          ZONE: s.plan.zone,
          NS_HOST: s.plan.nsHost,
          PANEL_DOMAIN: s.plan.panelDomain,
          PUBLIC_IP: s.facts.public_ip,
          LISTEN_IP: s.facts.listen_ip,
          ADMIN_USER,
          VERSION: PANEL_VERSION,
          BUNDLE_SHA256: panelHash(s.facts.arch),
          RESET_ADMIN: resetAdmin ? '1' : '0',
          ON_ZONE_MISMATCH: s.replaceData ? 'replace' : 'fail',
          ALLOW_MIGRATE: s.facts.old_soar === '1' ? '1' : '0',
        },
        onEvent(event) { if (event.status === 'start') edits.push(event.stage); },
      });
      session = result.session;
      await edits.finish();

      if (result.status !== 'ok') {
        return show(telegram, chatId, message, renderFailure(result), [
          [{ text: '🔄 تلاش مجدد', data: 'retry:prepare' }],
          [BTN.cancel],
        ]);
      }
      store.upsertDeployment({
        chatId, domain: s.domain, vpsIp: target.host, panelUrl: result.panel_url, sshPort: target.port, sshUser: target.user,
        zone: s.plan.zone, nsHost: s.plan.nsHost, panelDomain: s.plan.panelDomain, zoneId: s.zoneId,
      });
      store.resetSession(chatId);
      vault.clear(chatId);
      const rows = [];
      if (result.https === 'true' && result.panel_url) rows.push([{ text: '🌐 ورود به پنل WhiteDNS', url: result.panel_url }]);
      rows.push([BTN.status]);
      return show(telegram, chatId, message, renderInstallDone({
        // A password generated here was not used if a job was already running on the server.
        result, host: target.host, sshUser: target.user, sshPort: target.port, adminUser: ADMIN_USER, adminPass: result.attached ? null : adminPass, plan: s.plan,
      }), rows);
    } catch (err) {
      await edits.finish();
      const text = err.code ? `${esc(failureText(err.code))}\n\n<code>${esc(err.message)}</code>` : esc(err.message);
      return show(telegram, chatId, message, `❌ <b>عملیات متوقف شد</b>\n\n${text}`, [[{ text: '🔄 تلاش مجدد', data: 'retry:prepare' }], [BTN.cancel]]);
    } finally {
      session?.close();
      store.finishJob(jobId);
      tasks.unlock(target.host);
    }
  }

  // ---- commands & buttons --------------------------------------------------------
  const startTerms = (ctx) => {
    store.resetSession(ctx.chat.id, 'TERMS_AGREEMENT');
    vault.clear(ctx.chat.id);
    return respond(ctx, termsText(), [
      [{ text: '✅ شرایط را می‌پذیرم و ادامه می‌دهم', data: 'terms_accept' }],
      [{ text: '❌ نمی‌پذیرم و انصراف', data: 'terms_decline' }],
    ]);
  };
  bot.command('start', startTerms);
  action(bot, 'cmd:start', startTerms);
  action(bot, 'terms_accept', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_CF_EMAIL' });
    return cfPrompt(ctx);
  });
  action(bot, 'terms_decline', (ctx) => {
    store.resetSession(ctx.chat.id);
    return respond(ctx, '❌ <b>فرآیند لغو شد.</b>\n\nهیچ اطلاعاتی دریافت یا ذخیره نشد.', [[{ text: '🚀 شروع مجدد', data: 'cmd:start' }]]);
  });
  action(bot, 'back:cf_email', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_CF_EMAIL' });
    return cfPrompt(ctx);
  });
  action(bot, 'back:select_zone', (ctx) => {
    if (!zoneCache.get(ctx.chat.id)?.length) return startTerms(ctx);
    store.saveSession(ctx.chat.id, { step: 'SELECTING_ZONE', replaceData: false });
    return respond(ctx, '👇 دامنهٔ مورد نظر را انتخاب کنید:', zoneRows(ctx.chat.id, 0));
  });
  action(bot, /^zones:(\d+)$/, (ctx) => respond(ctx, '👇 دامنهٔ مورد نظر را انتخاب کنید:', zoneRows(ctx.chat.id, Number(ctx.match[1]))));
  action(bot, /^zone:(\d+)$/, (ctx) => {
    const zone = zoneCache.get(ctx.chat.id)?.[Number(ctx.match[1])];
    if (!zone) return startTerms(ctx);
    store.saveSession(ctx.chat.id, { zoneId: zone.id, domain: zone.name, step: 'AWAITING_SSH_IP' });
    return serverPrompt(ctx, zone.name);
  });
  action(bot, 'back:ssh_ip', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_SSH_IP' });
    return serverPrompt(ctx, store.getSession(ctx.chat.id).domain);
  });
  action(bot, 'cf_continue', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_SSH_IP' });
    return serverPrompt(ctx, store.getSession(ctx.chat.id).domain);
  });
  action(bot, 'back:ssh_port', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_SSH_PORT' });
    return askPort(ctx, store.getSession(ctx.chat.id).sshHost);
  });
  action(bot, 'back:ssh_user', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_SSH_USER' });
    return askUser(ctx, store.getSession(ctx.chat.id).sshPort ?? 22);
  });
  action(bot, 'port:22', (ctx) => {
    store.saveSession(ctx.chat.id, { sshPort: 22, step: 'AWAITING_SSH_USER' });
    return askUser(ctx, 22);
  });
  action(bot, 'port:custom', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_SSH_PORT_CUSTOM' });
    return respond(ctx, 'لطفاً شماره پورت SSH را بفرستید:', [[{ text: '🔙 بازگشت', data: 'back:ssh_port' }, BTN.cancel]]);
  });
  action(bot, 'user:root', (ctx) => {
    store.saveSession(ctx.chat.id, { sshUser: 'root', step: 'AWAITING_SSH_PASS' });
    return askPassword(ctx, 'root');
  });
  action(bot, 'user:custom', (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_SSH_USER_CUSTOM' });
    return respond(ctx, 'لطفاً نام کاربری SSH را بفرستید. این کاربر باید دسترسی sudo داشته باشد:', [[{ text: '🔙 بازگشت', data: 'back:ssh_user' }, BTN.cancel]]);
  });

  const runPrepare = (ctx) => {
    if (!hasCredential(vault, ctx.chat.id) || !vault.get(ctx.chat.id, 'cfAuth')) {
      return respond(ctx, '⚠️ اطلاعات این نشست منقضی شده است. لطفاً /start را بزنید.', [[BTN.start]]);
    }
    tasks.run(ctx.chat.id, () => prepare(ctx.telegram, ctx.chat.id));
    return undefined;
  };
  action(bot, 'retry:prepare', runPrepare);
  action(bot, 'zone_replace', (ctx) => {
    store.saveSession(ctx.chat.id, { replaceData: true });
    return runPrepare(ctx);
  });
  action(bot, 'hostkey:accept', (ctx) => {
    const s = store.getSession(ctx.chat.id);
    if (s.pendingFingerprint) store.setKnownHost(s.sshHost, s.sshPort, s.pendingFingerprint);
    store.saveSession(ctx.chat.id, { pendingFingerprint: null });
    return runPrepare(ctx);
  });

  const startDeploy = (resetAdmin) => (ctx) => {
    tasks.run(ctx.chat.id, () => deploy(ctx.telegram, ctx.chat.id, { resetAdmin }));
  };
  action(bot, 'deploy', startDeploy(false));
  action(bot, 'deploy:reset', startDeploy(true));

  // ---- text steps ----------------------------------------------------------------
  steps.TERMS_AGREEMENT = (ctx) => respond(ctx, '⚠️ لطفاً برای ادامه، یکی از دکمه‌های بالا را انتخاب کنید.', [
    [{ text: '✅ شرایط را می‌پذیرم و ادامه می‌دهم', data: 'terms_accept' }],
    [{ text: '❌ نمی‌پذیرم و انصراف', data: 'terms_decline' }],
  ]);

  steps.AWAITING_CF_EMAIL = async (ctx, text) => {
    if (text.includes(':') || (text.length >= 35 && !text.includes('@'))) {
      await scrub(ctx);
      return authenticate(ctx, ctx.chat.id, text);
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(text)) {
      return respond(ctx, '❌ لطفاً یک ایمیل معتبر بفرستید (مثال: <code>yourname@gmail.com</code>):', [[BTN.cancel]]);
    }
    store.saveSession(ctx.chat.id, { cfEmail: text, step: 'AWAITING_CF_KEY' });
    return respond(ctx, `✅ ایمیل ثبت شد: <code>${esc(text)}</code>

🔑 <b>مرحله ۲ از ۲: توکن کلودفلر</b>
۱. دکمهٔ زیر را بزنید. دسترسی‌ها از قبل پر شده‌اند.
۲. <b>Continue to summary</b> و سپس <b>Create Token</b> را بزنید.
۳. توکن را کپی کرده و اینجا بفرستید.

💡 <i>می‌توانید Global API Key را هم بفرستید.</i>`, [
      [{ text: '🚀 باز کردن فرم آماده توکن (۱-کلیک)', url: CF_TEMPLATE_URL }],
      [{ text: '🔙 ویرایش ایمیل', data: 'back:cf_email' }, BTN.cancel],
    ]);
  };

  steps.AWAITING_CF_KEY = async (ctx, text, s) => {
    await scrub(ctx);
    return authenticate(ctx, ctx.chat.id, s.cfEmail && !text.includes(':') ? `${s.cfEmail}:${text}` : text);
  };

  steps.AWAITING_SSH_IP = async (ctx, text) => {
    const chatId = ctx.chat.id;
    const line = parseServerLine(text);
    if (line) {
      await scrub(ctx);
      if (line.error || !line.password) {
        return respond(ctx, '❌ قالب درست نیست. قالب درست: <code>IP:Port:User:Password</code>', [[{ text: '🔙 تغییر دامنه', data: 'back:select_zone' }, BTN.cancel]]);
      }
      storeCredential(vault, chatId, line.password);
      store.saveSession(chatId, { sshHost: line.host, sshPort: line.port, sshUser: line.user, step: 'PROBING' });
      tasks.run(chatId, () => prepare(ctx.telegram, chatId));
      return undefined;
    }
    if (!isSshHost(text)) {
      return respond(ctx, '❌ لطفاً یک آی‌پی یا نام میزبان معتبر بفرستید (مثال: <code>194.26.11.20</code>):', [[{ text: '🔙 تغییر دامنه', data: 'back:select_zone' }, BTN.cancel]]);
    }
    store.saveSession(chatId, { sshHost: text, step: 'AWAITING_SSH_PORT' });
    return askPort(ctx, text);
  };

  steps.AWAITING_SSH_PORT = (ctx, _text, s) => askPort(ctx, s.sshHost);
  steps.AWAITING_SSH_USER = (ctx, _text, s) => askUser(ctx, s.sshPort ?? 22);

  steps.AWAITING_SSH_PORT_CUSTOM = (ctx, text) => {
    const port = parsePort(text);
    if (port === null) return respond(ctx, '❌ شماره پورت باید عددی بین ۱ تا ۶۵۵۳۵ باشد:', [[BTN.cancel]]);
    store.saveSession(ctx.chat.id, { sshPort: port, step: 'AWAITING_SSH_USER' });
    return askUser(ctx, port);
  };

  steps.AWAITING_SSH_USER_CUSTOM = (ctx, text) => {
    if (!isSshUser(text)) return respond(ctx, '❌ نام کاربری نامعتبر است:', [[BTN.cancel]]);
    store.saveSession(ctx.chat.id, { sshUser: text, step: 'AWAITING_SSH_PASS' });
    return askPassword(ctx, text);
  };

  steps.AWAITING_SSH_PASS = async (ctx, text) => {
    const chatId = ctx.chat.id;
    await scrub(ctx);
    storeCredential(vault, chatId, text);
    store.saveSession(chatId, { step: 'PROBING' });
    tasks.run(chatId, () => prepare(ctx.telegram, chatId));
  };

  return { authenticate, zoneCache };
}
