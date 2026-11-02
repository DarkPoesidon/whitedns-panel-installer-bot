import { escapeHtml as esc } from './validate.js';

/** rows: [[{ text, data } | { text, url }]] */
export function keyboard(rows = []) {
  return {
    inline_keyboard: rows.map((row) => row.map((b) => (b.url ? { text: b.text, url: b.url } : { text: b.text, callback_data: b.data }))),
  };
}

/** Any screen with buttons also leads out of itself, so no step of any flow can be a dead end. */
function withExit(rows) {
  if (!rows.length) return rows;
  const hasExit = rows.flat().some((b) => /^(cancel$|menu:main$|back:)/.test(b.data ?? ''));
  return hasExit ? rows : [...rows, [BTN.menu]];
}

/** Edits a message when possible, otherwise sends a new one. Returns the message id. */
export async function show(telegram, chatId, messageId, text, rows = []) {
  const extra = { parse_mode: 'HTML', link_preview_options: { is_disabled: true }, reply_markup: keyboard(withExit(rows)) };
  if (messageId) {
    try {
      await telegram.editMessageText(chatId, messageId, undefined, text, extra);
      return messageId;
    } catch (err) {
      if (/message is not modified/.test(err.message ?? '')) return messageId;
    }
  }
  const sent = await telegram.sendMessage(chatId, text, extra);
  return sent.message_id;
}

export const BTN = {
  menu: { text: '🏠 منوی اصلی', data: 'menu:main' },
  cancel: { text: '❌ انصراف', data: 'cancel' },
  start: { text: '🚀 نصب پنل جدید', data: 'cmd:start' },
  repair: { text: '🛠 عیب‌یابی و تعمیر سرور', data: 'menu:repair' },
  uninstall: { text: '🗑 حذف یا پاک‌سازی سرور', data: 'menu:uninstall' },
  dns: { text: '⚙️ مدیریت رکوردهای DNS', data: 'cmd:dns' },
  status: { text: '📊 مشاهده وضعیت سرورها', data: 'menu:status' },
};

export const MENU_TEXT = '🏠 <b>منوی اصلی ربات WhiteDNS</b>\n\nیکی از گزینه‌ها را انتخاب کنید:';
export const menuRows = () => [
  [BTN.start],
  [BTN.status],
  [BTN.repair],
  [BTN.uninstall],
  [BTN.dns],
  [{ text: '❓ راهنما', data: 'menu:help' }],
];

export function termsText() {
  return `📜 <b>بیانیه حفظ حریم خصوصی، امنیت اطلاعات و شرایط استفاده</b>

کاربر گرامی، به ربات راه‌اندازی خودکار <b>WhiteDNS Soar Server</b> خوش آمدید.
لطفاً پیش از شروع فرآیند نصب، موارد زیر را مطالعه فرمایید:

🔹 <b>چه اطلاعاتی از شما دریافت می‌شود؟</b>
۱. <b>اطلاعات کلودفلر:</b> توکن API یا کلید سراسری و نام دامنه (برای ساخت رکوردهای DNS تانل).
۲. <b>دسترسی سرور:</b> آی‌پی، پورت SSH، نام کاربری و رمز عبور یا کلید SSH (برای اجرای نصب).

🔒 <b>نحوهٔ نگهداری اطلاعات:</b>
• رمز عبور، کلید SSH و توکن کلودفلر <b>روی دیسک ربات ذخیره نمی‌شوند</b>. این اطلاعات فقط در حافظهٔ موقت می‌مانند و حداکثر ۳۰ دقیقه بعد، یا با پایان موفق عملیات، پاک می‌شوند.
• پیام‌های حاوی رمز بلافاصله از چت حذف می‌شوند. اگر حذف ممکن نباشد به شما اطلاع داده می‌شود.
• آدرس پنل، دامنه و آی‌پی سرور برای نمایش در /status ذخیره می‌شوند.
• اگر این ربات را شخص دیگری اجرا می‌کند، اطلاعات شما از سرور او عبور می‌کند. فقط به ربات مورد اعتماد خود اطلاعات بدهید.
• باینری‌ها از مخزن رسمی WhiteDNS دانلود و با هش بررسی می‌شوند.
• کد این ربات و اسکریپت‌های نصب متن‌باز است.

⚠️ <i>با انتخاب «شرایط را می‌پذیرم»، تأیید می‌کنید که مالک سرور و دامنه هستید و به ربات اجازهٔ اتصال و نصب می‌دهید.</i>`;
}

