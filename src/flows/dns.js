import { CF_TEMPLATE_URL } from '../config.js';
import { BTN } from '../ui.js';
import { escapeHtml as esc } from '../validate.js';
import { action, respond, scrub } from './common.js';

const PAGE_SIZE = 5;
const ZONE_PAGE = 8;

/** Cloudflare DNS record manager. Record ids stay in memory; buttons carry only a short index. */
export function dnsFlow({ bot, app, zoneCache }) {
  const { store, vault, deps, steps } = app;
  const state = new Map();
  const st = (chatId) => state.get(chatId) ?? {};
  const patch = (chatId, fields) => state.set(chatId, { ...st(chatId), ...fields });
  const auth = (chatId) => vault.get(chatId, 'cfAuth');

  const askAuth = (ctx) => {
    store.saveSession(ctx.chat.id, { step: 'AWAITING_DNS_CF_AUTH' });
    return respond(ctx, '⚙️ <b>مدیریت رکوردهای DNS کلودفلر</b>\n\nلطفاً <b>توکن API</b> یا <code>email:GlobalKey</code> را بفرستید:', [
      [{ text: '🚀 ساخت توکن در کلودفلر', url: CF_TEMPLATE_URL }],
      [BTN.cancel],
    ]);
  };

  async function renderZones(ctx, page = 0) {
    const zones = await deps.cf.listZones(auth(ctx.chat.id));
    if (!zones.ok || !zones.zones.length) {
      return respond(ctx, `⚠️ <b>دامنه‌ای پیدا نشد.</b>\n${esc(zones.error ?? '')}`, [[BTN.cancel]]);
    }
    zoneCache.set(ctx.chat.id, zones.zones);
    const start = page * ZONE_PAGE;
    const rows = zones.zones.slice(start, start + ZONE_PAGE).map((z, i) => [{ text: `🌐 ${z.name}`, data: `cf_zone:${start + i}` }]);
    const nav = [];
    if (page > 0) nav.push({ text: '◀️ قبلی', data: `cf_zones:${page - 1}` });
    if (start + ZONE_PAGE < zones.zones.length) nav.push({ text: 'بعدی ▶️', data: `cf_zones:${page + 1}` });
    if (nav.length) rows.push(nav);
    rows.push([BTN.cancel]);
    return respond(ctx, '🌐 <b>مدیریت رکوردهای DNS</b>\n\n👇 دامنه را انتخاب کنید:', rows);
  }

  async function renderManager(ctx, page = 1, notice = '') {
    const chatId = ctx.chat.id;
    const session = store.getSession(chatId);
    const { zoneId, domain } = session;
    if (!auth(chatId) || !zoneId) return askAuth(ctx);

    const res = await deps.cf.listDnsRecords(auth(chatId), zoneId, 1, 100);
    if (!res.ok) {
      return respond(ctx, `❌ <b>خطا در دریافت رکوردها:</b>\n<code>${esc(res.error)}</code>`, [[{ text: '🔄 تلاش مجدد', data: 'cf_dns' }], [BTN.cancel]]);
    }
    const all = res.records;
    const pages = Math.ceil(all.length / PAGE_SIZE) || 1;
    const current = Math.min(Math.max(1, page), pages);
    const start = (current - 1) * PAGE_SIZE;
    const records = all.slice(start, start + PAGE_SIZE);
    patch(chatId, { records, page: current });

    let text = `⚙️ <b>رکوردهای DNS دامنه</b> <code>${esc(domain)}</code>\n📊 کل: <b>${all.length}</b> (صفحه ${current} از ${pages})\n\n`;
    if (notice) text += `🔔 ${esc(notice)}\n\n`;
    if (!records.length) text += '<i>رکوردی ثبت نشده است.</i>\n';
    records.forEach((r, i) => {
      const value = r.content?.length > 25 ? `${r.content.slice(0, 22)}...` : r.content;
      text += `${start + i + 1}. <code>[${esc(r.type)}]</code> <code>${esc(r.name)}</code>\n   ← <code>${esc(value)}</code> (${r.proxied ? '☁️ Proxied' : '🔘 DNS Only'})\n`;
    });

    const rows = records.map((r, i) => [
      { text: `✏️ ویرایش #${start + i + 1} (${r.type})`, data: `cf_edit:${i}` },
      { text: `🗑 حذف #${start + i + 1}`, data: `cf_del:${i}` },
    ]);
    const nav = [];
    if (current > 1) nav.push({ text: '◀️ قبلی', data: `cf_page:${current - 1}` });
    if (current < pages) nav.push({ text: 'بعدی ▶️', data: `cf_page:${current + 1}` });
    if (nav.length) rows.push(nav);
    rows.push([{ text: '➕ افزودن رکورد', data: 'cf_add' }, { text: '🧹 پاک‌سازی رکوردهای تانل', data: 'cf_clean' }]);
    rows.push([{ text: '🚀 ادامه نصب پنل', data: 'cf_continue' }, { text: '🔙 لیست دامنه‌ها', data: 'cmd:dns' }]);
    return respond(ctx, text, rows);
  }

  const openDns = (ctx) => (auth(ctx.chat.id) ? renderZones(ctx) : askAuth(ctx));
  bot.command(['dns', 'cloudflare'], openDns);
  action(bot, 'cmd:dns', openDns);
  action(bot, 'cf_dns', (ctx) => renderManager(ctx));
  action(bot, /^cf_zones:(\d+)$/, (ctx) => renderZones(ctx, Number(ctx.match[1])));
  action(bot, /^cf_zone:(\d+)$/, (ctx) => {
    const zone = zoneCache.get(ctx.chat.id)?.[Number(ctx.match[1])];
    if (!zone) return openDns(ctx);
    store.saveSession(ctx.chat.id, { zoneId: zone.id, domain: zone.name });
    return renderManager(ctx);
  });
  action(bot, /^cf_page:(\d+)$/, (ctx) => renderManager(ctx, Number(ctx.match[1])));

  action(bot, 'cf_add', (ctx) => respond(ctx, `➕ <b>رکورد جدید برای</b> <code>${esc(store.getSession(ctx.chat.id).domain)}</code>\n\nنوع رکورد را انتخاب کنید:`, [
    [{ text: '📌 A', data: 'cf_add_type:A' }, { text: '🔗 CNAME', data: 'cf_add_type:CNAME' }],
    [{ text: '🌐 NS', data: 'cf_add_type:NS' }, { text: '📝 TXT', data: 'cf_add_type:TXT' }],
    [{ text: '🔙 بازگشت', data: 'cf_dns' }],
  ]));
  action(bot, /^cf_add_type:(A|CNAME|NS|TXT)$/, (ctx) => {
    patch(ctx.chat.id, { type: ctx.match[1] });
    store.saveSession(ctx.chat.id, { step: 'AWAITING_DNS_ADD_NAME' });
    return respond(ctx, `➕ <b>رکورد [${esc(ctx.match[1])}]</b>\n\n📌 <b>نام یا ساب‌دامنه</b> را بفرستید (مثلاً <code>panel</code> یا <code>@</code>):`, [[{ text: '❌ بازگشت', data: 'cf_dns' }]]);
  });

  async function createRecord(ctx, proxied) {
    const chatId = ctx.chat.id;
    const { type, name, content } = st(chatId);
    const { zoneId } = store.getSession(chatId);
    store.saveSession(chatId, { step: 'IDLE' });
    if (!auth(chatId) || !type || !name || !content) return respond(ctx, '⚠️ اطلاعات رکورد منقضی شده است.', [[{ text: '🔙 بازگشت', data: 'cf_dns' }]]);
    const res = await deps.cf.createDnsRecord(auth(chatId), zoneId, { type, name, content, proxied });
    if (!res.ok) return respond(ctx, `❌ <b>خطا در ثبت رکورد:</b>\n<code>${esc(res.error)}</code>`, [[{ text: '🔙 بازگشت', data: 'cf_dns' }]]);
    return renderManager(ctx, 1, `رکورد [${type}] ${name} ثبت شد.`);
  }
  action(bot, /^cf_add_proxy:([01])$/, (ctx) => createRecord(ctx, ctx.match[1] === '1'));

  const recordAt = (ctx) => st(ctx.chat.id).records?.[Number(ctx.match[1])];
  const gone = (ctx) => respond(ctx, '❌ رکورد پیدا نشد.', [[{ text: '🔙 بازگشت', data: 'cf_dns' }]]);

  action(bot, /^cf_del:(\d+)$/, (ctx) => {
    const r = recordAt(ctx);
    if (!r) return gone(ctx);
    return respond(ctx, `⚠️ <b>تأیید حذف رکورد:</b>\n\n• نوع: <code>${esc(r.type)}</code>\n• نام: <code>${esc(r.name)}</code>\n• مقدار: <code>${esc(r.content)}</code>\n\nاز حذف دائمی این رکورد مطمئن هستید؟`, [
      [{ text: '🗑 بله، حذف شود', data: `cf_del_ok:${ctx.match[1]}` }],
      [{ text: '❌ خیر', data: 'cf_dns' }],
    ]);
  });
  action(bot, /^cf_del_ok:(\d+)$/, async (ctx) => {
    const r = recordAt(ctx);
    if (!r) return gone(ctx);
    const res = await deps.cf.deleteDnsRecord(auth(ctx.chat.id), store.getSession(ctx.chat.id).zoneId, r.id);
    if (!res.ok) return respond(ctx, `❌ خطا در حذف رکورد: <code>${esc(res.error)}</code>`, [[{ text: '🔙 بازگشت', data: 'cf_dns' }]]);
    return renderManager(ctx, st(ctx.chat.id).page, 'رکورد حذف شد.');
  });
  action(bot, /^cf_edit:(\d+)$/, (ctx) => {
    const r = recordAt(ctx);
    if (!r) return gone(ctx);
    const rows = [[{ text: '✏️ تغییر مقدار', data: `cf_edit_val:${ctx.match[1]}` }]];
    if (['A', 'AAAA', 'CNAME'].includes(r.type)) {
      rows.push([{ text: r.proxied ? '🔘 خاموش کردن پروکسی' : '☁️ روشن کردن پروکسی', data: `cf_proxy:${ctx.match[1]}` }]);
    }
    rows.push([{ text: '🔙 بازگشت', data: 'cf_dns' }]);
    return respond(ctx, `✏️ <b>ویرایش رکورد:</b>\n\n• نوع: <code>${esc(r.type)}</code>\n• نام: <code>${esc(r.name)}</code>\n• مقدار: <code>${esc(r.content)}</code>\n• پروکسی: ${r.proxied ? '☁️ روشن' : '🔘 خاموش'}`, rows);
  });
  action(bot, /^cf_proxy:(\d+)$/, async (ctx) => {
    const r = recordAt(ctx);
    if (!r) return gone(ctx);
    const res = await deps.cf.updateDnsRecord(auth(ctx.chat.id), store.getSession(ctx.chat.id).zoneId, r.id, { proxied: !r.proxied });
    return renderManager(ctx, st(ctx.chat.id).page, res.ok ? 'وضعیت پروکسی تغییر کرد.' : res.error);
  });
  action(bot, /^cf_edit_val:(\d+)$/, (ctx) => {
    const r = recordAt(ctx);
    if (!r) return gone(ctx);
    patch(ctx.chat.id, { editing: r });
    store.saveSession(ctx.chat.id, { step: 'AWAITING_DNS_EDIT_VAL' });
    return respond(ctx, `✏️ <b>مقدار جدید</b> رکورد <code>${esc(r.name)}</code> را بفرستید:\n<i>(فعلی: <code>${esc(r.content)}</code>)</i>`, [[{ text: '❌ بازگشت', data: 'cf_dns' }]]);
  });

  // Only records of the panel are removed; a website on panel.<domain> stays.
  action(bot, 'cf_clean', async (ctx) => {
    const chatId = ctx.chat.id;
    const { zoneId, domain } = store.getSession(chatId);
    const deployment = store.listDeployments(chatId).find((d) => d.domain === domain);
    const names = deployment?.zone
      ? [deployment.zone, deployment.ns_host, deployment.panel_domain].filter(Boolean)
      : ['soar', 'ns-soar', 'panel'].map((label) => `${label}.${domain}`);
    try {
      const out = await deps.cf.deleteOwnedRecords(auth(chatId), zoneId, {
        names,
        ip: deployment?.vps_ip,
        nsHost: deployment?.ns_host ?? `ns-soar.${domain}`,
      });
      const kept = out.kept.length ? ` نگه داشته‌شده: ${out.kept.join(', ')}` : '';
      return renderManager(ctx, 1, `${out.deleted} رکورد تانل پاک شد.${kept}`);
    } catch (err) {
      return renderManager(ctx, 1, `خطا: ${err.message}`);
    }
  });

  steps.AWAITING_DNS_CF_AUTH = async (ctx, text) => {
    await scrub(ctx);
    const verify = await deps.cf.verifyToken(text);
    if (!verify.ok) {
      return respond(ctx, `❌ <b>توکن نامعتبر است:</b>\n<code>${esc(verify.error)}</code>\n\nتوکن دیگری بفرستید:`, [
        [{ text: '🚀 ساخت توکن در کلودفلر', url: CF_TEMPLATE_URL }],
        [BTN.cancel],
      ]);
    }
    vault.set(ctx.chat.id, { cfAuth: verify.resolvedAuth });
    store.saveSession(ctx.chat.id, { step: 'IDLE' });
    return renderZones(ctx);
  };
  steps.AWAITING_DNS_ADD_NAME = (ctx, text) => {
    patch(ctx.chat.id, { name: text });
    store.saveSession(ctx.chat.id, { step: 'AWAITING_DNS_ADD_CONTENT' });
    return respond(ctx, `📌 نام: <code>${esc(text)}</code>\n\n<b>مقدار</b> رکورد را بفرستید:`, [[{ text: '❌ بازگشت', data: 'cf_dns' }]]);
  };
  steps.AWAITING_DNS_ADD_CONTENT = (ctx, text) => {
    patch(ctx.chat.id, { content: text });
    const { type, name } = st(ctx.chat.id);
    if (type === 'NS' || type === 'TXT') return createRecord(ctx, false);
    store.saveSession(ctx.chat.id, { step: 'AWAITING_DNS_ADD_PROXY' });
    return respond(ctx, `🌐 <b>پروکسی کلودفلر برای</b> <code>${esc(name)}</code>\n<i>برای پنل و تانل WhiteDNS، پروکسی باید خاموش باشد.</i>`, [
      [{ text: '🔘 خاموش (DNS Only)', data: 'cf_add_proxy:0' }],
      [{ text: '☁️ روشن (Proxied)', data: 'cf_add_proxy:1' }],
      [{ text: '❌ بازگشت', data: 'cf_dns' }],
    ]);
  };
  steps.AWAITING_DNS_EDIT_VAL = async (ctx, text) => {
    const chatId = ctx.chat.id;
    const { editing, page } = st(chatId);
    store.saveSession(chatId, { step: 'IDLE' });
    if (!editing) return respond(ctx, '⚠️ جلسهٔ ویرایش منقضی شده است.', [[{ text: '🔙 بازگشت', data: 'cf_dns' }]]);
    const res = await deps.cf.updateDnsRecord(auth(chatId), store.getSession(chatId).zoneId, editing.id, { content: text });
    if (!res.ok) return respond(ctx, `❌ <b>خطا:</b>\n<code>${esc(res.error)}</code>`, [[{ text: '🔙 بازگشت', data: 'cf_dns' }]]);
    return renderManager(ctx, page, `مقدار رکورد به ${text} تغییر کرد.`);
  };
}
