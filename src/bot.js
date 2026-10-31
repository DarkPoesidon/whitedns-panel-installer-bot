import { Telegraf, Markup } from 'telegraf';
import { exec } from 'child_process';
import util from 'util';
import { BOT_TOKEN, CF_TEMPLATE_URL } from './config.js';
import { getSession, saveSession, resetSession, addDeployment, listDeployments, deleteDeploymentByIp } from './db.js';
import {
  verifyToken,
  listZones,
  setupSoarDnsRecords,
  deleteSoarDnsRecords,
  listDnsRecords,
  createDnsRecord,
  updateDnsRecord,
  deleteDnsRecord,
  getDnsRecord
} from './cloudflare.js';
import { installOverSSH, uninstallOverSSH, repairOverSSH } from './ssh-installer.js';
import { generateStrongPassword, renderProgressBox, renderCompletionCard, renderErrorCard, renderRepairProgressBox, renderRepairCard } from './ui.js';

const execPromise = util.promisify(exec);
const tempDnsState = new Map();

if (!BOT_TOKEN) {
  console.error('❌ FATAL: BOT_TOKEN is missing! Please provide BOT_TOKEN in .env file.');
  process.exit(1);
}

export const bot = new Telegraf(BOT_TOKEN);

/**
 * Registers Bot commands in Telegram Menu
 */
async function registerCommands() {
  try {
    await bot.telegram.setMyCommands([
      { command: 'start', description: '🚀 شروع و نصب پنل WhiteDNS' },
      { command: 'status', description: '📊 مشاهده سرورها و پنل‌های فعال' },
      { command: 'repair', description: '🛠 عیب‌یابی و تعمیر خودکار سرور' },
      { command: 'dns', description: '⚙️ مدیریت رکوردهای DNS کلودفلر' },
      { command: 'update', description: '🔄 به‌روزرسانی ربات به آخرین نسخه' },
      { command: 'uninstall', description: '🗑 حذف پنل WhiteDNS از سرور' },
      { command: 'help', description: '❓ راهنمای استفاده و پیش‌نیازها' },
      { command: 'reset', description: '🔄 لغو و شروع مجدد' }
    ]);
  } catch (err) {
    console.warn('Could not set commands:', err.message);
  }
}

// ----------------------------------------------------------------------------
// 1. COMMANDS
// ----------------------------------------------------------------------------

bot.command('start', async (ctx) => {
  const chatId = ctx.chat.id;
  resetSession(chatId, 'AWAITING_CF_EMAIL');

  return ctx.replyWithMarkdown(
    `👋 **به ربات نصب کاملاً خودکار WhiteDNS Soar Server خوش آمدید.**\n\nاین ربات تمامی مراحل تنظیم کلودفلر، اتصال SSH به سرور، حل تداخل پورت ۵۳، نصب پیش‌نیازها و صدور گواهی SSL را **به صورت ۱۰۰٪ خودکار** انجام می‌دهد.\n\n📧 **مرحله ۱ از ۲: ورود ایمیل کلودفلر**\nلطفاً **آدرس ایمیل** اکانت کلودفلر خود را ارسال فرمایید:\n_(مثال: myname@gmail.com)_\n\n💡 _اگر توکن آماده دارید، می‌توانید آن را مستقیماً ارسال کنید._`,
    Markup.inlineKeyboard([
      [Markup.button.url('🚀 باز کردن فرم آماده توکن (۱-کلیک)', CF_TEMPLATE_URL)],
      [Markup.button.callback('🛠 عیب‌یابی و تعمیر سرور موجود', 'menu:repair')],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.command('help', async (ctx) => {
  return ctx.replyWithMarkdown(
    `📖 **راهنمای جامع ربات نصب خودکار WhiteDNS**\n\n🔹 **این ربات چه کار می‌کند؟**\nاین ربات مستقیماً از طریق پروتکل امن SSH به سرور شما متصل شده، تانل DNS (Soar و Cotten) را کانفیگ کرده و پنل وب مدیریتی را با آدرس امن فعال می‌کند.\n\n🔹 **پیش‌نیازها:**\n۱. یک سرور خام با سیستم‌عامل Ubuntu 22/24 یا Debian 12/13.\n۲. یک دامنه متصل به اکانت کلودفلر.\n\n🔹 **دستورات منو:**\n• /start - شروع فرآیند نصب پنل جدید\n• /status - مشاهده پنل‌ها و لینک‌های فعال\n• /repair - عیب‌یابی خودکار، حل تداخل پورت ۵۳، صدور مجدد SSL و تعمیر پنل\n• /dns - مدیریت رکوردهای DNS کلودفلر (حذف / ویرایش / افزودن)\n• /update - به‌روزرسانی ربات به آخرین نسخه\n• /uninstall - حذف پنل WhiteDNS از سرور\n• /reset - ریست و لغو مرحله جاری`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 شروع نصب جدید', 'cmd:start')],
      [Markup.button.callback('🛠 عیب‌یابی و تعمیر سرور', 'menu:repair')],
      [Markup.button.callback('⚙️ مدیریت رکوردهای DNS', 'cmd:dns')]
    ])
  );
});

bot.command('status', async (ctx) => {
  const chatId = ctx.chat.id;
  const list = listDeployments(chatId);

  if (!list || list.length === 0) {
    return ctx.replyWithMarkdown(
      `📊 **وضعیت سرورها:**\n\nشما هنوز هیچ پنلی راه‌اندازی نکرده‌اید.\nبرای شروع نصب یا عیب‌یابی، گزینه‌های زیر را انتخاب کنید:`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🚀 نصب سرور جدید', 'cmd:start')],
        [Markup.button.callback('🛠 عیب‌یابی و تعمیر سرور دستی', 'menu:repair')]
      ])
    );
  }

  let text = `📊 **لیست سرورهای نصب‌شده شما (${list.length}):**\n\n`;
  for (const d of list) {
    text += `• **دامنه:** \`${d.domain}\`\n  **آی‌پی سرور:** \`${d.vps_ip}\`\n  **وضعیت:** 🟢 فعال\n`;
    if (d.panel_url) {
      text += `  **آدرس پنل:** ${d.panel_url}\n`;
    }
    text += `\n`;
  }

  return ctx.replyWithMarkdown(
    text,
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 نصب سرور جدید', 'cmd:start')],
      [Markup.button.callback('🛠 عیب‌یابی و تعمیر سرور', 'menu:repair')],
      [Markup.button.callback('🗑 حذف یا پاک‌سازی سرور', 'menu:uninstall_soar')]
    ])
  );
});

bot.command(['repair', 'fix'], async (ctx) => {
  return renderRepairList(ctx, ctx.chat.id, false);
});

