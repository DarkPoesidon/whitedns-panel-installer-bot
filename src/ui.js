/**
 * Generates a strong, random ASCII password (16 chars) suitable for Soar panel admin
 * Shell-safe: uses only unambiguous alphanumeric characters [A-Za-z0-9] without '$' or quotes
 */
export function generateStrongPassword(length = 16) {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower = 'abcdefghjkmnpqrstuvwxyz';
  const digits = '23456789';
  const all = upper + lower + digits;

  const result = [
    upper[Math.floor(Math.random() * upper.length)],
    lower[Math.floor(Math.random() * lower.length)],
    digits[Math.floor(Math.random() * digits.length)],
    lower[Math.floor(Math.random() * lower.length)]
  ];

  for (let i = 4; i < length; i++) {
    result.push(all[Math.floor(Math.random() * all.length)]);
  }

  // Modern Fisher-Yates shuffle for uniform distribution
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }

  return result.join('');
}

/**
 * Visual Progress Box renderer for Telegram chat during real SSH installation
 */
export function renderProgressBox(currentStep, totalSteps = 7, domain = '', ip = '', statusText = '') {
  const steps = [
    { num: 1, title: 'اتصال SSH به سرور و حل تداخل پورت ۵۳' },
    { num: 2, title: 'نصب بسته‌های سیستمی و نیازمندی‌ها' },
    { num: 3, title: 'دانلود باینری رسمی WhiteDNS و اعتبارسنجی SHA256' },
    { num: 4, title: 'راه‌اندازی دیتابیس، کاربر سیستمی و فایروال' },
    { num: 5, title: 'پیکربندی و راه‌اندازی سرویس‌های daemon' },
    { num: 6, title: 'پیکربندی دامنه اختصاصی و گواهی امنیتی SSL' },
    { num: 7, title: 'استخراج آدرس اختصاصی و نهایی پنل' },
  ];

  let text = '⚙️ **در حال نصب خودکار WhiteDNS Soar Server بر روی سرور شما...**\n\n';
  if (domain) text += `🌐 دامنه: \`${domain}\`\n`;
  if (ip) text += `🖥 آی‌پی سرور: \`${ip}\`\n\n`;

  for (const s of steps) {
    if (s.num < currentStep) {
      text += `[✅] مرحله ${s.num}: ${s.title}\n`;
    } else if (s.num === currentStep) {
      text += `[🔄] **مرحله ${s.num}: ${s.title}**...\n`;
    } else {
      text += `[⏳] مرحله ${s.num}: ${s.title}\n`;
    }
  }

  if (statusText) {
    text += `\n💬 وضعیت لحظه‌ای سرور:\n_${statusText}_\n`;
  }

  text += '\n⚠️ _این فرآیند روی سرور شما اجرا می‌شود و حدود ۶۰ تا ۹۰ ثانیه زمان می‌برد._';
  return text;
}

/**
 * Final Delivery Card renderer with the REAL secret URL
 */
export function renderCompletionCard({ panelUrl, adminUser, adminPass, domain, publicIp, version }) {
  return `🎉 **نصب و پیکربندی پنل WhiteDNS با موفقیت پایان یافت!**

🌐 **آدرس ورود مستقیم به پنل (دارای مسیر امنیتی اختصاصی):**
${panelUrl}

👤 **نام کاربری:**
\`${adminUser}\`

🔑 **رمز عبور اختصاصی (جهت کپی لمس کنید):**
\`${adminPass}\`

🖥 **اطلاعات فنی تانل:**
• دامنه اصلی: \`${domain}\`
• زیردامنه تانل: \`soar.${domain}\`
• نیم‌سرور: \`ns-soar.${domain}\`
• آی‌پی سرور: \`${publicIp}\`
• نسخه مستقر شده: \`${version || '0.14.0'}\`

🛡 **موتورهای فعال:**
• Soar Tunnel (پورت ۵۳ UDP/TCP فعال)
• CottenDNS (فعال و یکپارچه)
• MasterDNS (آماده در پنل)

📱 **راهنمای استفاده سریع:**
۱. آدرس بالا را در مرورگر باز کرده و با مشخصات بالا لاگین کنید.
۲. در منوی «حساب‌های کاربری»، روی «حساب جدید» بزنید و حساب خود را بسازید.
۳. لینک ساب (Subscription) را کپی کرده و در اپلیکیشن WhiteDNS وارد نمایید.`;
}

