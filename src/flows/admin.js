import fs from 'node:fs';
import { respond } from './common.js';
import { escapeHtml as esc } from '../validate.js';

const POLL_MS = 3000;
const POLL_LIMIT_MS = 6 * 60 * 1000;

const readText = (file) => {
  try {
    return fs.readFileSync(file, 'utf8').trim();
  } catch {
    return '';
  }
};

/** Status line from update.sh: `<ok|failed> <commit> <chatId> <epoch>` */
export function parseUpdateStatus(line) {
  const [state, commit, chatId, at] = line.split(' ');
  return state ? { state, commit, chatId: Number(chatId), at } : null;
}

/**
 * /update only drops a request file. A root path unit (see scripts/bot-setup.sh) performs the
 * update, so this unprivileged process never runs git or systemctl and cannot gain root through it.
 */
export function adminFlow({ bot, app, adminIds, requestFile, statusFile, reportedFile, pollMs = POLL_MS }) {
  const { tasks } = app;
  const isAdmin = (ctx) => adminIds.has(ctx.chat.id);
  const outcome = ({ state, commit }) => (state === 'ok'
    ? `✅ ربات به‌روز است (${commit}).`
    : `❌ به‌روزرسانی به ${commit} شکست خورد و نسخهٔ قبلی برگردانده شد.`);

  bot.command('id', (ctx) => respond(ctx, `🆔 شناسهٔ چت شما: <code>${esc(ctx.chat.id)}</code>`));

  bot.command('update', async (ctx) => {
    if (!isAdmin(ctx)) {
      return respond(ctx, '⛔ این دستور فقط برای مدیر این ربات است. شناسهٔ مدیر در <code>ADMIN_CHAT_IDS</code> فایل <code>.env</code> تعریف می‌شود.');
    }
    const before = readText(statusFile);
    fs.writeFileSync(requestFile, `${ctx.chat.id}\n`, { mode: 0o600 });
    const message = await ctx.reply('⏳ درخواست به‌روزرسانی ثبت شد. ربات ممکن است چند لحظه ریستارت شود...');
    tasks.run(ctx.chat.id, () => watchUpdate(ctx.telegram, ctx.chat.id, message.message_id, before));
    return undefined;
  });

  async function watchUpdate(telegram, chatId, messageId, before) {
    const deadline = Date.now() + POLL_LIMIT_MS;
    while (Date.now() < deadline) {
      await new Promise((resolve) => { setTimeout(resolve, pollMs); });
      const line = readText(statusFile);
      if (line && line !== before) {
        fs.writeFileSync(reportedFile, line);
        await telegram.editMessageText(chatId, messageId, undefined, outcome(parseUpdateStatus(line))).catch(() => {});
        return;
      }
    }
    await telegram.editMessageText(chatId, messageId, undefined, '⚠️ نتیجهٔ به‌روزرسانی نرسید. لاگ را با <code>journalctl -u whitedns-bot-update</code> ببینید.', { parse_mode: 'HTML' }).catch(() => {});
  }

  /** An update restarts this process, so its result is reported on the next start, once. */
  function reportFinishedUpdate(telegram) {
    const line = readText(statusFile);
    if (!line || line === readText(reportedFile)) return;
    fs.writeFileSync(reportedFile, line);
    const status = parseUpdateStatus(line);
    if (status.chatId) telegram.sendMessage(status.chatId, outcome(status)).catch(() => {});
  }

  return { reportFinishedUpdate };
}