bot.command(['dns', 'cloudflare'], async (ctx) => {
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  if (session && session.cfToken) {
    return renderZonesForDns(ctx, chatId, session.cfToken, false);
  }
  saveSession(chatId, { step: 'AWAITING_DNS_CF_AUTH' });
  return ctx.replyWithMarkdown(
    `⚙️ **سامانه مدیریت رکوردهای DNS کلودفلر**\n\nجهت مشاهده، افزودن، ویرایش و حذف رکوردهای DNS دامنه، لطفاً **توکن API** یا **ایمیل اکانت کلودفلر** خود را ارسال فرمایید:`,
    Markup.inlineKeyboard([
      [Markup.button.url('🚀 ساخت توکن در کلودفلر', CF_TEMPLATE_URL)],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.command('update', async (ctx) => {
  const statusMsg = await ctx.replyWithMarkdown('⏳ **در حال بررسی مخزن گیت‌هاب جهت دریافت آخرین نسخه...**');

  try {
    await execPromise('git fetch origin main 2>&1');
    const { stdout: statusOut } = await execPromise('git status -uno 2>&1');

    if (statusOut.includes('Your branch is up to date') && !statusOut.includes('behind')) {
      return ctx.telegram.editMessageText(
        ctx.chat.id,
        statusMsg.message_id,
        undefined,
        '✅ **ربات شما هم‌اکنون به آخرین نسخه رسمی گیت‌هاب مجهز است.**\n\nهیچ آپدیت جدیدی در مخزن موجود نیست.',
        { parse_mode: 'Markdown' }
      );
    }

    await ctx.telegram.editMessageText(
      ctx.chat.id,
      statusMsg.message_id,
      undefined,
      '🔄 **نسخه جدید یافت شد!**\nدر حال دریافت آخرین تغییرات و به‌روزرسانی پکیج‌ها...\n_(ربات تا لحظاتی دیگر به‌طور خودکار ریستارت می‌شود)_',
      { parse_mode: 'Markdown' }
    );

    setTimeout(async () => {
      try {
        await execPromise('git reset --hard origin/main && npm install --omit=dev && systemctl restart whitedns-bot');
      } catch (e) {
        console.error('Update restart error:', e);
      }
    }, 1000);

  } catch (err) {
    return ctx.telegram.editMessageText(
      ctx.chat.id,
      statusMsg.message_id,
      undefined,
      `❌ **خطا در فرآیند به‌روزرسانی خودکار:**\n\`${err.message}\`\n\nمی‌توانید در ترمینال سرور این دستور را اجرا فرمایید:\n\`bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/update.sh)\``,
      { parse_mode: 'Markdown' }
    );
  }
});

bot.command('uninstall', async (ctx) => {
  return renderUninstallSoar(ctx, ctx.chat.id, false);
});

bot.command(['reset', 'cancel'], async (ctx) => {
  const chatId = ctx.chat.id;
  resetSession(chatId, 'IDLE');
  return ctx.replyWithMarkdown(
    '🔄 **عملیات جاری لغو و حافظه نشست ریست شد.**\n\nبرای شروع دوباره از دکمه زیر استفاده کنید:',
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 شروع مجدد', 'cmd:start')]
    ])
  );
});

// ----------------------------------------------------------------------------
// 2. CONVERSATIONAL TEXT HANDLER
// ----------------------------------------------------------------------------

bot.on('text', async (ctx) => {
  const chatId = ctx.chat.id;
  const text = ctx.message.text.trim();
  const session = getSession(chatId);

  if (!session || session.step === 'IDLE') {
    return;
  }

  // 1. AWAITING CLOUDFLARE EMAIL
  if (session.step === 'AWAITING_CF_EMAIL') {
    // Check if user sent direct combo or token
    if (text.includes(':') || (text.length >= 35 && !text.includes('@'))) {
      await ctx.deleteMessage().catch(() => {});
      return handleCloudflareAuth(ctx, chatId, text);
    }

    if (!text.includes('@') || !text.includes('.')) {
      return ctx.replyWithMarkdown(
        '❌ لطفاً یک آدرس ایمیل معتبر ارسال فرمایید (مثال: `yourname@gmail.com`):',
        Markup.inlineKeyboard([[Markup.button.callback('❌ انصراف', 'cancel')]])
      );
    }

    saveSession(chatId, { cfToken: text, step: 'AWAITING_CF_KEY' });

    return ctx.replyWithMarkdown(
      `✅ ایمیل شما ثبت شد: \`${text}\`\n\n🔑 **مرحله ۲ از ۲: دریافت خودکار توکن کلودفلر**\n\nروی دکمه زیر بزنید تا صفحه کلودفلر **با قالب و پرمیشن‌های از پیش تنظیم‌شده** باز شود:\n\n۱. دکمه زیر را لمس کنید (همه گزینه‌ها و دسترسی‌های DNS خودکار پر شده‌اند).\n۲. در انتهای صفحه، دکمه آبی **Continue to summary** و سپس **Create Token** را بزنید.\n۳. توکن ساخته‌شده را کپی کرده و به این چت ارسال فرمایید:\n\n💡 _(یا اگر در صفحه هستید، روبروی عبارت Global API Key دکمه View را بزنید و کد را بفرستید)_`,
      Markup.inlineKeyboard([
        [Markup.button.url('🚀 باز کردن فرم آماده توکن (۱-کلیک)', CF_TEMPLATE_URL)],
        [
          Markup.button.callback('🔙 ویرایش ایمیل', 'back:cf_email'),
          Markup.button.callback('❌ انصراف', 'cancel')
        ]
      ])
    );
  }

  // 2. AWAITING CLOUDFLARE KEY
  if (session.step === 'AWAITING_CF_KEY') {
    await ctx.deleteMessage().catch(() => {});

    let authInput = text;
    if (session.cfToken && session.cfToken.includes('@') && !text.includes(':')) {
      authInput = `${session.cfToken}:${text}`;
    }

    return handleCloudflareAuth(ctx, chatId, authInput);
  }

  // 3. AWAITING SSH IP
  if (session.step === 'AWAITING_SSH_IP') {
    const parts = text.split(':');
    if (parts.length >= 2) {
      await ctx.deleteMessage().catch(() => {});

      let ip = parts[0].trim();
      let port = 22;
      let user = 'root';
      let pass = '';

      if (parts.length === 2) {
        pass = parts[1].trim();
      } else if (parts.length === 4) {
        port = parseInt(parts[1], 10) || 22;
        user = parts[2].trim() || 'root';
        pass = parts[3].trim();
      }

      const adminPass = generateStrongPassword(16);

      saveSession(chatId, {
        vpsIp: ip,
        vpsPort: port,
        vpsUser: user,
        vpsPass: pass,
        adminPass,
        step: 'CONFIRM_DEPLOY'
      });

      return ctx.replyWithMarkdown(
        `✅ **مشخصات سرور با موفقیت دریافت شد.**\n_(پیام حاوی رمز عبور شما فوراً حذف شد)_\n\n📋 **خلاصه پیکربندی نهایی:**\n• دامنه تانل: \`soar.${session.domain}\`\n• نیم‌سرور: \`ns-soar.${session.domain}\`\n• آدرس پنل: \`panel.${session.domain}\`\n• آی‌پی سرور: \`${ip}\`\n• پورت SSH: \`${port}\`\n• کاربر: \`${user}\`\n\nبرای شروع عملیات نصب خودکار از طریق SSH کلیک کنید:`,
        Markup.inlineKeyboard([
          [Markup.button.callback('🚀 تایید و شروع نصب خودکار (SSH)', 'deploy')],
          [
            Markup.button.callback('🔙 تغییر آی‌پی سرور', 'back:ssh_ip'),
            Markup.button.callback('❌ انصراف', 'cancel')
          ]
        ])
      );
    }

    const ip = text.replace(/[^0-9.]/g, '');
    if (!ip || ip.split('.').length !== 4) {
      return ctx.replyWithMarkdown(
        '❌ لطفاً یک آدرس IPv4 معتبر وارد نمایید (مثال: `194.26.11.20`):',
        Markup.inlineKeyboard([
          [
            Markup.button.callback('🔙 تغییر دامنه', 'back:select_zone'),
            Markup.button.callback('❌ انصراف', 'cancel')
          ]
        ])
      );
    }

    saveSession(chatId, { vpsIp: ip, step: 'AWAITING_SSH_PORT' });

    return ctx.replyWithMarkdown(
      `🌐 آی‌پی سرور: \`${ip}\`\n\nپورت SSH سرور را مشخص کنید:`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🔘 پورت پیش‌فرض (22)', 'port:22')],
        [Markup.button.callback('✏️ ورود پورت سفارشی', 'port:custom')],
        [
          Markup.button.callback('🔙 ویرایش آی‌پی سرور', 'back:ssh_ip'),
          Markup.button.callback('❌ انصراف', 'cancel')
        ]
      ])
    );
  }

  // 4. AWAITING CUSTOM SSH PORT
  if (session.step === 'AWAITING_SSH_PORT_CUSTOM') {
    const port = parseInt(text, 10);
    if (isNaN(port) || port < 1 || port > 65535) {
      return ctx.replyWithMarkdown('❌ شماره پورت نامعتبر است. یک عدد بین ۱ تا ۶۵۵۳۵ بفرستید:');
    }

    saveSession(chatId, { vpsPort: port, step: 'AWAITING_SSH_USER' });

    return ctx.replyWithMarkdown(
      `پورت SSH: \`${port}\`\n\nنام کاربری سرور را انتخاب کنید:`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🔘 کاربر پیش‌فرض (root)', 'user:root')],
        [Markup.button.callback('✏️ نام کاربری سفارشی', 'user:custom')],
        [
          Markup.button.callback('🔙 تغییر پورت', 'back:ssh_port'),
          Markup.button.callback('❌ انصراف', 'cancel')
        ]
      ])
    );
  }

  // 5. AWAITING CUSTOM SSH USERNAME
  if (session.step === 'AWAITING_SSH_USER_CUSTOM') {
    if (!text || text.length > 32) {
      return ctx.replyWithMarkdown('❌ نام کاربری نامعتبر است.');
    }

    saveSession(chatId, { vpsUser: text, step: 'AWAITING_SSH_PASS' });

    return ctx.replyWithMarkdown(
      `نام کاربری: \`${text}\`\n\n🔑 لطفاً **رمز عبور سرور** را ارسال نمایید:\n_(پیام شما بلافاصله پس از دریافت حذف خواهد شد)_`,
      Markup.inlineKeyboard([
        [
          Markup.button.callback('🔙 تغییر نام کاربری', 'back:ssh_user'),
          Markup.button.callback('❌ انصراف', 'cancel')
        ]
      ])
    );
  }

  // 6. AWAITING SSH PASSWORD
  if (session.step === 'AWAITING_SSH_PASS') {
    await ctx.deleteMessage().catch(() => {});

    const adminPass = generateStrongPassword(16);

    saveSession(chatId, {
      vpsPass: text,
      adminPass,
      step: 'CONFIRM_DEPLOY'
    });

    return ctx.replyWithMarkdown(
      `✅ **رمز عبور سرور دریافت شد.**\n_(پیام رمز عبور شما فوراً حذف گردید)_\n\n📋 **خلاصه اطلاعات جهت راه‌اندازی:**\n• دامنه: \`${session.domain}\`\n• زیردامنه تانل: \`soar.${session.domain}\`\n• نیم‌سرور: \`ns-soar.${session.domain}\`\n• آدرس پنل: \`panel.${session.domain}\`\n• آی‌پی سرور: \`${session.vpsIp}\`\n• پورت SSH: \`${session.vpsPort}\`\n• کاربر SSH: \`${session.vpsUser}\`\n\nآماده شروع نصب خودکار هستید؟`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🚀 تایید و شروع نصب خودکار (SSH)', 'deploy')],
        [
          Markup.button.callback('🔙 ویرایش مشخصات سرور', 'back:ssh_ip'),
          Markup.button.callback('❌ انصراف و شروع مجدد', 'cancel')
        ]
      ])
    );
  }

  // 7. AWAITING UNINSTALL MANUAL IP
  if (session.step === 'AWAITING_UNINSTALL_IP') {
    const ip = text.replace(/[^0-9.]/g, '');
    if (!ip || ip.split('.').length !== 4) {
      return ctx.replyWithMarkdown('❌ لطفاً یک آدرس IPv4 معتبر ارسال فرمایید:');
    }

    saveSession(chatId, { uninstIp: ip, step: 'AWAITING_UNINSTALL_PASS' });
    return ctx.replyWithMarkdown(
      `🌐 سرور انتخابی: \`${ip}\`\n\n🔑 لطفاً **رمز عبور root سرور** را جهت اتصال SSH و پاک‌سازی کامل WhiteDNS ارسال فرمایید:\n_(پیام رمز عبور شما بلافاصله پس از دریافت حذف می‌شود)_`,
      Markup.inlineKeyboard([[Markup.button.callback('❌ انصراف', 'cancel')]])
    );
  }

  // 8. AWAITING UNINSTALL ROOT PASSWORD
  if (session.step === 'AWAITING_UNINSTALL_PASS') {
    await ctx.deleteMessage().catch(() => {});
    const vpsPass = text;
    const vpsIp = session.uninstIp || session.vpsIp;
    const domain = session.uninstDomain || session.domain;

    const progressMsg = await ctx.replyWithMarkdown(
      `⏳ **در حال اتصال امن SSH به سرور (\`${vpsIp}\`) جهت توقف و پاک‌سازی WhiteDNS...**`
    );

    try {
      await uninstallOverSSH({
        vpsIp,
        vpsPort: session.vpsPort || 22,
        vpsUser: 'root',
        vpsPass,
        onProgress: async (step, msg) => {
          await ctx.telegram.editMessageText(
            chatId,
            progressMsg.message_id,
            undefined,
            `⚙️ **در حال حذف WhiteDNS از روی سرور...**\n\n[🔄] مرحله ${step}: ${msg}`,
            { parse_mode: 'Markdown' }
          ).catch(() => {});
        }
      });

      // Also clean up Cloudflare DNS records if token exists
      if (session.cfToken && session.zoneId && domain) {
        await deleteSoarDnsRecords(session.cfToken, session.zoneId, domain).catch(() => {});
      }

      deleteDeploymentByIp(chatId, vpsIp);
      resetSession(chatId, 'IDLE');

      return ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        `🎉 **پنل WhiteDNS با موفقیت به طور کامل از روی سرور حذف شد!**\n\n• آی‌پی سرور: \`${vpsIp}\`\n• سرویس‌های \`soar-panel\` و \`soar-panel-ops\` متوقف و حذف شدند.\n• فایل‌های پایگاه‌داده و باینری‌ها پاک شدند.\n• تنظیمات پورت ۵۳ و فایروال به حالت اولیه بازگشتند.\n\nسرور شما اکنون کاملاً پاک و آماده استفاده مجدد است.`,
        {
          parse_mode: 'Markdown',
          reply_markup: {
            inline_keyboard: [
              [{ text: '🚀 نصب مجدد یا جدید', callback_data: 'cmd:start' }]
            ]
          }
        }
      );
    } catch (err) {
      return ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        `❌ **خطا در فرآیند حذف از سرور:**\n\`${err.message}\`\n\nلطفاً از صحت رمز عبور root و در دسترس بودن سرور اطمینان حاصل نمایید.`,
        { parse_mode: 'Markdown' }
      );
    }
  }

  // 9. AWAITING REPAIR MANUAL IP
  if (session.step === 'AWAITING_REPAIR_IP') {
    const ip = text.replace(/[^0-9.]/g, '');
    if (!ip || ip.split('.').length !== 4) {
      return ctx.replyWithMarkdown('❌ لطفاً یک آدرس IPv4 معتبر ارسال فرمایید:');
    }

    saveSession(chatId, { repairIp: ip, step: 'AWAITING_REPAIR_PASS' });
    return ctx.replyWithMarkdown(
      `🌐 سرور انتخابی جهت عیب‌یابی: \`${ip}\`\n\n🔑 لطفاً **رمز عبور root سرور** را جهت اتصال SSH و عیب‌یابی/تعمیر خودکار ارسال فرمایید:\n_(پیام رمز عبور شما بلافاصله پس از دریافت حذف می‌شود)_`,
      Markup.inlineKeyboard([[Markup.button.callback('❌ انصراف', 'cancel')]])
    );
  }

  // 10. AWAITING REPAIR ROOT PASSWORD
  if (session.step === 'AWAITING_REPAIR_PASS') {
    await ctx.deleteMessage().catch(() => {});
    const vpsPass = text;
    const vpsIp = session.repairIp || session.vpsIp;
    const domain = session.repairDomain || session.domain || '';

    const progressMsg = await ctx.replyWithMarkdown(
      renderRepairProgressBox(1, 6, vpsIp, 'در حال برقراری اتصال امن SSH به سرور...')
    );

    try {
      const repairRes = await repairOverSSH({
        vpsIp,
        vpsPort: session.vpsPort || 22,
        vpsUser: 'root',
        vpsPass,
        domain,
        onProgress: async (step, msg) => {
          await ctx.telegram.editMessageText(
            chatId,
            progressMsg.message_id,
            undefined,
            renderRepairProgressBox(step, 6, vpsIp, msg),
            { parse_mode: 'Markdown' }
          ).catch(() => {});
        }
      });

      if (repairRes.panelUrl) {
        addDeployment({
          chatId,
          domain: repairRes.panelDomain || domain || vpsIp,
          vpsIp,
          panelUrl: repairRes.panelUrl,
          status: 'COMPLETED'
        });
      }

      resetSession(chatId, 'IDLE');

      return ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        renderRepairCard({ panelUrl: repairRes.panelUrl, ip: vpsIp }),
        {
          parse_mode: 'Markdown',
          reply_markup: {
            inline_keyboard: [
              [{ text: '🌐 باز کردن مستقیم آدرس پنل', url: repairRes.panelUrl }],
              [{ text: '📊 مشاهده وضعیت سرورها', callback_data: 'menu:status' }]
            ]
          }
        }
      );
    } catch (err) {
      return ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        `❌ **عملیات عیب‌یابی و تعمیر متوقف شد:**\n\`${err.message}\`\n\nلطفاً از صحت رمز عبور root و باز بودن پورت ۲۲ سرور اطمینان حاصل نمایید.`,
        {
          parse_mode: 'Markdown',
          reply_markup: {
            inline_keyboard: [
              [{ text: '🔄 تلاش مجدد', callback_data: 'menu:repair' }],
              [{ text: '❌ انصراف', callback_data: 'cancel' }]
            ]
          }
        }
      );
    }
  }

  // 11. AWAITING DNS CLOUDFLARE AUTH (FROM /dns)
  if (session.step === 'AWAITING_DNS_CF_AUTH') {
    await ctx.deleteMessage().catch(() => {});
    const verify = await verifyToken(text);
    if (!verify.ok) {
      return ctx.replyWithMarkdown(
        `❌ **توکن یا اطلاعات کلودفلر نامعتبر است:**\n\`${verify.error || 'عدم دسترسی'}\`\n\nلطفاً توکن جدید ساخته و ارسال فرمایید:`,
        Markup.inlineKeyboard([
          [Markup.button.url('🚀 ساخت توکن در کلودفلر', CF_TEMPLATE_URL)],
          [Markup.button.callback('❌ انصراف', 'cancel')]
        ])
      );
    }
    const auth = verify.resolvedAuth || text;
    saveSession(chatId, { cfToken: auth, step: 'SELECTING_ZONE_FOR_DNS' });
    return renderZonesForDns(ctx, chatId, auth, false);
  }

  // 12. AWAITING DNS ADD NAME
  if (session.step === 'AWAITING_DNS_ADD_NAME') {
    const rawName = text.trim();
    const st = tempDnsState.get(chatId) || {};
    st.name = rawName;
    tempDnsState.set(chatId, st);

    saveSession(chatId, { step: 'AWAITING_DNS_ADD_CONTENT' });
    return ctx.replyWithMarkdown(
      `📌 نام رکورد: \`${rawName}\`\n\nلطفاً **مقدار یا آی‌پی (Value / Content)** این رکورد را ارسال فرمایید:\n_(برای رکورد A: آی‌پی سرور مثل \`173.230.134.64\` | برای CNAME: نام هاست)_`,
      Markup.inlineKeyboard([
        [Markup.button.callback('❌ انصراف', `cf_dns:${st.zoneId}:${st.domain}`)]
      ])
    );
  }

  // 13. AWAITING DNS ADD CONTENT
  if (session.step === 'AWAITING_DNS_ADD_CONTENT') {
    const content = text.trim();
    const st = tempDnsState.get(chatId) || {};
    st.content = content;
    tempDnsState.set(chatId, st);

    // If type is NS or TXT, proxy is not applicable
    if (st.type === 'NS' || st.type === 'TXT') {
      const waitMsg = await ctx.reply('⏳ در حال ثبت رکورد در کلودفلر...');
      const createRes = await createDnsRecord(session.cfToken, st.zoneId, {
        type: st.type,
        name: st.name,
        content: st.content,
        proxied: false
      });
      await ctx.telegram.deleteMessage(chatId, waitMsg.message_id).catch(() => {});
      saveSession(chatId, { step: 'IDLE' });
      tempDnsState.delete(chatId);

      if (!createRes.ok) {
        return ctx.replyWithMarkdown(
          `❌ **خطا در ثبت رکورد DNS:**\n\`${createRes.error}\``,
          Markup.inlineKeyboard([
            [Markup.button.callback('🔙 بازگشت به لیست رکوردها', `cf_dns:${st.zoneId}:${st.domain}`)]
          ])
        );
      }
      return renderDnsManager(ctx, chatId, st.zoneId, st.domain, 1, false, `✅ رکورد [${st.type}] ${st.name} با موفقیت ایجاد شد.`);
    }

    // For A, AAAA, CNAME -> ask for proxy status
    saveSession(chatId, { step: 'AWAITING_DNS_ADD_PROXY' });
    return ctx.replyWithMarkdown(
      `🌐 **وضعیت پروکسی کلودفلر برای رکورد \`${st.name}\`:**\n\n• مقدار: \`${content}\`\n• نوع: \`${st.type}\`\n\nآیا می‌خواهید ترافیک این رکورد از شبکه CDN کلودفلر عبور کند؟\n_(توجه: برای پنل WhiteDNS و تانل، پروکسی باید خاموش / DNS Only باشد)_`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🔘 پروکسی خاموش (DNS Only - توصیه شده)', `cf_add_proxy:${st.zoneId}:${st.domain}:0`)],
        [Markup.button.callback('☁️ پروکسی روشن (Proxied)', `cf_add_proxy:${st.zoneId}:${st.domain}:1`)],
        [Markup.button.callback('❌ انصراف', `cf_dns:${st.zoneId}:${st.domain}`)]
      ])
    );
  }

  // 14. AWAITING DNS EDIT VALUE
  if (session.step === 'AWAITING_DNS_EDIT_VAL') {
    const newVal = text.trim();
    const st = tempDnsState.get(chatId) || {};
    if (!st.recordId) {
      saveSession(chatId, { step: 'IDLE' });
      return ctx.reply('⚠️ جلسه ویرایش منقضی شده است.');
    }

    const waitMsg = await ctx.reply('⏳ در حال به‌روزرسانی رکورد در کلودفلر...');
    const updateRes = await updateDnsRecord(session.cfToken, st.zoneId, st.recordId, {
      content: newVal
    });
    await ctx.telegram.deleteMessage(chatId, waitMsg.message_id).catch(() => {});
    saveSession(chatId, { step: 'IDLE' });
    tempDnsState.delete(chatId);

    if (!updateRes.ok) {
      return ctx.replyWithMarkdown(
        `❌ **خطا در به‌روزرسانی رکورد:**\n\`${updateRes.error}\``,
        Markup.inlineKeyboard([
          [Markup.button.callback('🔙 بازگشت به لیست رکوردها', `cf_dns:${st.zoneId}:${st.domain}`)]
        ])
      );
    }

    return renderDnsManager(ctx, chatId, st.zoneId, st.domain, 1, false, `✅ مقدار رکورد با موفقیت به ${newVal} تغییر یافت.`);
  }
});