export const HELP_TEXT = `📖 <b>راهنمای ربات نصب خودکار WhiteDNS</b>

🔹 <b>پیش‌نیازها:</b>
۱. سرور با Ubuntu 22/24/26 یا Debian 12/13 (amd64 یا arm64) و یک IPv4 عمومی.
۲. یک دامنه در کلودفلر.
۳. باز بودن پورت‌های UDP و TCP شماره ۵۳، و TCP شماره ۸۰ و ۴۴۳ در فایروال پرووایدر.

🔹 <b>دستورات:</b>
• /start - منوی اصلی
• /status - پنل‌ها و لینک‌ها
• /repair - عیب‌یابی و تعمیر
• /dns - مدیریت رکوردهای DNS
• /uninstall - حذف پنل از سرور
• /reset - لغو عملیات جاری
• /id - نمایش شناسهٔ چت شما`;

// ---- agent codes -> Persian ---------------------------------------------------
const FAILURES = {
  NOT_ROOT: 'اسکریپت به دسترسی root نیاز دارد.',
  NO_SYSTEMD: 'این سرور systemd ندارد (کانتینرهای بدون systemd پشتیبانی نمی‌شوند).',
  UNSUPPORTED_OS: 'سیستم‌عامل پشتیبانی نمی‌شود. Ubuntu 22/24/26 یا Debian 12/13 لازم است.',
  UNSUPPORTED_ARCH: 'معماری پردازنده پشتیبانی نمی‌شود. فقط amd64 و arm64.',
  NO_DISK: 'حداقل ۲۰۰ مگابایت فضای خالی لازم است.',
  BUSY: 'عملیات دیگری روی پنل این سرور در حال اجراست. کمی بعد دوباره تلاش کنید.',
  NOT_INSTALLED: 'پنلی روی این سرور نصب نیست. از /start برای نصب استفاده کنید.',
  NO_LOCAL_IP: 'آی‌پی محلی مناسب روی سرور پیدا نشد.',
  ZONE_MISMATCH: 'دیتابیس پنل به دامنهٔ دیگری تعلق دارد.',
  ZONE_TOO_LONG: 'نام تانل از سقف ۲۴ کاراکتر پنل بلندتر است.',
  OLD_SOAR: 'سرویس مستقل soar-server روی سرور فعال است و باید مهاجرت را تأیید کنید.',
  PORT53_BUSY: 'پورت ۵۳ در اختیار سرویس دیگری است. آن سرویس تغییر داده نشد. لطفاً آن را خودتان متوقف کنید یا از سرور دیگری استفاده کنید.',
  PANEL_PORT_BUSY: 'هیچ‌کدام از پورت‌های مدیریت پنل آزاد نیست.',
  MISSING_TOOL: 'یکی از ابزارهای پایهٔ سیستم وجود ندارد.',
  APT_FAILED: 'نصب بسته‌های لازم با apt شکست خورد.',
  CHECKSUM_MISMATCH: 'هش فایل دانلودشده درست نبود و فایل نصب نشد.',
  CHECKSUM_UNAVAILABLE: 'فایل هش از گیت‌هاب دریافت نشد.',
  NEED_BUNDLE: 'سرور به گیت‌هاب دسترسی ندارد و آپلود باندل هم موفق نشد.',
  BUNDLE_INVALID: 'باندل پنل ناقص یا خراب است.',
  PANEL_INIT_FAILED: 'ساخت دیتابیس پنل شکست خورد.',
  ADMIN_RESET_FAILED: 'تغییر رمز ادمین شکست خورد.',
  ACCESS_FAILED: 'تنظیم آدرس خصوصی پنل شکست خورد.',
  FIREWALL_FAILED: 'تنظیم فایروال UFW شکست خورد.',
  OPS_START_FAILED: 'سرویس نگهداری پنل بالا نیامد.',
  PANEL_UNHEALTHY: 'سرویس پنل به حالت سالم نرسید.',
  DNS_LISTENER_MISSING: 'پنل روی پورت DNS گوش نمی‌دهد.',
  JOB_INVALID: 'پارامترهای نصب نامعتبر بودند.',
  JOB_MISSING: 'فایل کار روی سرور پیدا نشد.',
  UNEXPECTED: 'خطای پیش‌بینی‌نشده روی سرور رخ داد.',
  // SSH layer
  AUTH_FAILED: 'نام کاربری یا رمز/کلید SSH اشتباه است، یا ورود این کاربر روی سرور بسته است.',
  REFUSED: 'پورت SSH روی سرور بسته است یا سرویس SSH اجرا نمی‌شود.',
  TIMEOUT: 'اتصال به سرور زمان‌بر شد. آی‌پی، پورت و فایروال را بررسی کنید.',
  DNS: 'نام میزبان سرور پیدا نشد.',
  UNREACHABLE: 'مسیری تا سرور وجود ندارد.',
  BAD_KEY: 'کلید SSH نامعتبر است یا رمز عبور دارد. کلید بدون passphrase بفرستید.',
  CONNECT_FAILED: 'اتصال SSH برقرار نشد.',
  PRIVATE_TARGET: 'این آدرس عمومی نیست. ربات فقط به سرورهای دارای آدرس عمومی وصل می‌شود.',
  RATE_LIMITED: 'تعداد تلاش‌های اتصال زیاد بوده است. لطفاً ۱۵ دقیقهٔ دیگر دوباره تلاش کنید.',
  SUDO_FAILED: 'کاربر دسترسی sudo ندارد، یا sudo روی این سرور به tty نیاز دارد. با کاربر root وارد شوید.',
  EXEC_FAILED: 'سرور اجرای دستور را نپذیرفت.',
  COMMAND_TIMEOUT: 'اجرای دستور روی سرور بیش از حد طول کشید.',
  PROBE_FAILED: 'بررسی اولیهٔ سرور شکست خورد.',
  JOB_START_FAILED: 'شروع عملیات روی سرور شکست خورد.',
  LOST_CONNECTION: 'ارتباط با سرور قطع شد. عملیات روی سرور ادامه دارد؛ چند دقیقهٔ دیگر با /repair نتیجه را ببینید.',
  NO_RESULT: 'نتیجهٔ عملیات از سرور دریافت نشد.',
  BUNDLE_DOWNLOAD_FAILED: 'ربات هم نتوانست باندل پنل را از گیت‌هاب دریافت کند.',
};

