// Secrets live only in this process's memory, never in SQLite, and expire on their own.
const TTL_MS = 30 * 60 * 1000;

export function createVault({ ttlMs = TTL_MS, now = Date.now } = {}) {
  const entries = new Map();

  const live = (chatId) => {
    const entry = entries.get(chatId);
    if (!entry) return null;
    if (now() > entry.expires) {
      entries.delete(chatId);
      return null;
    }
    return entry;
  };

  return {
    get(chatId, key) {
      return live(chatId)?.values[key];
    },
    set(chatId, values) {
      const entry = live(chatId) ?? { values: {} };
      Object.assign(entry.values, values);
      entry.expires = now() + ttlMs;
      entries.set(chatId, entry);
    },
    clear(chatId) {
      entries.delete(chatId);
    },
    sweep() {
      for (const chatId of entries.keys()) live(chatId);
    },
  };
}

export const vault = createVault();
setInterval(() => vault.sweep(), 5 * 60 * 1000).unref();