// ----------------------------------------------------------------------------
// 3. CALLBACK QUERY HANDLERS
// ----------------------------------------------------------------------------

bot.action('cmd:start', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  resetSession(chatId, 'AWAITING_CF_EMAIL');
  return ctx.replyWithMarkdown(
    `👋 **شروع نصب WhiteDNS Soar Server**\n\n📧 **مرحله ۱ از ۲: ورود ایمیل کلودفلر**\nلطفاً **آدرس ایمیل** اکانت کلودفلر خود را ارسال فرمایید:\n_(مثال: myname@gmail.com)_`,
    Markup.inlineKeyboard([
      [Markup.button.url('🚀 باز کردن فرم آماده توکن (۱-کلیک)', CF_TEMPLATE_URL)],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.action('cancel', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  resetSession(chatId, 'IDLE');
  return ctx.editMessageText(
    '❌ **عملیات جاری لغو شد.**\n\nبرای شروع دوباره می‌توانید از دکمه زیر استفاده کنید:',
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 شروع مجدد', 'cmd:start')]
    ])
  );
});

function renderUninstallSoar(ctx, chatId, isEdit = false) {
  const list = listDeployments(chatId);

  if (!list || list.length === 0) {
    saveSession(chatId, { step: 'AWAITING_UNINSTALL_IP' });
    const msg = `🗑 **حذف پنل WhiteDNS از روی سرور**\n\nهیچ سرور ثبت‌شده‌ای در تاریخچه شما یافت نشد.\n\n📌 لطفاً **آی‌پی سرور (IPv4)** که می‌خواهید پنل WhiteDNS از روی آن حذف شود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_`;
    const buttons = Markup.inlineKeyboard([
      [Markup.button.callback('❌ انصراف و بازگشت', 'cancel')]
    ]);
    if (isEdit) return ctx.editMessageText(msg, buttons);
    return ctx.replyWithMarkdown(msg, buttons);
  }

  const keyboard = list.map(d => ([
    Markup.button.callback(`🗑 حذف ${d.domain} (${d.vps_ip})`, `uninst_srv:${d.domain}:${d.vps_ip}`)
  ]));

  keyboard.push([
    Markup.button.callback('✏️ ورود دستی آی‌پی سرور دیگر', 'uninst_manual'),
    Markup.button.callback('❌ انصراف', 'cancel')
  ]);

  const msg = `🗑 **مدیریت حذف پنل WhiteDNS از روی سرور مقصد**\n\n👇 لطفاً سروری که می‌خواهید پنل WhiteDNS و تنظیمات تانل DNS از روی آن پاک‌سازی شود را انتخاب فرمایید:`;
  if (isEdit) return ctx.editMessageText(msg, Markup.inlineKeyboard(keyboard));
  return ctx.replyWithMarkdown(msg, Markup.inlineKeyboard(keyboard));
}

bot.action('menu:uninstall_soar', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  return renderUninstallSoar(ctx, ctx.chat.id, true);
});

