import net from 'node:net';
import { PANEL_VERSION, panelHash } from '../config.js';
import { BTN, failureText, renderFailure, renderProgress, renderRepairDone, show } from '../ui.js';
import { escapeHtml as esc, generateStrongPassword, isSshHost, parseServerLine } from '../validate.js';
import { action, connector, hasCredential, hostKeyChangedText, respond, scrub, storeCredential, throttled } from './common.js';

const ADMIN_USER = 'admin';

const statusCard = (list) => {
  if (!list.length) return '📊 <b>وضعیت سرورها:</b>\n\nشما هنوز پنلی راه‌اندازی نکرده‌اید.';
  let text = `📊 <b>سرورهای نصب‌شدهٔ شما (${list.length}):</b>\n\n`;
  for (const d of list) {
    text += `• <b>دامنه:</b> <code>${esc(d.domain)}</code>\n  <b>سرور:</b> <code>${esc(d.vps_ip)}</code>\n`;
    if (d.panel_url) text += `  <b>آدرس پنل:</b> ${esc(d.panel_url)}\n`;
    text += '\n';
  }
  return `${text}<i>وضعیت زندهٔ هر سرور را با /repair بررسی کنید.</i>`;
};

const statusRows = (list) => (list.length
  ? [[BTN.start], [BTN.repair], [BTN.uninstall]]
  : [[BTN.start], [BTN.repair]]);

const OPS = {
  repair: {
    title: 'در حال عیب‌یابی و تعمیر خودکار سرور',
    listIntro: '🛠 <b>عیب‌یابی و خودترمیمی WhiteDNS</b>\n\nربات سرویس‌ها، فایل‌ها، HTTPS و تانل را بررسی و اصلاح می‌کند. حساب‌ها و آدرس خصوصی حفظ می‌شوند.\n\n👇 سرور را انتخاب کنید:',
    item: (d) => `🛠 ${d.domain} (${d.vps_ip})`,
    prompt: '🛠 <b>تعمیر سرور</b>',
  },
  uninstall: {
    title: 'در حال حذف WhiteDNS از سرور',
    listIntro: '🗑 <b>حذف پنل WhiteDNS از سرور</b>\n\n👇 سرور را انتخاب کنید:',
    item: (d) => `🗑 ${d.domain} (${d.vps_ip})`,
    prompt: '🗑 <b>حذف پنل</b>',
  },
};

