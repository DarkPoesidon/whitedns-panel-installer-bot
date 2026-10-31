import Database from 'better-sqlite3';
import { fileURLToPath } from 'url';
import path from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const dbPath = path.resolve(__dirname, '../data.db');

export const db = new Database(dbPath);

// Enable WAL mode for high concurrency
db.pragma('journal_mode = WAL');

// Initialize database tables
db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    chat_id INTEGER PRIMARY KEY,
    step TEXT NOT NULL DEFAULT 'IDLE',
    cf_token TEXT,
    zone_id TEXT,
    domain TEXT,
    vps_ip TEXT,
    vps_port INTEGER DEFAULT 22,
    vps_user TEXT DEFAULT 'root',
    vps_pass TEXT,
    admin_pass TEXT,
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
  );

  CREATE TABLE IF NOT EXISTS deployments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER NOT NULL,
    domain TEXT NOT NULL,
    vps_ip TEXT NOT NULL,
    panel_url TEXT,
    status TEXT DEFAULT 'IN_PROGRESS',
    created_at INTEGER DEFAULT (strftime('%s', 'now'))
  );
`);

export function getSession(chatId) {
  const row = db.prepare('SELECT * FROM sessions WHERE chat_id = ?').get(chatId);
  if (!row) return null;
  return {
    chatId: row.chat_id,
    step: row.step,
    cfToken: row.cf_token,
    zoneId: row.zone_id,
    domain: row.domain,
    vpsIp: row.vps_ip,
    vpsPort: row.vps_port,
    vpsUser: row.vps_user,
    vpsPass: row.vps_pass,
    adminPass: row.admin_pass
  };
}

export function saveSession(chatId, fields) {
  const existing = getSession(chatId);
  if (!existing) {
    db.prepare(`
      INSERT INTO sessions (chat_id, step, cf_token, zone_id, domain, vps_ip, vps_port, vps_user, vps_pass, admin_pass, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
    `).run(
      chatId,
      fields.step || 'IDLE',
      fields.cfToken || null,
      fields.zoneId || null,
      fields.domain || null,
      fields.vpsIp || null,
      fields.vpsPort || 22,
      fields.vpsUser || 'root',
      fields.vpsPass || null,
      fields.adminPass || null
    );
  } else {
    const updated = { ...existing, ...fields };
    db.prepare(`
      UPDATE sessions SET
        step = ?,
        cf_token = ?,
        zone_id = ?,
        domain = ?,
        vps_ip = ?,
        vps_port = ?,
        vps_user = ?,
        vps_pass = ?,
        admin_pass = ?,
        updated_at = strftime('%s', 'now')
      WHERE chat_id = ?
    `).run(
      updated.step,
      updated.cfToken,
      updated.zoneId,
      updated.domain,
      updated.vpsIp,
      updated.vpsPort,
      updated.vpsUser,
      updated.vpsPass,
      updated.adminPass,
      chatId
    );
  }
}

export function resetSession(chatId, initialStep = 'AWAITING_CF_EMAIL') {
  db.prepare(`
    INSERT INTO sessions (chat_id, step, cf_token, zone_id, domain, vps_ip, vps_port, vps_user, vps_pass, admin_pass, updated_at)
    VALUES (?, ?, NULL, NULL, NULL, NULL, 22, 'root', NULL, NULL, strftime('%s', 'now'))
    ON CONFLICT(chat_id) DO UPDATE SET
      step = ?,
      cf_token = NULL,
      zone_id = NULL,
      domain = NULL,
      vps_ip = NULL,
      vps_port = 22,
      vps_user = 'root',
      vps_pass = NULL,
      admin_pass = NULL,
      updated_at = strftime('%s', 'now')
  `).run(chatId, initialStep, initialStep);
}

export function addDeployment({ chatId, domain, vpsIp, panelUrl, status = 'COMPLETED' }) {
  db.prepare(`
    INSERT INTO deployments (chat_id, domain, vps_ip, panel_url, status)
    VALUES (?, ?, ?, ?, ?)
  `).run(chatId, domain, vpsIp, panelUrl, status);
}

export function listDeployments(chatId) {
  return db.prepare('SELECT * FROM deployments WHERE chat_id = ? ORDER BY id DESC').all(chatId);
}

export function removeDeployment(id) {
  db.prepare('DELETE FROM deployments WHERE id = ?').run(id);
}

export function deleteDeploymentByIp(chatId, vpsIp) {
  db.prepare('DELETE FROM deployments WHERE chat_id = ? AND vps_ip = ?').run(chatId, vpsIp);
}
