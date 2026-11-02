import { DatabaseSync } from 'node:sqlite';

const SESSION_TTL_SECONDS = 1800;
// Secrets belong in the vault; this guard turns a slip into a loud failure instead of a leak.
const SECRET_KEYS = new Set(['password', 'privateKey', 'passphrase', 'cfAuth', 'adminPass', 'cfToken', 'vpsPass']);

const columnsOf = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);

function migrate(db) {
  db.exec("PRAGMA secure_delete = ON");
  // Versions before 2.0 stored SSH passwords and Cloudflare tokens here in plain text.
  if (columnsOf(db, 'sessions').includes('vps_pass')) {
    db.exec('DROP TABLE sessions');
    db.exec('VACUUM');
    // In WAL mode VACUUM only reaches the log; the main file keeps the old pages until this runs.
    db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
  }
  db.exec(`
    CREATE TABLE IF NOT EXISTS wizard (
      chat_id INTEGER PRIMARY KEY,
      step TEXT NOT NULL DEFAULT 'IDLE',
      data TEXT NOT NULL DEFAULT '{}',
      updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    );
    CREATE TABLE IF NOT EXISTS deployments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      chat_id INTEGER NOT NULL,
      domain TEXT NOT NULL,
      vps_ip TEXT NOT NULL,
      panel_url TEXT,
      status TEXT DEFAULT 'COMPLETED',
      created_at INTEGER DEFAULT (strftime('%s', 'now'))
    );
    CREATE TABLE IF NOT EXISTS known_hosts (
      host TEXT NOT NULL,
      port INTEGER NOT NULL,
      fingerprint TEXT NOT NULL,
      PRIMARY KEY (host, port)
    );
    CREATE TABLE IF NOT EXISTS jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      chat_id INTEGER NOT NULL,
      host TEXT NOT NULL,
      op TEXT NOT NULL,
      finished INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    );
  `);
  const have = columnsOf(db, 'deployments');
  for (const [name, type] of [['ssh_port', 'INTEGER DEFAULT 22'], ['ssh_user', "TEXT DEFAULT 'root'"], ['zone', 'TEXT'], ['ns_host', 'TEXT'], ['panel_domain', 'TEXT'], ['zone_id', 'TEXT']]) {
    if (!have.includes(name)) db.exec(`ALTER TABLE deployments ADD COLUMN ${name} ${type}`);
  }
}

export function createStore(dbPath) {
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;');
  migrate(db);

  const cleanup = () => {
    const cutoff = Math.floor(Date.now() / 1000) - SESSION_TTL_SECONDS;
    db.prepare('DELETE FROM wizard WHERE updated_at < ?').run(cutoff);
  };

  return {
    close: () => db.close(),
    cleanup,

    getSession(chatId) {
      const row = db.prepare('SELECT step, data FROM wizard WHERE chat_id = ?').get(chatId);
      return row ? { ...JSON.parse(row.data), step: row.step } : { step: 'IDLE' };
    },
    saveSession(chatId, fields) {
      for (const key of Object.keys(fields)) {
        if (SECRET_KEYS.has(key)) throw new Error(`refusing to persist secret field ${key}`);
      }
      const { step, ...data } = { ...this.getSession(chatId), ...fields };
      db.prepare(`
        INSERT INTO wizard (chat_id, step, data, updated_at) VALUES (?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(chat_id) DO UPDATE SET step = excluded.step, data = excluded.data, updated_at = excluded.updated_at
      `).run(chatId, step, JSON.stringify(data));
    },
    resetSession(chatId, step = 'IDLE') {
      db.prepare(`
        INSERT INTO wizard (chat_id, step, data, updated_at) VALUES (?, ?, '{}', strftime('%s', 'now'))
        ON CONFLICT(chat_id) DO UPDATE SET step = excluded.step, data = '{}', updated_at = excluded.updated_at
      `).run(chatId, step);
    },

    /** One row per server: a reinstall or repair updates the row instead of adding another. */
    upsertDeployment({ chatId, domain, vpsIp, panelUrl, sshPort = 22, sshUser = 'root', zone = null, nsHost = null, panelDomain = null, zoneId = null, status = 'COMPLETED' }) {
      const existing = db.prepare('SELECT id FROM deployments WHERE chat_id = ? AND vps_ip = ?').get(chatId, vpsIp);
      if (existing) {
        db.prepare(`
          UPDATE deployments SET domain = ?, panel_url = COALESCE(?, panel_url), status = ?, ssh_port = ?, ssh_user = ?,
            zone = COALESCE(?, zone), ns_host = COALESCE(?, ns_host), panel_domain = COALESCE(?, panel_domain), zone_id = COALESCE(?, zone_id)
          WHERE id = ?
        `).run(domain, panelUrl ?? null, status, sshPort, sshUser, zone, nsHost, panelDomain, zoneId, existing.id);
        return existing.id;
      }
      return Number(db.prepare(`
        INSERT INTO deployments (chat_id, domain, vps_ip, panel_url, status, ssh_port, ssh_user, zone, ns_host, panel_domain, zone_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(chatId, domain, vpsIp, panelUrl ?? null, status, sshPort, sshUser, zone, nsHost, panelDomain, zoneId).lastInsertRowid);
    },
    listDeployments(chatId) {
      return db.prepare('SELECT * FROM deployments WHERE chat_id = ? ORDER BY id DESC').all(chatId);
    },
    getDeployment(chatId, id) {
      return db.prepare('SELECT * FROM deployments WHERE chat_id = ? AND id = ?').get(chatId, id);
    },
    deleteDeployment(chatId, id) {
      db.prepare('DELETE FROM deployments WHERE chat_id = ? AND id = ?').run(chatId, id);
    },

    getKnownHost(host, port) {
      return db.prepare('SELECT fingerprint FROM known_hosts WHERE host = ? AND port = ?').get(host, port)?.fingerprint ?? null;
    },
    setKnownHost(host, port, fingerprint) {
      db.prepare(`
        INSERT INTO known_hosts (host, port, fingerprint) VALUES (?, ?, ?)
        ON CONFLICT(host, port) DO UPDATE SET fingerprint = excluded.fingerprint
      `).run(host, port, fingerprint);
    },

    beginJob(chatId, host, op) {
      return Number(db.prepare('INSERT INTO jobs (chat_id, host, op) VALUES (?, ?, ?)').run(chatId, host, op).lastInsertRowid);
    },
    finishJob(id) {
      db.prepare('UPDATE jobs SET finished = 1 WHERE id = ?').run(id);
    },
    /** Jobs the previous process left behind; returned once, then marked as handled. */
    takeOrphanedJobs() {
      const rows = db.prepare('SELECT * FROM jobs WHERE finished = 0').all();
      db.exec('UPDATE jobs SET finished = 1 WHERE finished = 0');
      return rows;
    },
  };
}
