import { Telegraf } from 'telegraf';
import { BTN, HELP_TEXT } from './ui.js';
import { action, createAttemptLimiter, createTasks, respond } from './flows/common.js';
import { installFlow } from './flows/install.js';
import { maintenanceFlow } from './flows/maintenance.js';
import { dnsFlow } from './flows/dns.js';
import { adminFlow } from './flows/admin.js';

const COMMANDS = [
  { command: 'start', description: '🚀 شروع و نصب پنل WhiteDNS' },
  { command: 'status', description: '📊 مشاهده سرورها و پنل‌های فعال' },
  { command: 'repair', description: '🛠 عیب‌یابی و تعمیر خودکار سرور' },
  { command: 'dns', description: '⚙️ مدیریت رکوردهای DNS کلودفلر' },
  { command: 'uninstall', description: '🗑 حذف پنل WhiteDNS از سرور' },
  { command: 'help', description: '❓ راهنما و پیش‌نیازها' },
  { command: 'reset', description: '🔄 لغو و شروع مجدد' },
];

export function createApp({ token, apiRoot, store, vault, deps, adminIds = new Set(), requestFile, statusFile, reportedFile, pollMs }) {
  const bot = new Telegraf(token, apiRoot ? { telegram: { apiRoot } } : {});
  const tasks = createTasks(bot.telegram);
  const app = { store, vault, deps, tasks, steps: {}, checkAttemptLimit: createAttemptLimiter() };

  bot.catch((err, ctx) => {
    console.error(`bot error on ${ctx?.updateType}:`, err.message);
    ctx?.reply?.('⚠️ خطایی رخ داد. لطفاً با /reset یا /start دوباره تلاش کنید.').catch(() => {});
  });

  // Passwords must never be typed where other members could read them.
  bot.use(async (ctx, next) => {
    if (ctx.chat && ctx.chat.type !== 'private') {
      if (ctx.message?.text?.startsWith('/')) await ctx.reply('🔒 این ربات برای امنیت رمزها فقط در چت خصوصی کار می‌کند.').catch(() => {});
      return undefined;
    }
    return next();
  });

  const { zoneCache } = installFlow({ bot, app });
  maintenanceFlow({ bot, app });
  dnsFlow({ bot, app, zoneCache });
  const admin = adminFlow({ bot, app, adminIds, requestFile, statusFile, reportedFile, pollMs });

  bot.command('help', (ctx) => respond(ctx, HELP_TEXT, [[BTN.start], [BTN.repair], [BTN.dns]]));

  const reset = (ctx) => {
    store.resetSession(ctx.chat.id);
    vault.clear(ctx.chat.id);
    return respond(ctx, '🔄 <b>عملیات جاری لغو و اطلاعات موقت پاک شد.</b>', [[{ text: '🚀 شروع مجدد', data: 'cmd:start' }]]);
  };
  bot.command(['reset', 'cancel'], reset);
  action(bot, 'cancel', reset);

  bot.on('text', async (ctx) => {
    const session = store.getSession(ctx.chat.id);
    const handler = app.steps[session.step];
    if (handler) await handler(ctx, ctx.message.text.trim(), session);
  });

  return {
    bot,
    tasks,
    admin,
    async announceOrphans() {
      for (const job of store.takeOrphanedJobs()) {
        await bot.telegram.sendMessage(job.chat_id, `ℹ️ ربات حین عملیات روی <code>${job.host}</code> ریستارت شد. کار روی خود سرور ادامه دارد. برای دیدن نتیجه /repair را بزنید.`, { parse_mode: 'HTML' }).catch(() => {});
      }
    },
    registerCommands: () => bot.telegram.setMyCommands(COMMANDS).catch((err) => console.warn('setMyCommands:', err.message)),
  };
}
