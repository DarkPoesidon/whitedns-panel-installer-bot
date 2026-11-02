import fs from 'node:fs';
import { ADMIN_CHAT_IDS, BOT_TOKEN, DATA_DIR, DB_PATH, TELEGRAM_API_ROOT, UPDATE_REPORTED_FILE, UPDATE_REQUEST_FILE, UPDATE_STATUS_FILE } from './config.js';
import { createApp } from './app.js';
import { createStore } from './db.js';
import { vault } from './vault.js';
import { connectSsh } from './ssh.js';
import { cleanupAgentDir, probe, runJob } from './agent.js';
import * as cf from './cloudflare.js';

if (!BOT_TOKEN) {
  console.error('FATAL: BOT_TOKEN is missing. Provide it in the .env file.');
  process.exit(1);
}

fs.mkdirSync(DATA_DIR, { recursive: true });
const store = createStore(DB_PATH);
setInterval(() => store.cleanup(), 5 * 60 * 1000).unref();

const { bot, admin, announceOrphans, registerCommands } = createApp({
  token: BOT_TOKEN,
  apiRoot: TELEGRAM_API_ROOT,
  store,
  vault,
  adminIds: ADMIN_CHAT_IDS,
  requestFile: UPDATE_REQUEST_FILE,
  statusFile: UPDATE_STATUS_FILE,
  reportedFile: UPDATE_REPORTED_FILE,
  deps: { connectSsh, probe, runJob, cleanupAgentDir, cf },
});

await registerCommands();
await announceOrphans();
admin.reportFinishedUpdate(bot.telegram);
bot.launch(() => console.log('WhiteDNS bot is online.')).catch((err) => {
  console.error('FATAL: could not start polling:', err.message);
  process.exit(1);
});

process.once('SIGINT', () => bot.stop('SIGINT'));
process.once('SIGTERM', () => bot.stop('SIGTERM'));