export function maintenanceFlow({ bot, app }) {
  const { store, vault, deps, tasks, steps } = app;

  const list = (op) => (ctx) => {
    const chatId = ctx.chat.id;
    const deployments = store.listDeployments(chatId);
    if (!deployments.length) {
      store.saveSession(chatId, { step: 'AWAITING_MAINT_HOST', maintOp: op, target: null });
      return respond(ctx, `${OPS[op].prompt}\n\nسروری در تاریخچهٔ شما ثبت نیست.\n\n📌 <b>آی‌پی سرور</b> را بفرستید، یا: <code>IP:Port:User:Password</code>`, [[BTN.cancel]]);
    }
    const rows = deployments.map((d) => [{ text: OPS[op].item(d), data: `maint:${op}:${d.id}` }]);
    rows.push([{ text: '✏️ سرور دیگر', data: `maint_manual:${op}` }, BTN.cancel]);
    return respond(ctx, OPS[op].listIntro, rows);
  };

  const askCredential = (ctx, op, target, deployment) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_MAINT_PASS', maintOp: op, target, deploymentId: deployment?.id ?? null });
    return respond(ctx, `${OPS[op].prompt}\n\n🖥 <code>${esc(target.host)}</code> (پورت <code>${esc(target.port)}</code>، کاربر <code>${esc(target.user)}</code>)\n\n🔑 لطفاً <b>رمز عبور</b> یا متن <b>کلید خصوصی SSH</b> را بفرستید.\n<i>(پیام شما بلافاصله حذف می‌شود)</i>`, [[BTN.cancel]]);
  };

  /** Inspects the server, then asks for the final choice of this operation. */
  async function confirm(telegram, chatId) {
    const s = store.getSession(chatId);
    const target = s.target;
    const status = await show(telegram, chatId, null, '⏳ در حال اتصال به سرور و بررسی آن...');
    let session;
    try {
      session = await connector(app, chatId, target)();
    } catch (err) {
      if (err.code === 'HOST_KEY_CHANGED') {
        store.saveSession(chatId, { pendingFingerprint: err.fingerprint });
        return show(telegram, chatId, status, hostKeyChangedText(target.host, err.fingerprint), [[{ text: '✅ کلید جدید را می‌پذیرم', data: 'maint_hostkey' }], [BTN.cancel]]);
      }
      return show(telegram, chatId, status, `❌ ${esc(failureText(err.code))}\n\n<code>${esc(err.message)}</code>`, [[{ text: '🔄 تلاش مجدد', data: 'maint_retry' }], [BTN.cancel]]);
    }
    try {
      const facts = await deps.probe(session, target.host);
      store.saveSession(chatId, { facts, step: 'CONFIRM_MAINT' });
      if (facts.job_active === '1') {
        // A job from before a restart or a dropped connection: follow it rather than start another.
        return show(telegram, chatId, status, '⏳ <b>عملیاتی روی این سرور در حال اجراست.</b>\nمی‌توانید نتیجهٔ آن را دنبال کنید.', [[{ text: '👀 دنبال کردن عملیات', data: 'maint_go:attach' }], [BTN.cancel]]);
      }
      if (s.maintOp === 'repair') {
        if (facts.installed !== '1') {
          return show(telegram, chatId, status, `ℹ️ ${esc(failureText('NOT_INSTALLED'))}`, [[BTN.start], [BTN.cancel]]);
        }
        return show(telegram, chatId, status, `🛠 <b>آمادهٔ تعمیر</b>\n\n🖥 <code>${esc(target.host)}</code>\n• تانل: <code>${esc(facts.zone)}</code>\n• نسخه: <code>${esc(facts.panel_version || 'نامشخص')}</code>\n• سرویس پنل: ${facts.panel_active === '1' ? '🟢 فعال' : '🔴 متوقف'}`, [
          [{ text: '🛠 شروع تعمیر', data: 'maint_go:repair' }],
          [{ text: '🔑 تعمیر همراه با رمز ادمین تازه', data: 'maint_go:repair_reset' }],
          [BTN.cancel],
        ]);
      }
      return show(telegram, chatId, status, `⚠️ <b>حذف پنل از سرور</b>\n\n🖥 <code>${esc(target.host)}</code>\n• تانل: <code>${esc(facts.zone || 'نامشخص')}</code>\n\nسرویس‌ها و باینری‌ها حذف می‌شوند و کاربران پنل قطع می‌شوند. nginx، فایروال و سرویس‌های دیگر شما دست نمی‌خورند.\n\nیک نسخهٔ پشتیبان در <code>/root</code> می‌ماند، حتی در حذف کامل.`, [
        [{ text: '🗑 حذف، با نگه داشتن دیتابیس', data: 'maint_go:keep' }],
        [{ text: '🔥 حذف کامل همراه با دیتابیس', data: 'maint_go:purge' }],
        [BTN.cancel],
      ]);
    } finally {
      session.close();
    }
  }

  async function execute(telegram, chatId, choice) {
    const s = store.getSession(chatId);
    const target = s.target;
    if (!target || !hasCredential(vault, chatId)) {
      return show(telegram, chatId, null, '⚠️ اطلاعات این نشست منقضی شده است. لطفاً دوباره شروع کنید.', [[BTN.repair]]);
    }
    if (!tasks.tryLock(target.host)) return show(telegram, chatId, null, '⏳ عملیات دیگری روی این سرور در حال اجراست.');

    const op = s.maintOp;
    const deployment = s.deploymentId ? store.getDeployment(chatId, s.deploymentId) : null;
    const jobId = store.beginJob(chatId, target.host, op);
    const title = OPS[op].title;
    const message = await show(telegram, chatId, null, renderProgress({ title, host: target.host, stage: 'preflight' }));
    const edits = throttled((stage) => show(telegram, chatId, message, renderProgress({ title, host: target.host, stage })));
    let session;
    try {
      const generated = choice === 'repair_reset' ? generateStrongPassword() : null;
      const connect = connector(app, chatId, target);
      session = await connect();
      const panelDomain = deployment?.panel_domain ?? panelHost(deployment?.panel_url);
      const result = await deps.runJob({
        session,
        connect,
        op,
        attachOnly: choice === 'attach',
        arch: s.facts.arch,
        secret: generated,
        params: op === 'uninstall'
          ? { UNINSTALL_MODE: choice === 'purge' ? 'purge' : 'keep' }
          : {
            PANEL_DOMAIN: panelDomain ?? '',
            PUBLIC_IP: s.facts.public_ip,
            LISTEN_IP: s.facts.listen_ip,
            ADMIN_USER,
            VERSION: PANEL_VERSION,
            BUNDLE_SHA256: panelHash(s.facts.arch),
            RESET_ADMIN: choice === 'repair_reset' ? '1' : '0',
          },
        onEvent(event) { if (event.status === 'start') edits.push(event.stage); },
      });
      session = result.session;
      await edits.finish();

      if (result.status !== 'ok') {
        return show(telegram, chatId, message, renderFailure(result), [[{ text: '🔄 تلاش مجدد', data: 'maint_retry' }], [BTN.cancel]]);
      }
      // The job that ran decides, not the menu: following someone's install from /uninstall must not delete records.
      if (result.op === 'uninstall') return finishUninstall(telegram, chatId, message, { session, target, deployment, result });

      // A password generated here was not used if the job was already running.
      const adminPass = result.attached ? null : generated;

      if (deployment) store.upsertDeployment({ chatId, domain: deployment.domain, vpsIp: target.host, panelUrl: result.panel_url, sshPort: target.port, sshUser: target.user });
      else if (result.zone) store.upsertDeployment({ chatId, domain: result.zone, vpsIp: target.host, panelUrl: result.panel_url, sshPort: target.port, sshUser: target.user });
      store.resetSession(chatId);
      vault.clear(chatId);
      const rows = [];
      if (result.https === 'true' && result.panel_url) rows.push([{ text: '🌐 ورود به پنل', url: result.panel_url }]);
      rows.push([BTN.status]);
      return show(telegram, chatId, message, renderRepairDone({ result, host: target.host, sshUser: target.user, sshPort: target.port, adminUser: ADMIN_USER, adminPass }), rows);
    } catch (err) {
      await edits.finish();
      const text = err.code ? `${esc(failureText(err.code))}\n\n<code>${esc(err.message)}</code>` : esc(err.message);
      return show(telegram, chatId, message, `❌ <b>عملیات متوقف شد</b>\n\n${text}`, [[{ text: '🔄 تلاش مجدد', data: 'maint_retry' }], [BTN.cancel]]);
    } finally {
      session?.close();
      store.finishJob(jobId);
      tasks.unlock(target.host);
    }
  }

  async function finishUninstall(telegram, chatId, message, { session, target, deployment, result }) {
    await deps.cleanupAgentDir(session);
    let dnsNote = '\n\nℹ️ رکوردهای DNS دست نخوردند. می‌توانید با /dns آن‌ها را پاک کنید.';
    const cfAuth = vault.get(chatId, 'cfAuth');
    if (cfAuth && deployment?.zone_id && deployment.zone) {
      try {
        const removed = await deps.cf.deleteOwnedRecords(cfAuth, deployment.zone_id, {
          names: [deployment.zone, deployment.ns_host, deployment.panel_domain].filter(Boolean),
          ip: target.host,
          nsHost: deployment.ns_host,
        });
        dnsNote = `\n\n🧹 ${removed.deleted} رکورد DNS این پنل پاک شد.`;
        if (removed.kept.length) dnsNote += `\nاین رکوردها متعلق به پنل نبودند و نگه داشته شدند: <code>${esc(removed.kept.join(', '))}</code>`;
      } catch (err) {
        dnsNote = `\n\n⚠️ پاک کردن رکوردهای DNS موفق نبود: <code>${esc(err.message)}</code>`;
      }
    }
    if (deployment) store.deleteDeployment(chatId, deployment.id);
    store.resetSession(chatId);
    vault.clear(chatId);
    return show(telegram, chatId, message, `🎉 <b>پنل WhiteDNS از سرور حذف شد.</b>\n\n🖥 <code>${esc(target.host)}</code>\n🗄 نسخهٔ پشتیبان روی سرور: <code>${esc(result.backup)}</code>\n<i>این پوشه شامل کلیدهای پنل است. اگر لازمش ندارید خودتان پاکش کنید.</i>${dnsNote}`, [[{ text: '🚀 نصب مجدد یا جدید', data: 'cmd:start' }]]);
  }

  // ---- commands & buttons --------------------------------------------------------
  const showStatus = (ctx) => {
    const deployments = store.listDeployments(ctx.chat.id);
    return respond(ctx, statusCard(deployments), statusRows(deployments));
  };
  bot.command('status', showStatus);
  action(bot, 'menu:status', showStatus);
  bot.command(['repair', 'fix'], list('repair'));
  action(bot, 'menu:repair', list('repair'));
  bot.command('uninstall', list('uninstall'));
  action(bot, 'menu:uninstall', list('uninstall'));

  action(bot, /^maint:(repair|uninstall):(\d+)$/, (ctx) => {
    const deployment = store.getDeployment(ctx.chat.id, Number(ctx.match[2]));
    if (!deployment) return respond(ctx, '⚠️ این سرور دیگر در فهرست نیست.', [[BTN.status]]);
    return askCredential(ctx, ctx.match[1], { host: deployment.vps_ip, port: deployment.ssh_port ?? 22, user: deployment.ssh_user ?? 'root' }, deployment);
  });
  action(bot, /^maint_manual:(repair|uninstall)$/, (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_MAINT_HOST', maintOp: ctx.match[1], target: null });
    return respond(ctx, '📌 <b>آی‌پی سرور</b> را بفرستید، یا: <code>IP:Port:User:Password</code>', [[BTN.cancel]]);
  });
  action(bot, 'maint_retry', (ctx) => {
    if (!hasCredential(vault, ctx.chat.id)) return respond(ctx, '⚠️ اطلاعات این نشست منقضی شده است. لطفاً دوباره شروع کنید.', [[BTN.repair]]);
    tasks.run(ctx.chat.id, () => confirm(ctx.telegram, ctx.chat.id));
    return undefined;
  });
  action(bot, 'maint_hostkey', (ctx) => {
    const s = store.getSession(ctx.chat.id);
    if (s.pendingFingerprint && s.target) store.setKnownHost(s.target.host, s.target.port, s.pendingFingerprint);
    store.saveSession(ctx.chat.id, { pendingFingerprint: null });
    tasks.run(ctx.chat.id, () => confirm(ctx.telegram, ctx.chat.id));
  });
  action(bot, /^maint_go:(repair|repair_reset|keep|purge|attach)$/, (ctx) => {
    tasks.run(ctx.chat.id, () => execute(ctx.telegram, ctx.chat.id, ctx.match[1]));
  });

  // ---- text steps ----------------------------------------------------------------
  steps.AWAITING_MAINT_HOST = async (ctx, text, s) => {
    const chatId = ctx.chat.id;
    const line = parseServerLine(text);
    if (line) {
      await scrub(ctx);
      if (line.error || !line.password) return respond(ctx, '❌ قالب درست نیست. قالب درست: <code>IP:Port:User:Password</code>', [[BTN.cancel]]);
      storeCredential(vault, chatId, line.password);
      store.saveSession(chatId, { target: { host: line.host, port: line.port, user: line.user }, step: 'PROBING' });
      tasks.run(chatId, () => confirm(ctx.telegram, chatId));
      return undefined;
    }
    if (!isSshHost(text)) return respond(ctx, '❌ لطفاً یک آی‌پی یا نام میزبان معتبر بفرستید:', [[BTN.cancel]]);
    return askCredential(ctx, s.maintOp, { host: text, port: 22, user: 'root' }, null);
  };

  steps.AWAITING_MAINT_PASS = async (ctx, text) => {
    const chatId = ctx.chat.id;
    await scrub(ctx);
    storeCredential(vault, chatId, text);
    store.saveSession(chatId, { step: 'PROBING' });
    tasks.run(chatId, () => confirm(ctx.telegram, chatId));
  };
}

/** The HTTPS name in a stored URL; a loopback address from an install without HTTPS is not one. */
function panelHost(url) {
  try {
    const { hostname } = new URL(url);
    return net.isIP(hostname) ? null : hostname;
  } catch {
    return null;
  }
}