const WARNINGS = {
  NO_PANEL_DOMAIN: 'دامنه‌ای برای پنل تعیین نشد و HTTPS فعال نشد.',
  DNS_NOT_READY: 'رکورد دامنهٔ پنل هنوز به این سرور نمی‌رسد و HTTPS فعال نشد. چند دقیقهٔ دیگر /repair را بزنید.',
  HTTPS_PORTS_BUSY: 'پورت ۸۰ یا ۴۴۳ در اختیار سرویس دیگری است و HTTPS فعال نشد.',
  CERT_FAILED: 'گواهی HTTPS صادر نشد. پورت‌های ۸۰ و ۴۴۳ را در فایروال پرووایدر بررسی کنید و با /repair دوباره تلاش کنید.',
  CERT_STALLED: `گواهی دوم پنل (ECDSA) از Let's Encrypt نرسید و HTTPS برگردانده شد. معمولاً علت این است که برای همین نام در هفتهٔ اخیر چند گواهی صادر شده است؛ مثلاً با چند بار نصب و حذف. چند ساعت یا چند روز بعد با /repair دوباره تلاش کنید.`,
  PUBLIC_ACCESS_FAILED: 'باز کردن پنل روی IP سرور موفق نبود، پس پنل فقط از راه تونل SSH باز می‌شود.',
  CHECK_TOOL_MISSING: 'ابزار تست تانل پیدا نشد و تانل آزمایش نشد.',
  PROBE_FAILED: 'حساب تست ساخته نشد و تانل آزمایش نشد.',
  TUNNEL_LOCAL_FAILED: 'تست محلی تانل Soar موفق نبود. دسترسی سرور به اینترنت را بررسی کنید.',
  COTTEN_LOCAL_FAILED: 'تست محلی موتور Cotten موفق نبود.',
  MASTERDNS_LOCAL_FAILED: 'تست محلی موتور MasterDNS موفق نبود.',
  TUNNEL_RECURSIVE_FAILED: 'تانل از بیرون سرور جواب نداد. احتمالاً UDP/53 در فایروال پرووایدر بسته است یا رکوردهای NS هنوز منتشر نشده‌اند.',
};