bot.action('uninst_manual', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { step: 'AWAITING_UNINSTALL_IP' });
  return ctx.editMessageText(
    `📌 لطفاً **آی‌پی سرور (IPv4)** که می‌خواهید پنل WhiteDNS از روی آن پاک شود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', 'menu:uninstall_soar')],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.action(/uninst_srv:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const domain = ctx.match[1];
  const ip = ctx.match[2];

  saveSession(chatId, { uninstDomain: domain, uninstIp: ip, step: 'AWAITING_UNINSTALL_PASS' });

  return ctx.editMessageText(
    `⚠️ **هشدار حذف کامل پنل:**\n• دامنه: \`${domain}\`\n• آی‌پی سرور: \`${ip}\`\n\nبا این عملیات تمام باینری‌های WhiteDNS، دیتابیس کاربران و سرویس‌های مربوطه از سرور پاک خواهند شد.\n\n🔑 لطفاً **رمز عبور root سرور** را ارسال نمایید تا ربات فرآیند حذف را شروع کند:\n_(پیام رمز عبور شما فوراً حذف خواهد شد)_`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔙 انصراف و بازگشت', 'menu:uninstall_soar')]
    ])
  );
});

function renderRepairList(ctx, chatId, isEdit = false) {
  const list = listDeployments(chatId);

  if (!list || list.length === 0) {
    saveSession(chatId, { step: 'AWAITING_REPAIR_IP' });
    const msg = `🛠 **عیب‌یابی و تعمیر خودکار سرور WhiteDNS**\n\nهیچ سرور ثبت‌شده‌ای در تاریخچه شما یافت نشد.\n\n📌 لطفاً **آی‌پی سرور (IPv4)** که می‌خواهید عیب‌یابی و تعمیر شود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_`;
    const buttons = Markup.inlineKeyboard([
      [Markup.button.callback('❌ انصراف و بازگشت', 'cancel')]
    ]);
    if (isEdit) return ctx.editMessageText(msg, buttons);
    return ctx.replyWithMarkdown(msg, buttons);
  }

  const keyboard = list.map(d => ([
    Markup.button.callback(`🛠 عیب‌یابی و تعمیر ${d.domain} (${d.vps_ip})`, `repair_srv:${d.domain}:${d.vps_ip}`)
  ]));

  keyboard.push([
    Markup.button.callback('✏️ ورود دستی آی‌پی سرور دیگر', 'repair_manual'),
    Markup.button.callback('❌ انصراف', 'cancel')
  ]);

  const msg = `🛠 **سامانه هوشمند عیب‌یابی و خودترمیمی WhiteDNS**\n\nربات به صورت خودکار موارد زیر را روی سرور بررسی و اصلاح می‌کند:\n• رفع قطعی اینترنت و تنظیم DNS خروجی سرور (/etc/resolv.conf)\n• حل تداخل پورت ۵۳ (آزادسازی از دست systemd-resolved)\n• اصلاح دسترسی‌ها و راه‌اندازی مجدد هسته Soar Panel\n• بررسی فایروال و بازگشایی پورت‌های ۵۳، ۸۰ و ۴۴۳\n• صدور مجدد SSL و راه‌اندازی ریورس پروکسی Nginx\n• بازیابی و ارائه آدرس اختصاصی و فعال پنل\n\n👇 لطفاً سرور مورد نظر خود را انتخاب فرمایید:`;
  if (isEdit) return ctx.editMessageText(msg, Markup.inlineKeyboard(keyboard));
  return ctx.replyWithMarkdown(msg, Markup.inlineKeyboard(keyboard));
}

