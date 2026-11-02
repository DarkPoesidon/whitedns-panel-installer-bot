import 'dotenv/config';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const AGENT_SCRIPT = path.join(ROOT_DIR, 'scripts', 'agent.sh');
export const DATA_DIR = process.env.DATA_DIR || ROOT_DIR;
export const DB_PATH = path.join(DATA_DIR, 'data.db');
export const UPDATE_REQUEST_FILE = path.join(DATA_DIR, 'update-request');
// Written by the root updater, outside the directory this unprivileged process can modify.
export const UPDATE_STATUS_FILE = process.env.UPDATE_STATUS_FILE || path.join(DATA_DIR, 'update-status');
export const UPDATE_REPORTED_FILE = path.join(DATA_DIR, 'update-reported');

export const BOT_TOKEN = process.env.BOT_TOKEN || '';
// For hosts where api.telegram.org is blocked: a self-hosted Bot API server or reverse proxy.
export const TELEGRAM_API_ROOT = process.env.TELEGRAM_API_ROOT || '';
// Off by default: a public bot must not reach its own private network. For private LAN deployments only.
export const ALLOW_PRIVATE_TARGETS = process.env.ALLOW_PRIVATE_TARGETS === '1';
export const ADMIN_CHAT_IDS = new Set(
  (process.env.ADMIN_CHAT_IDS || '').split(',').map((id) => id.trim()).filter(Boolean).map(Number),
);

// The tested panel release. Hashes come from the release's .sha256 assets.
export const PANEL_VERSION = process.env.SOAR_PANEL_VERSION || '0.14.0';
const PINNED_HASHES = {
  '0.14.0': {
    amd64: 'b4132db4b3b801a125885aba2654e3dcc8621dc9c071e2167225202f3175d9ab',
    arm64: '6c51c2e5e8da6ff9cadfd6e26c4d483d8d9641a8387171c0f0bde38d2336e3e5',
  },
};
/** An unpinned SOAR_PANEL_VERSION falls back to the release's own .sha256 file on the server. */
export function panelHash(arch) {
  return PINNED_HASHES[PANEL_VERSION]?.[arch] ?? '';
}
export function bundleUrl(arch) {
  return `https://github.com/WhiteDNS/Soar-Server/releases/download/panel-v${PANEL_VERSION}/soar-panel-${PANEL_VERSION}-linux-${arch}.tar.gz`;
}

export const CF_TEMPLATE_URL = 'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&accountId=*&zoneId=all&name=WhiteDNS';