export const failureText = (code) => FAILURES[code] ?? `خطا: ${code}`;
export const warningText = (code) => WARNINGS[code] ?? code;

const STAGES = [
  ['preflight', 'بررسی سرور و پیش‌نیازها'],
  ['deps', 'نصب ابزارهای لازم'],
  ['fetch', 'دریافت و بررسی هش باندل رسمی'],
  ['activate', 'نصب و راه‌اندازی سرویس‌های پنل'],
  ['https', 'فعال‌سازی HTTPS پنل (تا ۷ دقیقه)'],
  ['verify', 'آزمایش واقعی تانل'],
];

export function renderProgress({ title, host, domain, stage, note }) {
  const current = STAGES.findIndex(([id]) => id === stage);
  let text = `⚙️ <b>${esc(title)}</b>\n\n`;
  if (domain) text += `🌐 دامنه: <code>${esc(domain)}</code>\n`;
  if (host) text += `🖥 سرور: <code>${esc(host)}</code>\n\n`;
  STAGES.forEach(([, label], index) => {
    if (index < current) text += `✅ ${label}\n`;
    else if (index === current) text += `🔄 <b>${label}</b>\n`;
    else text += `⏳ ${label}\n`;
  });
  if (note) text += `\n💬 <i>${esc(note)}</i>\n`;
  text += '\n<i>کار روی خود سرور اجرا می‌شود و با قطع ارتباط متوقف نمی‌شود. معمولاً ۲ تا ۶ دقیقه طول می‌کشد، ولی اگر گرفتن گواهی کند باشد تا ۱۲ دقیقه هم ممکن است.</i>';
  return text;
}

function renderWarnings(result) {
  if (!result.warnings?.length) return '';
  const lines = result.warnings.map((w) => {
    const detail = result[`warning_detail_${w}`];
    return `• ${esc(warningText(w))}${detail ? `\n<code>${esc(detail)}</code>` : ''}`;
  });
  return `\n\n⚠️ <b>نیازمند توجه:</b>\n${lines.join('\n')}`;
}