bot.action('menu:repair', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  return renderRepairList(ctx, ctx.chat.id, true);
});

bot.action('repair_manual', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { step: 'AWAITING_REPAIR_IP' });
  return ctx.editMessageText(
    `📌 لطفاً **آی‌پی سرور (IPv4)** که می‌خواهید عیب‌یابی و تعمیر شود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', 'menu:repair')],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.action(/repair_srv:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const domain = ctx.match[1];
  const ip = ctx.match[2];

  saveSession(chatId, { repairDomain: domain, repairIp: ip, step: 'AWAITING_REPAIR_PASS' });

  return ctx.editMessageText(
    `🛠 **آماده‌سازی عیب‌یابی و خودترمیمی سرور:**\n• دامنه: \`${domain}\`\n• آی‌پی سرور: \`${ip}\`\n\nربات به سرور متصل شده، تداخل‌های پورت ۵۳، سرویس‌های داون، گواهی SSL و وب‌سرور را به‌طور کامل تعمیر خواهد کرد.\n\n🔑 لطفاً **رمز عبور root سرور** را ارسال فرمایید:\n_(پیام رمز عبور شما بلافاصله پس از دریافت حذف خواهد شد)_`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔙 انصراف و بازگشت', 'menu:repair')]
    ])
  );
});

bot.action('menu:status', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const list = listDeployments(ctx.chat.id);
  if (!list || list.length === 0) {
    return ctx.editMessageText(
      `📊 **وضعیت سرورها:**\n\nشما هنوز هیچ پنلی راه‌اندازی نکرده‌اید.`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🚀 نصب سرور جدید', 'cmd:start')]
      ])
    );
  }
  let text = `📊 **لیست سرورهای نصب‌شده شما (${list.length}):**\n\n`;
  for (const d of list) {
    text += `• **دامنه:** \`${d.domain}\`\n  **آی‌پی سرور:** \`${d.vps_ip}\`\n  **وضعیت:** 🟢 فعال\n`;
    if (d.panel_url) {
      text += `  **آدرس پنل:** ${d.panel_url}\n`;
    }
    text += `\n`;
  }
  return ctx.editMessageText(
    text,
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 نصب سرور جدید', 'cmd:start')],
      [Markup.button.callback('🛠 عیب‌یابی و تعمیر سرور', 'menu:repair')],
      [Markup.button.callback('🗑 حذف یا پاک‌سازی سرور', 'menu:uninstall_soar')]
    ])
  );
});