/**
 * Error Card renderer
 */
export function renderErrorCard(errorMsg) {
  return `❌ **عملیات نصب بر روی سرور متوقف شد**

علت خطا:
\`${errorMsg}\`

💡 **راهنما و راه‌حل:**
۱. اتصال اینترنت سرور و در دسترس بودن پورت ۲۲ را بررسی کنید.
۲. از صحت پسورد root اطمینان حاصل نمایید.
۳. مطمئن شوید پورت‌های ۵۳، ۸۰ و ۴۴۳ در فایروال پرووایدر VPS مسدود نیستند.

جهت شروع دوباره، دستور /start را ارسال کنید.`;
}

/**
 * Repair Progress Box renderer
 */
export function renderRepairProgressBox(currentStep, totalSteps = 6, ip = '', statusText = '') {
  const steps = [
    { num: 1, title: 'بررسی و رفع مشکل DNS و اینترنت سرور (/etc/resolv.conf)' },
    { num: 2, title: 'بررسی و آزادسازی پورت ۵۳ (حل تداخل systemd-resolved)' },
    { num: 3, title: 'بررسی دسترسی‌ها و ریستارت سرویس‌های daemon پنل' },
    { num: 4, title: 'بررسی فایروال و بازگشایی پورت‌های ۵۳، ۸۰ و ۴۴۳' },
    { num: 5, title: 'بررسی گواهی SSL و ریورس پروکسی Nginx' },
    { num: 6, title: 'تست سلامت نهایی و بازیابی آدرس اختصاصی پنل' },
  ];

  let text = '🛠 **در حال عیب‌یابی و تعمیر خودکار سرور WhiteDNS...**\n\n';
  if (ip) text += `🖥 آی‌پی سرور: \`${ip}\`\n\n`;

  for (const s of steps) {
    if (s.num < currentStep) {
      text += `[✅] مرحله ${s.num}: ${s.title}\n`;
    } else if (s.num === currentStep) {
      text += `[🔄] **مرحله ${s.num}: ${s.title}**...\n`;
    } else {
      text += `[⏳] مرحله ${s.num}: ${s.title}\n`;
    }
  }

  if (statusText) {
    text += `\n💬 وضعیت لحظه‌ای سرور:\n_${statusText}_\n`;
  }

  text += '\n⚠️ _این عملیات حدود ۱۵ تا ۳۰ ثانیه زمان می‌برد._';
  return text;
}

/**
 * Repair Card renderer
 */
export function renderRepairCard({ panelUrl, ip }) {
  return `✅ **عیب‌یابی و تعمیر خودکار سرور با موفقیت پایان یافت!**

🖥 **سرور:** \`${ip}\`

🟢 **گزارش سلامت سرویس‌ها:**
• اینترنت و ریزالو DNS: کاملاً سالم (1.1.1.1 / 8.8.8.8)
• پورت ۵۳ (تانل Soar DNS): بدون تداخل و فعال
• فایروال (UFW): پورت‌های ۵۳، ۸۰ و ۴۴۳ باز
• وب‌سرور Nginx و گواهی SSL: فعال و پیکربندی‌شده
• هسته مدیریتی Soar Panel: فعال (Active)

🌐 **آدرس بازیابی‌شده و فعال پنل شما:**
${panelUrl}

💡 در صورت بروز هرگونه قطعی یا عدم باز شدن پنل، همیشه می‌توانید با دستور /repair سرور را مجدداً عیب‌یابی و ریستارت نمایید.`;
}