/** The URL or, without public HTTPS, the SSH tunnel that reaches the panel. */
export function renderAccess({ result, host, sshUser, sshPort }) {
  const url = result.panel_url ?? '';
  if (result.https === 'true') return `🌐 <b>آدرس ورود به پنل:</b>\n${esc(url)}`;
  const port = (result.panel_bind ?? '').split(':').pop() || '2053';
  if (result.public_http === '1') {
    return `🌐 <b>آدرس ورود به پنل (با IP سرور):</b>\n${esc(url)}\n\n⚠️ این اتصال HTTP است و رمزنگاری ندارد، پس رمز شما روی شبکه محافظت نمی‌شود. فعلاً از وای‌فای عمومی وارد نشوید.\nاگر باز نشد، پورت <code>${esc(port)}</code> را در فایروال پرووایدر باز کنید. با /repair دوباره برای HTTPS تلاش کنید.`;
  }
  const portFlag = sshPort && Number(sshPort) !== 22 ? `-p ${sshPort} ` : '';
  return `🔒 <b>HTTPS فعال نشد و پنل فقط از داخل خود سرور باز می‌شود.</b>\nآدرس با IP سرور باز نمی‌شود و این عمدی است، چون بدون HTTPS رمز شما رمزنگاری نمی‌شود.\n\nفعلاً این دستور را روی کامپیوتر خود اجرا کنید و تا پایان کار باز نگه دارید:\n<code>ssh -N -L ${esc(port)}:127.0.0.1:${esc(port)} ${portFlag}${esc(sshUser)}@${esc(host)}</code>\n\nسپس این آدرس را در مرورگر باز کنید:\n${esc(url)}`;
}

// The password of a job the bot only followed left its memory, e.g. with a restart.
const LOST_PASSWORD = '🔑 رمز ادمین در این عملیات تنظیم شد، ولی ربات دیگر آن را ندارد. با /repair و گزینهٔ «رمز ادمین تازه» رمز جدید بگیرید.';

export function renderInstallDone({ result, host, sshUser, sshPort, adminUser, adminPass, plan }) {
  const verified = !result.warnings.some((w) => /FAILED|MISSING|STALLED/.test(w));
  let text = '🎉 <b>پنل WhiteDNS نصب و آزمایش شد.</b>';
  if (result.public_http === '1') text = '🟡 <b>پنل نصب شد و با IP سرور باز می‌شود، ولی HTTPS فعال نشد.</b>';
  else if (result.https !== 'true') text = '🟡 <b>پنل نصب شد، ولی هنوز از اینترنت باز نمی‌شود.</b>';
  else if (!verified) text = '🟡 <b>پنل نصب شد، ولی همهٔ آزمایش‌ها موفق نبودند.</b>';
  text += `\n\n${renderAccess({ result, host, sshUser, sshPort })}`;
  if (result.admin_changed === '1' && adminPass) {
    text += `\n\n👤 <b>نام کاربری:</b> <code>${esc(adminUser)}</code>\n🔑 <b>رمز عبور:</b> <code>${esc(adminPass)}</code>\n<i>رمز را ذخیره و بعد این پیام را حذف کنید. ربات آن را نگه نمی‌دارد.</i>`;
  } else if (result.admin_changed === '1') {
    text += `\n\n${LOST_PASSWORD}`;
  } else {
    text += '\n\n🔑 <b>رمز ادمین تغییر نکرد</b> و حساب‌ها و اطلاعات قبلی پنل حفظ شدند.';
  }
  if (plan) {
    text += `\n\n🖥 <b>اطلاعات تانل:</b>\n• زیردامنهٔ تانل: <code>${esc(plan.zone)}</code>\n• نیم‌سرور: <code>${esc(plan.nsHost)}</code>`;
  }
  if (result.version) text += `\n• نسخه: <code>${esc(result.version)}</code>`;
  return text + renderWarnings(result);
}

export function renderRepairDone({ result, host, sshUser, sshPort, adminUser, adminPass }) {
  let text = result.warnings.length
    ? '🟡 <b>تعمیر انجام شد، ولی چند مورد باقی مانده است.</b>'
    : '✅ <b>سرور سالم است و تانل آزمایش شد.</b>';
  text += `\n\n🖥 <code>${esc(host)}</code>\n\n${renderAccess({ result, host, sshUser, sshPort })}`;
  if (result.admin_changed === '1' && adminPass) {
    text += `\n\n👤 <code>${esc(adminUser)}</code>\n🔑 <code>${esc(adminPass)}</code>\n<i>رمز را ذخیره و بعد این پیام را حذف کنید.</i>`;
  } else if (result.admin_changed === '1') {
    text += `\n\n${LOST_PASSWORD}`;
  }
  return text + renderWarnings(result);
}