bot.action('back:cf_email', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { step: 'AWAITING_CF_EMAIL' });
  return ctx.editMessageText(
    `📧 **مرحله ۱ از ۲: ورود ایمیل کلودفلر**\n\nبرای اتصال به دامنه، لطفاً **آدرس ایمیل** اکانت کلودفلر خود را تایپ و ارسال کنید:\n_(مثال: myname@gmail.com)_`,
    Markup.inlineKeyboard([
      [Markup.button.url('🚀 باز کردن فرم آماده توکن (۱-کلیک)', CF_TEMPLATE_URL)],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.action('back:select_zone', async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);

  if (!session?.cfToken) return;

  const zonesRes = await listZones(session.cfToken);
  if (zonesRes.ok && zonesRes.zones?.length) {
    saveSession(chatId, { step: 'SELECTING_ZONE' });
    const keyboard = zonesRes.zones.map(z => ([
      Markup.button.callback(`🌐 ${z.name}`, `zone:${z.id}:${z.name}`)
    ]));
    keyboard.push([
      Markup.button.callback('🔙 تغییر اکانت کلودفلر', 'back:cf_email'),
      Markup.button.callback('❌ انصراف', 'cancel')
    ]);
    return ctx.editMessageText('👇 دامنه مورد نظر خود را مجدداً انتخاب کنید:', Markup.inlineKeyboard(keyboard));
  }
});

bot.action('back:ssh_ip', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  saveSession(chatId, { step: 'AWAITING_SSH_IP' });
  return ctx.editMessageText(
    `🌐 دامنه انتخاب‌شده: \`${session.domain}\`\n\n📌 اکنون لطفاً **آدرس IPv4 عمومی سرور (VPS)** خود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_`,
    Markup.inlineKeyboard([
      [
        Markup.button.callback('🔙 تغییر دامنه', 'back:select_zone'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

bot.action('back:ssh_port', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  saveSession(chatId, { step: 'AWAITING_SSH_PORT' });
  return ctx.editMessageText(
    `🌐 آی‌پی سرور: \`${session.vpsIp}\`\n\nپورت SSH سرور را مشخص کنید:`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔘 پورت پیش‌فرض (22)', 'port:22')],
      [Markup.button.callback('✏️ ورود پورت سفارشی', 'port:custom')],
      [
        Markup.button.callback('🔙 ویرایش آی‌پی سرور', 'back:ssh_ip'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

bot.action('back:ssh_user', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  saveSession(chatId, { step: 'AWAITING_SSH_USER' });
  return ctx.editMessageText(
    `پورت SSH: \`${session.vpsPort || 22}\`\n\nنام کاربری سرور را انتخاب کنید:`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔘 کاربر پیش‌فرض (root)', 'user:root')],
      [Markup.button.callback('✏️ نام کاربری سفارشی', 'user:custom')],
      [
        Markup.button.callback('🔙 تغییر پورت', 'back:ssh_port'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

bot.action(/zone:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];

  saveSession(chatId, { zoneId, domain, step: 'AWAITING_SSH_IP' });

  return ctx.editMessageText(
    `🌐 دامنه انتخاب‌شده: \`${domain}\`\n\n📌 اکنون لطفاً **آدرس IPv4 عمومی سرور (VPS)** خود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_\n\n💡 _همچنین می‌توانید مشخصات کامل را یکجا بفرستید:_\n\`IP:Port:User:Password\`\n\nیا در صورت تمایل می‌توانید رکوردهای DNS این دامنه را بررسی، ویرایش یا حذف نمایید:`,
    Markup.inlineKeyboard([
      [Markup.button.callback('⚙️ مدیریت رکوردهای DNS این دامنه', `cf_dns:${zoneId}:${domain}`)],
      [
        Markup.button.callback('🔙 تغییر دامنه', 'back:select_zone'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

// ----------------------------------------------------------------------------
// CLOUDFLARE DNS MANAGEMENT FUNCTIONS & HANDLERS
// ----------------------------------------------------------------------------

async function renderZonesForDns(ctx, chatId, authInput, isEdit = false) {
  let statusMsg = null;
  if (!isEdit) {
    statusMsg = await ctx.reply('⏳ در حال دریافت لیست دامنه‌های کلودفلر...');
  }
  const zonesRes = await listZones(authInput);

  if (!zonesRes.ok || !zonesRes.zones?.length) {
    const errorText = `⚠️ **هیچ دامنه‌ای در اکانت کلودفلر شما یافت نشد!**\nعلت: ${zonesRes.error || 'عدم دسترسی'}`;
    if (isEdit) return ctx.editMessageText(errorText);
    return ctx.telegram.editMessageText(chatId, statusMsg.message_id, undefined, errorText);
  }

  const keyboard = zonesRes.zones.map(z => ([
    Markup.button.callback(`🌐 مدیریت DNS: ${z.name}`, `cf_dns:${z.id}:${z.name}`)
  ]));

  keyboard.push([
    Markup.button.callback('❌ انصراف و خروج', 'cancel')
  ]);

  const msg = `🌐 **سامانه مدیریت رکوردهای DNS کلودفلر**\n\n👇 لطفاً دامنه‌ای که می‌خواهید رکوردهای DNS آن را مشاهده، افزوده، ویرایش یا حذف کنید انتخاب فرمایید:`;

  if (isEdit) return ctx.editMessageText(msg, Markup.inlineKeyboard(keyboard));
  if (statusMsg) {
    return ctx.telegram.editMessageText(chatId, statusMsg.message_id, undefined, msg, {
      parse_mode: 'Markdown',
      reply_markup: Markup.inlineKeyboard(keyboard).reply_markup
    });
  }
  return ctx.replyWithMarkdown(msg, Markup.inlineKeyboard(keyboard));
}

async function renderDnsManager(ctx, chatId, zoneId, domain, page = 1, isEdit = false, toastNotice = '') {
  const session = getSession(chatId);
  const auth = session?.cfToken;
  if (!auth) {
    return ctx.replyWithMarkdown('⚠️ دسترسی به کلودفلر یافت نشد. لطفاً دستور /dns را ارسال نمایید.');
  }

  const res = await listDnsRecords(auth, zoneId, 1, 100);
  if (!res.ok) {
    const errText = `❌ **خطا در دریافت رکوردهای DNS کلودفلر:**\n\`${res.error}\``;
    const buttons = Markup.inlineKeyboard([
      [Markup.button.callback('🔄 تلاش مجدد', `cf_dns:${zoneId}:${domain}`)],
      [Markup.button.callback('🔙 بازگشت به دامنه‌ها', 'back:select_zone')]
    ]);
    if (isEdit) return ctx.editMessageText(errText, buttons);
    return ctx.replyWithMarkdown(errText, buttons);
  }

  const allRecords = res.records || [];
  const pageSize = 5;
  const totalPages = Math.ceil(allRecords.length / pageSize) || 1;
  const curPage = Math.min(Math.max(1, page), totalPages);
  const startIdx = (curPage - 1) * pageSize;
  const pageRecords = allRecords.slice(startIdx, startIdx + pageSize);

  let text = `⚙️ **مدیریت رکوردهای DNS دامنه** \`${domain}\`\n📊 کل رکوردها: **${allRecords.length}** (صفحه ${curPage} از ${totalPages})\n\n`;

  if (toastNotice) {
    text += `🔔 ${toastNotice}\n\n`;
  }

  if (pageRecords.length === 0) {
    text += `_هیچ رکوردی برای این دامنه ثبت نشده است._\n\n`;
  } else {
    pageRecords.forEach((r, idx) => {
      const num = startIdx + idx + 1;
      const proxyIcon = r.proxied ? '☁️ Proxied' : '🔘 DNS Only';
      const displayContent = r.content.length > 28 ? r.content.substring(0, 25) + '...' : r.content;
      text += `${num}. [**${r.type}**] \`${r.name}\`\n   ➔ \`${displayContent}\` (${proxyIcon})\n`;
    });
    text += `\n_(راهنما: ☁️ پروکسی فعال | 🔘 پروکسی غیرفعال / مستقیم)_\n`;
  }

  const keyboard = [];

  if (pageRecords.length > 0) {
    const actionRows = pageRecords.map((r, idx) => {
      const num = startIdx + idx + 1;
      return [
        Markup.button.callback(`✏️ رکورد #${num}`, `cf_edit:${zoneId}:${domain}:${r.id}`),
        Markup.button.callback(`🗑 حذف #${num}`, `cf_del:${zoneId}:${domain}:${r.id}`)
      ];
    });
    keyboard.push(...actionRows);
  }

  const navRow = [];
  if (curPage > 1) {
    navRow.push(Markup.button.callback('◀️ صفحه قبلی', `cf_page:${zoneId}:${domain}:${curPage - 1}`));
  }
  if (curPage < totalPages) {
    navRow.push(Markup.button.callback('صفحه بعدی ▶️', `cf_page:${zoneId}:${domain}:${curPage + 1}`));
  }
  if (navRow.length > 0) {
    keyboard.push(navRow);
  }

  keyboard.push([
    Markup.button.callback('➕ افزودن رکورد DNS جدید', `cf_add:${zoneId}:${domain}`),
    Markup.button.callback('🧹 پاک‌سازی رکوردهای تانل', `cf_clean:${zoneId}:${domain}`)
  ]);

  keyboard.push([
    Markup.button.callback('🚀 ادامه نصب پنل (ورود آی‌پی سرور)', `cf_continue:${zoneId}:${domain}`),
    Markup.button.callback('🔙 بازگشت به لیست دامنه‌ها', 'back:select_zone')
  ]);

  if (isEdit) {
    return ctx.editMessageText(text, { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
  }
  return ctx.replyWithMarkdown(text, Markup.inlineKeyboard(keyboard));
}

bot.action('cmd:dns', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  if (session && session.cfToken) {
    return renderZonesForDns(ctx, chatId, session.cfToken, true);
  }
  saveSession(chatId, { step: 'AWAITING_DNS_CF_AUTH' });
  return ctx.editMessageText(
    `⚙️ **سامانه مدیریت رکوردهای DNS کلودفلر**\n\nجهت مشاهده، افزودن، ویرایش و حذف رکوردهای DNS دامنه، لطفاً **توکن API** یا **ایمیل اکانت کلودفلر** خود را ارسال فرمایید:`,
    Markup.inlineKeyboard([
      [Markup.button.url('🚀 ساخت توکن در کلودفلر', CF_TEMPLATE_URL)],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.action(/cf_dns:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  return renderDnsManager(ctx, ctx.chat.id, zoneId, domain, 1, true);
});

bot.action(/cf_page:(.+):(.+):([0-9]+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const page = parseInt(ctx.match[3], 10) || 1;
  return renderDnsManager(ctx, ctx.chat.id, zoneId, domain, page, true);
});

bot.action(/cf_add:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];

  return ctx.editMessageText(
    `➕ **افزودن رکورد DNS جدید برای دامنه:** \`${domain}\`\n\nلطفاً نوع رکورد مورد نظر خود را انتخاب فرمایید:`,
    Markup.inlineKeyboard([
      [
        Markup.button.callback('📌 رکورد A (IPv4)', `cf_add_type:${zoneId}:${domain}:A`),
        Markup.button.callback('🔗 رکورد CNAME', `cf_add_type:${zoneId}:${domain}:CNAME`)
      ],
      [
        Markup.button.callback('🌐 رکورد NS', `cf_add_type:${zoneId}:${domain}:NS`),
        Markup.button.callback('📝 رکورد TXT', `cf_add_type:${zoneId}:${domain}:TXT`)
      ],
      [
        Markup.button.callback('🔙 بازگشت به لیست رکوردها', `cf_dns:${zoneId}:${domain}`)
      ]
    ])
  );
});

bot.action(/cf_add_type:(.+):(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const type = ctx.match[3];

  tempDnsState.set(chatId, { zoneId, domain, type });
  saveSession(chatId, { step: 'AWAITING_DNS_ADD_NAME' });

  return ctx.editMessageText(
    `➕ **ثبت رکورد جدید [${type}] برای دامنه:** \`${domain}\`\n\n📌 لطفاً **نام یا ساب‌دامنه** را ارسال فرمایید:\n(مثلاً \`panel\` برای panel.${domain} یا \`@\` برای دامنه اصلی \`${domain}\`):`,
    Markup.inlineKeyboard([
      [Markup.button.callback('❌ انصراف و بازگشت', `cf_dns:${zoneId}:${domain}`)]
    ])
  );
});

bot.action(/cf_add_proxy:(.+):(.+):([01])/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const proxied = ctx.match[3] === '1';

  const st = tempDnsState.get(chatId) || {};
  const session = getSession(chatId);

  await ctx.editMessageText('⏳ در حال ثبت رکورد در کلودفلر...');

  const createRes = await createDnsRecord(session.cfToken, zoneId, {
    type: st.type,
    name: st.name,
    content: st.content,
    proxied
  });

  saveSession(chatId, { step: 'IDLE' });
  tempDnsState.delete(chatId);

  if (!createRes.ok) {
    return ctx.editMessageText(
      `❌ **خطا در ثبت رکورد DNS:**\n\`${createRes.error}\``,
      Markup.inlineKeyboard([
        [Markup.button.callback('🔙 بازگشت به لیست رکوردها', `cf_dns:${zoneId}:${domain}`)]
      ])
    );
  }

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, `✅ رکورد [${st.type}] ${st.name} با موفقیت افزوده شد.`);
});

bot.action(/cf_del:(.+):(.+):(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const recordId = ctx.match[3];
  const session = getSession(chatId);

  const getRes = await getDnsRecord(session.cfToken, zoneId, recordId);
  if (!getRes.ok) {
    return ctx.editMessageText(`❌ رکورد یافت نشد یا دسترسی وجود ندارد.`, Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', `cf_dns:${zoneId}:${domain}`)]
    ]));
  }

  const r = getRes.record;
  return ctx.editMessageText(
    `⚠️ **تایید حذف رکورد DNS:**\n\n• **نوع:** \`${r.type}\`\n• **نام:** \`${r.name}\`\n• **مقدار:** \`${r.content}\`\n• **پروکسی:** ${r.proxied ? '☁️ روشن' : '🔘 خاموش'}\n\nآیا از حذف دائمی این رکورد اطمینان دارید؟`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🗑 بله، حذف شود', `cf_del_conf:${zoneId}:${domain}:${recordId}`)],
      [Markup.button.callback('❌ خیر، بازگشت', `cf_dns:${zoneId}:${domain}`)]
    ])
  );
});

bot.action(/cf_del_conf:(.+):(.+):(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const recordId = ctx.match[3];
  const session = getSession(chatId);

  const delRes = await deleteDnsRecord(session.cfToken, zoneId, recordId);
  if (!delRes.ok) {
    return ctx.editMessageText(`❌ خطا در حذف رکورد: ${delRes.error}`, Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', `cf_dns:${zoneId}:${domain}`)]
    ]));
  }

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, '🗑 رکورد با موفقیت حذف شد.');
});

bot.action(/cf_edit:(.+):(.+):(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const recordId = ctx.match[3];
  const session = getSession(chatId);

  const getRes = await getDnsRecord(session.cfToken, zoneId, recordId);
  if (!getRes.ok) {
    return ctx.editMessageText(`❌ رکورد یافت نشد.`, Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', `cf_dns:${zoneId}:${domain}`)]
    ]));
  }

  const r = getRes.record;
  const keyboard = [
    [Markup.button.callback('✏️ تغییر مقدار / آی‌پی', `cf_edit_val:${zoneId}:${domain}:${recordId}`)]
  ];

  if (r.type === 'A' || r.type === 'AAAA' || r.type === 'CNAME') {
    const toggleLabel = r.proxied ? '🔘 خاموش کردن پروکسی (DNS Only)' : '☁️ روشن کردن پروکسی (Proxied)';
    keyboard.push([Markup.button.callback(toggleLabel, `cf_toggle_proxy:${zoneId}:${domain}:${recordId}`)]);
  }

  keyboard.push([
    Markup.button.callback('🔙 بازگشت به لیست رکوردها', `cf_dns:${zoneId}:${domain}`)
  ]);

  return ctx.editMessageText(
    `✏️ **مدیریت و ویرایش رکورد DNS:**\n\n• **نوع:** \`${r.type}\`\n• **نام:** \`${r.name}\`\n• **مقدار فعلی:** \`${r.content}\`\n• **وضعیت پروکسی:** ${r.proxied ? '☁️ روشن (Proxied)' : '🔘 خاموش (DNS Only)'}\n\nلطفاً عملیات مورد نظر را انتخاب فرمایید:`,
    Markup.inlineKeyboard(keyboard)
  );
});

bot.action(/cf_toggle_proxy:(.+):(.+):(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const recordId = ctx.match[3];
  const session = getSession(chatId);

  const getRes = await getDnsRecord(session.cfToken, zoneId, recordId);
  if (getRes.ok) {
    const newProxied = !getRes.record.proxied;
    await updateDnsRecord(session.cfToken, zoneId, recordId, { proxied: newProxied });
  }

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, '🔄 وضعیت پروکسی رکورد با موفقیت تغییر یافت.');
});

bot.action(/cf_edit_val:(.+):(.+):(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const recordId = ctx.match[3];
  const session = getSession(chatId);

  const getRes = await getDnsRecord(session.cfToken, zoneId, recordId);
  const curVal = getRes.ok ? getRes.record.content : '';
  const rName = getRes.ok ? getRes.record.name : domain;

  tempDnsState.set(chatId, { zoneId, domain, recordId });
  saveSession(chatId, { step: 'AWAITING_DNS_EDIT_VAL' });

  return ctx.editMessageText(
    `✏️ لطفاً **مقدار یا آی‌پی جدید** برای رکورد \`${rName}\` را ارسال فرمایید:\n\n_(مقدار فعلی: \`${curVal}\`)_`,
    Markup.inlineKeyboard([
      [Markup.button.callback('❌ انصراف و بازگشت', `cf_dns:${zoneId}:${domain}`)]
    ])
  );
});

bot.action(/cf_clean:(.+):(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  const session = getSession(chatId);

  await ctx.editMessageText('⏳ در حال پاک‌سازی رکوردهای تانل WhiteDNS...');
  await deleteSoarDnsRecords(session.cfToken, zoneId, domain);

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, '🧹 رکوردهای پیشین تانل WhiteDNS (ns-soar, soar, panel) با موفقیت پاک شدند.');
});

bot.action(/cf_continue:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];

  saveSession(chatId, { zoneId, domain, step: 'AWAITING_SSH_IP' });

  return ctx.editMessageText(
    `🌐 دامنه انتخاب‌شده: \`${domain}\`\n\n📌 اکنون لطفاً **آدرس IPv4 عمومی سرور (VPS)** خود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_\n\n💡 _همچنین می‌توانید مشخصات کامل را یکجا بفرستید:_\n\`IP:Port:User:Password\``,
    Markup.inlineKeyboard([
      [Markup.button.callback('⚙️ مدیریت مجدد رکوردهای DNS', `cf_dns:${zoneId}:${domain}`)],
      [
        Markup.button.callback('🔙 تغییر دامنه', 'back:select_zone'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

bot.action('port:22', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { vpsPort: 22, step: 'AWAITING_SSH_USER' });

  return ctx.editMessageText(
    `پورت SSH: \`22\`\n\nنام کاربری سرور را انتخاب کنید:`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🔘 کاربر پیش‌فرض (root)', 'user:root')],
      [Markup.button.callback('✏️ نام کاربری سفارشی', 'user:custom')],
      [
        Markup.button.callback('🔙 ویرایش آی‌پی سرور', 'back:ssh_ip'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

bot.action('port:custom', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { step: 'AWAITING_SSH_PORT_CUSTOM' });
  return ctx.reply('لطفاً شماره پورت SSH سرور خود را ارسال کنید:');
});

bot.action('user:root', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { vpsUser: 'root', step: 'AWAITING_SSH_PASS' });

  return ctx.editMessageText(
    `نام کاربری: \`root\`\n\n🔑 لطفاً **رمز عبور root سرور** را ارسال نمایید:\n_(پیام رمز عبور شما بلافاصله پس از دریافت حذف خواهد شد)_`,
    Markup.inlineKeyboard([
      [
        Markup.button.callback('🔙 تغییر پورت', 'back:ssh_port'),
        Markup.button.callback('❌ انصراف', 'cancel')
      ]
    ])
  );
});

bot.action('user:custom', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { step: 'AWAITING_SSH_USER_CUSTOM' });
  return ctx.reply('لطفاً نام کاربری SSH سرور خود را تایپ و ارسال کنید:');
});

// ----------------------------------------------------------------------------
// 4. REAL SSH DEPLOY TRIGGER
// ----------------------------------------------------------------------------

bot.action('deploy', async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);

  if (!session || !session.domain || !session.vpsIp || !session.cfToken || !session.vpsPass) {
    return ctx.reply('اطلاعات نشست ناقص است. لطفاً /start را بزنید.');
  }

  const { domain, vpsIp, vpsPort, vpsUser, vpsPass, cfToken, zoneId, adminPass } = session;

  const progressMsg = await ctx.replyWithMarkdown(
    renderProgressBox(1, 6, domain, vpsIp, 'در حال ثبت رکوردهای DNS در کلودفلر...')
  );

  try {
    // Step 1: Cloudflare DNS Setup
    await setupSoarDnsRecords(cfToken, zoneId, domain, vpsIp);

    await ctx.telegram.editMessageText(
      chatId,
      progressMsg.message_id,
      undefined,
      renderProgressBox(1, 7, domain, vpsIp, 'رکوردهای DNS در کلادفلر ثبت شدند. در حال اتصال SSH به سرور...'),
      { parse_mode: 'Markdown' }
    );

    // Step 1-7: Real SSH Execution
    let lastRenderedStep = 1;
    let lastRenderedMsg = '';
    let lastEditTime = Date.now();

    const result = await installOverSSH({
      vpsIp,
      vpsPort,
      vpsUser,
      vpsPass,
      domain,
      adminUser: 'admin',
      adminPass,
      onProgress: async (step, msg) => {
        const now = Date.now();
        const stepChanged = step !== lastRenderedStep;
        const msgChanged = msg && msg !== lastRenderedMsg;

        // Render immediately on step change, or update message if 1.5s passed
        if (stepChanged || (msgChanged && now - lastEditTime >= 1500)) {
          lastRenderedStep = step;
          lastRenderedMsg = msg;
          lastEditTime = now;
          const displayStep = Math.min(Math.max(step, 1), 7);
          await ctx.telegram.editMessageText(
            chatId,
            progressMsg.message_id,
            undefined,
            renderProgressBox(displayStep, 7, domain, vpsIp, msg),
            { parse_mode: 'Markdown' }
          ).catch(() => {});
        }
      }
    });

    // Save deployment to database
    addDeployment({
      chatId,
      domain,
      vpsIp,
      panelUrl: result.panelUrl,
      status: 'COMPLETED'
    });

    // Reset session
    saveSession(chatId, { step: 'COMPLETED' });

    // Send final card with the REAL access URL (containing random path!)
    await ctx.telegram.editMessageText(
      chatId,
      progressMsg.message_id,
      undefined,
      renderCompletionCard({
        panelUrl: result.panelUrl,
        adminUser: 'admin',
        adminPass,
        domain,
        publicIp: vpsIp,
        version: result.version
      }),
      { parse_mode: 'Markdown' }
    );

  } catch (err) {
    console.error('Installation error:', err);
    await ctx.telegram.editMessageText(
      chatId,
      progressMsg.message_id,
      undefined,
      renderErrorCard(err.message),
      { parse_mode: 'Markdown' }
    );
  }
});

// Helper for Cloudflare authentication
async function handleCloudflareAuth(ctx, chatId, authInput) {
  const statusMsg = await ctx.reply('⏳ در حال بررسی اتصال به اکانت کلودفلر...');

  const verify = await verifyToken(authInput);
  if (!verify.ok) {
    return ctx.telegram.editMessageText(
      chatId,
      statusMsg.message_id,
      undefined,
      `❌ **اطلاعات کلودفلر نامعتبر است!**\n\nعلت خطا: \`${verify.error || 'عدم تطابق ایمیل یا کلید'}\`\n\nلطفاً با زدن دکمه زیر، مجدداً توکن بگیرید یا کلید معتبر ارسال کنید:`,
      {
        parse_mode: 'Markdown',
        reply_markup: {
          inline_keyboard: [
            [{ text: '🚀 باز کردن فرم آماده ساخت توکن', url: CF_TEMPLATE_URL }],
            [
              { text: '🔙 ویرایش ایمیل', callback_data: 'back:cf_email' },
              { text: '❌ انصراف', callback_data: 'cancel' }
            ]
          ]
        }
      }
    );
  }

  const effectiveAuth = verify.resolvedAuth || authInput;
  const zonesRes = await listZones(effectiveAuth);

  if (!zonesRes.ok || !zonesRes.zones?.length) {
    return ctx.telegram.editMessageText(
      chatId,
      statusMsg.message_id,
      undefined,
      '⚠️ **ارتباط برقرار شد، اما هیچ دامنه‌ای در اکانت شما یافت نشد!**\nابتدا دامنه خود را در کلودفلر ثبت کنید، سپس /start را بزنید.',
      {
        parse_mode: 'Markdown',
        reply_markup: {
          inline_keyboard: [
            [{ text: '🔙 بازگشت به مرحله قبل', callback_data: 'back:cf_email' }],
            [{ text: '❌ انصراف', callback_data: 'cancel' }]
          ]
        }
      }
    );
  }

  saveSession(chatId, { cfToken: effectiveAuth, step: 'SELECTING_ZONE' });

  const keyboard = zonesRes.zones.map(z => ([
    Markup.button.callback(`🌐 ${z.name}`, `zone:${z.id}:${z.name}`)
  ]));

  keyboard.push([
    Markup.button.callback('🔙 تغییر اکانت کلودفلر', 'back:cf_email'),
    Markup.button.callback('❌ انصراف', 'cancel')
  ]);

  return ctx.telegram.editMessageText(
    chatId,
    statusMsg.message_id,
    undefined,
    `✅ **اتصال به کلودفلر با موفقیت برقرار شد.**\n_(پیام شما جهت امنیت پاک شد)_\n\n👇 دامنه مورد نظر خود برای نصب تانل را انتخاب کنید:`,
    {
      parse_mode: 'Markdown',
      reply_markup: { inline_keyboard: keyboard }
    }
  );
}

// ----------------------------------------------------------------------------
// 5. START BOT
// ----------------------------------------------------------------------------

registerCommands();

bot.launch(() => {
  console.log('🤖 WhiteDNS Linux Server Bot is online and listening for updates!');
});

// Enable graceful stop
process.once('SIGINT', () => bot.stop('SIGINT'));
process.once('SIGTERM', () => bot.stop('SIGTERM'));
