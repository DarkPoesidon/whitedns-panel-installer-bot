/**
 * Generates a strong, random ASCII password (16 chars) suitable for Soar panel admin
 */
export function generateStrongPassword(length = 16) {
  const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*';
  let pass = '';
  // Ensure at least one lower, one upper, one number, one special
  pass += 'abcdefghjkmnpqrstuvwxyz'[Math.floor(Math.random() * 23)];
  pass += 'ABCDEFGHJKLMNPQRSTUVWXYZ'[Math.floor(Math.random() * 23)];
  pass += '23456789'[Math.floor(Math.random() * 8)];
  pass += '!@#$%^&*'[Math.floor(Math.random() * 8)];

  for (let i = 4; i < length; i++) {
    pass += chars[Math.floor(Math.random() * chars.length)];
  }
  return pass.split('').sort(() => 0.5 - Math.random()).join('');
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