export function renderFailure({ code, detail, status, backup }) {
  let text = `❌ <b>عملیات متوقف شد</b>\n\n${esc(failureText(code))}`;
  if (detail && code !== 'ZONE_MISMATCH') text += `\n\n<code>${esc(detail)}</code>`;
  if (status === 'rolled_back') text += '\n\n↩️ سرور به حالت قبل از نصب برگردانده شد.';
  if (status === 'rollback_incomplete') {
    text += `\n\n⚠️ <b>بازگشت به حالت قبل کامل نشد.</b> نسخهٔ پشتیبان روی سرور: <code>${esc(backup)}</code>`;
  }
  return text;
}

const ACTION_LABEL = { create: 'ساخت', update: 'تغییر', keep: 'بدون تغییر' };

export function renderConfirm({ domain, host, sshPort, sshUser, facts, plan, fingerprint }) {
  let text = `📋 <b>خلاصهٔ پیکربندی</b>\n\n• دامنه: <code>${esc(domain)}</code>\n• سرور: <code>${esc(host)}</code> (پورت <code>${esc(sshPort)}</code>، کاربر <code>${esc(sshUser)}</code>)\n• سیستم‌عامل: <code>${esc(facts.os)}</code> (<code>${esc(facts.arch)}</code>)\n• آی‌پی عمومی: <code>${esc(facts.public_ip)}</code>`;
  if (facts.listen_ip && facts.listen_ip !== facts.public_ip) {
    text += `\n• آی‌پی محلی (NAT): <code>${esc(facts.listen_ip)}</code>`;
  }
  text += `\n\n🌐 <b>رکوردهای DNS:</b>\n${plan.changes.map((c) => `• ${ACTION_LABEL[c.action]}: <code>${esc(c.type)} ${esc(c.name)} ← ${esc(c.content)}</code>`).join('\n')}`;
  if (plan.renamed) text += '\n\n💡 نام‌های استاندارد روی این دامنه اشغال بودند، پس برای حفظ سرویس‌های فعلی شما نام‌های بالا انتخاب شدند.';
  if (plan.moves.length) {
    text += `\n\n⚠️ <b>این رکوردها از مقدار فعلی تغییر می‌کنند:</b>\n${plan.moves.map((m) => `• <code>${esc(m.name)}</code>: <code>${esc(m.current.content)}</code> ← <code>${esc(m.content)}</code>`).join('\n')}`;
  }
  if (facts.installed === '1') text += `\n\n♻️ <b>پنل قبلی روی این سرور پیدا شد</b> (<code>${esc(facts.zone)}</code>). حساب‌ها و آدرس خصوصی حفظ می‌شوند.`;
  if (facts.old_soar === '1') text += '\n\n⚠️ <b>سرویس مستقل soar-server فعال است.</b> با ادامه، این سرویس متوقف می‌شود و پروفایل‌های قدیمی آن از کار می‌افتند. باید برای کاربران لینک تازه بسازید.';
  // The nginx this bot itself installed earlier gets retired, so it is no obstacle.
  if ((facts.port80 || facts.port443) && facts.legacy_nginx !== '1') text += `\n\n⚠️ پورت ۸۰ یا ۴۴۳ در اختیار <code>${esc(facts.port80 || facts.port443)}</code> است، پس HTTPS فعال نمی‌شود و پنل از راه تونل SSH باز می‌شود.`;
  if (fingerprint) text += `\n\n🔐 اثرانگشت کلید سرور:\n<code>SHA256:${esc(fingerprint)}</code>`;
  return text;
}
