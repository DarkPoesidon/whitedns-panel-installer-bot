import net from 'node:net';
import dns from 'node:dns/promises';
import { ALLOW_PRIVATE_TARGETS } from '../config.js';
import { SshError } from '../ssh.js';
import { BTN, failureText, show } from '../ui.js';
import { escapeHtml as esc, isPrivateKey, isPublicIPv4 } from '../validate.js';

/** Replies to a callback by editing its message, and to a text message with a new one. */
export const respond = (ctx, text, rows) => show(ctx.telegram, ctx.chat.id, ctx.callbackQuery?.message?.message_id, text, rows);

export function action(bot, trigger, handler) {
  bot.action(trigger, async (ctx) => {
    ctx.answerCbQuery().catch(() => {});
    return handler(ctx);
  });
}

/** Removes a message carrying a secret, and says so when Telegram refuses. */
export async function scrub(ctx) {
  try {
    await ctx.deleteMessage();
  } catch {
    await ctx.reply('⚠️ حذف پیام حاوی رمز ممکن نشد. لطفاً آن را خودتان از چت پاک کنید.').catch(() => {});
  }
}

/**
 * Long work runs outside the Telegraf handler: its 90s handlerTimeout would otherwise abort
 * the handler and polling would stall for every other user meanwhile.
 */
export function createTasks(telegram) {
  const running = new Set();
  const busyHosts = new Set();
  return {
    run(chatId, fn) {
      const job = Promise.resolve()
        .then(fn)
        .catch(async (err) => {
          console.error('task failed:', err.code ?? '', err.message);
          const text = `❌ ${esc(err.code ? failureText(err.code) : 'خطای غیرمنتظره رخ داد.')}`;
          await show(telegram, chatId, null, text, [[BTN.status]]).catch(() => {});
        })
        .finally(() => running.delete(job));
      running.add(job);
      return job;
    },
    /** Rejects a second operation on a server while one is running. */
    tryLock(host) {
      if (busyHosts.has(host)) return false;
      busyHosts.add(host);
      return true;
    },
    unlock(host) {
      busyHosts.delete(host);
    },
    idle: async () => {
      while (running.size) await Promise.allSettled([...running]);
    },
  };
}

/** Coalesces progress edits to stay under Telegram's per-chat edit limit. */
export function throttled(fn, intervalMs = 3500) {
  let last = 0;
  let pending = null;
  let timer = null;
  let inFlight = Promise.resolve();
  const flush = () => {
    timer = null;
    if (pending === null) return;
    const value = pending;
    pending = null;
    last = Date.now();
    inFlight = Promise.resolve(fn(value)).catch(() => {});
  };
  return {
    push(value) {
      pending = value;
      if (timer) return;
      timer = setTimeout(flush, Math.max(0, last + intervalMs - Date.now()));
      timer.unref?.();
    },
    async finish() {
      clearTimeout(timer);
      pending = null;
      timer = null;
      // A late progress edit must not overwrite the result card that follows.
      await inFlight;
    },
  };
}

/** Stores a typed password or pasted private key in the vault, never in the session. */
export function storeCredential(vault, chatId, text) {
  if (isPrivateKey(text)) vault.set(chatId, { privateKey: text.trim(), password: undefined });
  else vault.set(chatId, { password: text, privateKey: undefined });
}

export const hasCredential = (vault, chatId) => Boolean(vault.get(chatId, 'password') || vault.get(chatId, 'privateKey'));

const NON_PUBLIC_V6 = new net.BlockList();
NON_PUBLIC_V6.addAddress('::', 'ipv6');
NON_PUBLIC_V6.addAddress('::1', 'ipv6');
NON_PUBLIC_V6.addSubnet('fc00::', 7, 'ipv6');
NON_PUBLIC_V6.addSubnet('fe80::', 10, 'ipv6');
NON_PUBLIC_V6.addSubnet('ff00::', 8, 'ipv6');
NON_PUBLIC_V6.addSubnet('::ffff:0:0', 96, 'ipv6');

const isPublicAddress = (address) => (net.isIPv4(address) ? isPublicIPv4(address) : !NON_PUBLIC_V6.check(address, 'ipv6'));

/**
 * The bot is public, so without this anyone could aim it at its own loopback or private network.
 * Connecting to the checked address, not the name, closes the DNS rebinding gap.
 */
export async function resolvePublicTarget(host, { lookup = dns.lookup, allowPrivate = ALLOW_PRIVATE_TARGETS } = {}) {
  if (allowPrivate) return host;
  const addresses = net.isIP(host) ? [host] : (await lookup(host, { all: true })).map((entry) => entry.address);
  const allowed = addresses.filter(isPublicAddress);
  if (!allowed.length || allowed.length !== addresses.length) throw new SshError('PRIVATE_TARGET', host);
  return allowed[0];
}

const ATTEMPT_LIMIT = 10;
const ATTEMPT_WINDOW_MS = 15 * 60 * 1000;

/** Caps new SSH attempts per chat so the bot cannot be used to guess passwords on other servers. */
export function createAttemptLimiter() {
  const attempts = new Map();
  return (chatId, now = Date.now()) => {
    const recent = (attempts.get(chatId) ?? []).filter((at) => now - at < ATTEMPT_WINDOW_MS);
    if (recent.length >= ATTEMPT_LIMIT) throw new SshError('RATE_LIMITED');
    recent.push(now);
    attempts.set(chatId, recent);
  };
}

/** Opens SSH with the credentials in the vault, pinning the host key on first contact. */
export function connector({ store, vault, deps, checkAttemptLimit }, chatId, target) {
  const credentials = {
    password: vault.get(chatId, 'password'),
    privateKey: vault.get(chatId, 'privateKey'),
  };
  // Counted per operation; reconnects while following a running job stay within it.
  let counted = false;
  return async () => {
    if (!counted) {
      checkAttemptLimit(chatId);
      counted = true;
    }
    const session = await deps.connectSsh({
      host: await resolvePublicTarget(target.host),
      port: target.port,
      user: target.user,
      ...credentials,
      expectedFingerprint: store.getKnownHost(target.host, target.port),
    });
    store.setKnownHost(target.host, target.port, session.fingerprint);
    return session;
  };
}

export const hostKeyChangedText = (host, fingerprint) => `🚨 <b>کلید میزبان سرور <code>${esc(host)}</code> تغییر کرده است.</b>

اگر سرور را تازه نصب یا بازسازی کرده‌اید این طبیعی است. در غیر این صورت ممکن است اتصال شما شنود شود، و رمز ارسال نشده است.

اثرانگشت جدید:
<code>SHA256:${esc(fingerprint)}</code>`;
