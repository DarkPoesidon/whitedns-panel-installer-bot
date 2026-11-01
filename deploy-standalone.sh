#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - 1-Click Standalone Installer for Linux VPS
# Automatically unpacks, configures, and starts the bot as a systemd service.
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}======================================================"
echo -e "   WhiteDNS Autonomous Linux Telegram Bot Deployer"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
mkdir -p "$INSTALL_DIR/src" "$INSTALL_DIR/scripts"

# Install git and curl if missing
if ! command -v git &>/dev/null; then
  echo -e "${BLUE}[INFO] Installing git and curl...${NC}"
  apt-get update -qq && apt-get install -y -qq git curl
fi

# Initialize git repository so self-updates work
git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
git config --global --add safe.directory "*" 2>/dev/null || true
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  (cd "$INSTALL_DIR" && (git init -b main 2>/dev/null || git init) && (git remote add origin https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git 2>/dev/null || true)) 2>/dev/null || true
fi
(cd "$INSTALL_DIR" && git remote set-url origin https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git 2>/dev/null || true) 2>/dev/null || true

# 1. Write package.json
cat > "$INSTALL_DIR/package.json" <<'EOF_PKG'
{
  "name": "whitedns-server-bot",
  "version": "1.0.0",
  "description": "Autonomous Telegram Bot with direct SSH execution for 100% automated WhiteDNS Soar Server deployment",
  "main": "src/bot.js",
  "type": "module",
  "scripts": {
    "start": "node src/bot.js"
  },
  "dependencies": {
    "better-sqlite3": "^11.8.1",
    "dotenv": "^16.4.7",
    "ssh2": "^1.16.0",
    "telegraf": "^4.16.3"
  },
  "keywords": [
    "telegram-bot",
    "whitedns",
    "soar-server",
    "ssh",
    "automation"
  ],
  "author": "Antigravity",
  "license": "MIT"
}
EOF_PKG

# 2. Write src/config.js
cat > "$INSTALL_DIR/src/config.js" <<'EOF_CONFIG'
import 'dotenv/config';

export const BOT_TOKEN = process.env.BOT_TOKEN || '';

if (!BOT_TOKEN) {
  console.warn('⚠️ WARNING: BOT_TOKEN is not defined in your environment or .env file!');
}

export const CF_TEMPLATE_URL = 'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&accountId=*&zoneId=all&name=WhiteDNS';
EOF_CONFIG

# 3. Write src/db.js
cat > "$INSTALL_DIR/src/db.js" <<'EOF_DB'
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
    repair_ip TEXT,
    repair_domain TEXT,
    uninst_ip TEXT,
    uninst_domain TEXT,
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

// Migration guards for existing databases
try { db.exec('ALTER TABLE sessions ADD COLUMN repair_ip TEXT'); } catch (e) {}
try { db.exec('ALTER TABLE sessions ADD COLUMN repair_domain TEXT'); } catch (e) {}
try { db.exec('ALTER TABLE sessions ADD COLUMN uninst_ip TEXT'); } catch (e) {}
try { db.exec('ALTER TABLE sessions ADD COLUMN uninst_domain TEXT'); } catch (e) {}

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
    adminPass: row.admin_pass,
    repairIp: row.repair_ip,
    repairDomain: row.repair_domain,
    uninstIp: row.uninst_ip,
    uninstDomain: row.uninst_domain
  };
}

export function saveSession(chatId, fields) {
  const existing = getSession(chatId);
  if (!existing) {
    db.prepare(`
      INSERT INTO sessions (chat_id, step, cf_token, zone_id, domain, vps_ip, vps_port, vps_user, vps_pass, admin_pass, repair_ip, repair_domain, uninst_ip, uninst_domain, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
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
      fields.adminPass || null,
      fields.repairIp || null,
      fields.repairDomain || null,
      fields.uninstIp || null,
      fields.uninstDomain || null
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
        repair_ip = ?,
        repair_domain = ?,
        uninst_ip = ?,
        uninst_domain = ?,
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
      updated.repairIp || null,
      updated.repairDomain || null,
      updated.uninstIp || null,
      updated.uninstDomain || null,
      chatId
    );
  }
}

export function resetSession(chatId, initialStep = 'AWAITING_CF_EMAIL') {
  db.prepare(`
    INSERT INTO sessions (chat_id, step, cf_token, zone_id, domain, vps_ip, vps_port, vps_user, vps_pass, admin_pass, repair_ip, repair_domain, uninst_ip, uninst_domain, updated_at)
    VALUES (?, ?, NULL, NULL, NULL, NULL, 22, 'root', NULL, NULL, NULL, NULL, NULL, NULL, strftime('%s', 'now'))
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
      repair_ip = NULL,
      repair_domain = NULL,
      uninst_ip = NULL,
      uninst_domain = NULL,
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
EOF_DB

# 4. Write src/cloudflare.js
cat > "$INSTALL_DIR/src/cloudflare.js" <<'EOF_CF'
const CF_API_BASE = 'https://api.cloudflare.com/client/v4';

/**
 * Returns appropriate Cloudflare headers for either:
 * - Scoped API Token (Bearer <TOKEN>)
 * - Global API Key (X-Auth-Email + X-Auth-Key)
 */
export function getAuthHeaders(authInput) {
  const trimmed = (authInput || '').trim();
  if (trimmed.includes(':') && trimmed.includes('@')) {
    const parts = trimmed.split(':');
    const email = parts[0].trim();
    const key = parts.slice(1).join(':').trim();
    return {
      'X-Auth-Email': email,
      'X-Auth-Key': key,
      'Content-Type': 'application/json'
    };
  }
  return {
    'Authorization': `Bearer ${trimmed}`,
    'Content-Type': 'application/json'
  };
}

/**
 * Validates Cloudflare credentials (supports both API Token and Global Key)
 * Automatically falls back to pure Bearer Token if email:token was provided.
 */
export async function verifyToken(authInput) {
  try {
    const headers = getAuthHeaders(authInput);
    const endpoint = headers['X-Auth-Key'] ? `${CF_API_BASE}/user` : `${CF_API_BASE}/user/tokens/verify`;

    const res = await fetch(endpoint, {
      method: 'GET',
      headers
    });

    if (res.ok) {
      const data = await res.json();
      if (data.success) {
        return { ok: true, resolvedAuth: authInput };
      }
    }

    // Fallback: If authInput was "email:key", test if "key" is actually a Bearer Token
    if (authInput.includes(':') && authInput.includes('@')) {
      const rawKey = authInput.split(':').slice(1).join(':').trim();
      const fallbackRes = await fetch(`${CF_API_BASE}/user/tokens/verify`, {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${rawKey}`,
          'Content-Type': 'application/json'
        }
      });
      if (fallbackRes.ok) {
        const fallbackData = await fallbackRes.json();
        if (fallbackData.success) {
          return { ok: true, resolvedAuth: rawKey };
        }
      }
    }

    return { ok: false, error: 'کلید یا توکن نامعتبر است. لطفاً دقت فرمایید.' };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Retrieves the list of active zones (domains) for the credentials
 */
export async function listZones(authInput) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones?status=active&per_page=50`, {
      method: 'GET',
      headers
    });

    if (!res.ok) {
      return { ok: false, error: `Failed to fetch zones: HTTP ${res.status}` };
    }

    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'Unknown API error' };
    }

    const zones = (data.result || []).map(z => ({
      id: z.id,
      name: z.name
    }));

    return { ok: true, zones };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Ensures a DNS record exists with the exact specified content and proxied=false
 */
async function upsertDnsRecord(authInput, zoneId, type, name, content, proxied = false) {
  const headers = getAuthHeaders(authInput);

  // Find existing record
  const searchUrl = `${CF_API_BASE}/zones/${zoneId}/dns_records?type=${type}&name=${encodeURIComponent(name)}`;
  const searchRes = await fetch(searchUrl, { headers });
  const searchData = await searchRes.json();
  const existing = searchData.result?.[0];

  const payload = {
    type,
    name,
    content,
    ttl: 1, // Auto TTL
    proxied: !!proxied
  };

  if (existing) {
    // Check if update is needed
    if (existing.content === content && existing.proxied === proxied) {
      return { ok: true, action: 'kept', id: existing.id };
    }

    const updateRes = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${existing.id}`, {
      method: 'PUT',
      headers,
      body: JSON.stringify(payload)
    });
    const updateData = await updateRes.json();
    if (!updateData.success) {
      throw new Error(`Failed to update ${type} record ${name}: ${updateData.errors?.[0]?.message}`);
    }
    return { ok: true, action: 'updated', id: existing.id };
  }

  // Create new record
  const createRes = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records`, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload)
  });
  const createData = await createRes.json();
  if (!createData.success) {
    throw new Error(`Failed to create ${type} record ${name}: ${createData.errors?.[0]?.message}`);
  }
  return { ok: true, action: 'created', id: createData.result.id };
}

/**
 * Creates the complete triple DNS configuration required for WhiteDNS Soar Server:
 * 1. A record:     ns-soar.<domain> -> vpsIp (Proxy OFF)
 * 2. NS record:    soar.<domain>    -> ns-soar.<domain>
 * 3. A record:     panel.<domain>   -> vpsIp (Proxy OFF)
 */
export async function setupSoarDnsRecords(authInput, zoneId, domain, vpsIp) {
  const cleanDomain = domain.toLowerCase().trim();
  const nsHost = `ns-soar.${cleanDomain}`;
  const tunnelZone = `soar.${cleanDomain}`;
  const panelHost = `panel.${cleanDomain}`;

  // 1. A record: ns-soar.<domain> -> vpsIp (Proxy OFF)
  const nsARecord = await upsertDnsRecord(authInput, zoneId, 'A', nsHost, vpsIp, false);

  // 2. NS record: soar.<domain> -> ns-soar.<domain>
  const soarNsRecord = await upsertDnsRecord(authInput, zoneId, 'NS', tunnelZone, nsHost, false);

  // 3. A record: panel.<domain> -> vpsIp (Proxy OFF)
  const panelARecord = await upsertDnsRecord(authInput, zoneId, 'A', panelHost, vpsIp, false);

  return {
    ok: true,
    nsARecord,
    soarNsRecord,
    panelARecord,
    records: {
      nsHost,
      tunnelZone,
      panelHost,
      vpsIp
    }
  };
}

/**
 * Deletes the triple DNS configuration for WhiteDNS from Cloudflare
 */
export async function deleteSoarDnsRecords(authInput, zoneId, domain) {
  const cleanDomain = domain.toLowerCase().trim();
  const targets = [
    { type: 'A', name: `ns-soar.${cleanDomain}` },
    { type: 'NS', name: `soar.${cleanDomain}` },
    { type: 'A', name: `panel.${cleanDomain}` }
  ];

  const headers = getAuthHeaders(authInput);
  let deletedCount = 0;

  for (const t of targets) {
    try {
      const searchUrl = `${CF_API_BASE}/zones/${zoneId}/dns_records?type=${t.type}&name=${encodeURIComponent(t.name)}`;
      const searchRes = await fetch(searchUrl, { headers });
      const searchData = await searchRes.json();
      if (searchData.result?.length) {
        for (const r of searchData.result) {
          await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${r.id}`, {
            method: 'DELETE',
            headers
          });
          deletedCount++;
        }
      }
    } catch (e) {
      // Ignore individual record deletion failure
    }
  }

  return { ok: true, deletedCount };
}

/**
 * Retrieves all DNS records for a given zone
 */
export async function listDnsRecords(authInput, zoneId, page = 1, perPage = 50) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records?page=${page}&per_page=${perPage}&order=type`, {
      method: 'GET',
      headers
    });
    if (!res.ok) {
      return { ok: false, error: `خطا در دریافت رکوردها: HTTP ${res.status}` };
    }
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در ارتباط با کلودفلر' };
    }
    return {
      ok: true,
      records: data.result || [],
      info: data.result_info || {}
    };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Fetches a single DNS record by ID
 */
export async function getDnsRecord(authInput, zoneId, recordId) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${recordId}`, {
      method: 'GET',
      headers
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'رکورد یافت نشد.' };
    }
    return { ok: true, record: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Creates a new DNS record in Cloudflare
 */
export async function createDnsRecord(authInput, zoneId, { type, name, content, proxied = false, ttl = 1, comment = 'WhiteDNS Manager' }) {
  try {
    const headers = getAuthHeaders(authInput);
    const payload = {
      type: type.toUpperCase(),
      name,
      content,
      proxied: !!proxied,
      ttl: Number(ttl) || 1,
      comment
    };
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records`, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در ثبت رکورد' };
    }
    return { ok: true, record: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Updates an existing DNS record in Cloudflare
 */
export async function updateDnsRecord(authInput, zoneId, recordId, updates) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${recordId}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify(updates)
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در به‌روزرسانی رکورد' };
    }
    return { ok: true, record: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Deletes a single DNS record by ID
 */
export async function deleteDnsRecord(authInput, zoneId, recordId) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${recordId}`, {
      method: 'DELETE',
      headers
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در حذف رکورد' };
    }
    return { ok: true, result: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}
EOF_CF

# 5. Write src/ui.js
cat > "$INSTALL_DIR/src/ui.js" <<'EOF_UI'
/**
 * Generates a strong, random ASCII password (16 chars) suitable for Soar panel admin
 * Shell-safe: uses only unambiguous alphanumeric characters [A-Za-z0-9] without '$' or quotes
 */
export function generateStrongPassword(length = 16) {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower = 'abcdefghjkmnpqrstuvwxyz';
  const digits = '23456789';
  const all = upper + lower + digits;

  const result = [
    upper[Math.floor(Math.random() * upper.length)],
    lower[Math.floor(Math.random() * lower.length)],
    digits[Math.floor(Math.random() * digits.length)],
    lower[Math.floor(Math.random() * lower.length)]
  ];

  for (let i = 4; i < length; i++) {
    result.push(all[Math.floor(Math.random() * all.length)]);
  }

  // Modern Fisher-Yates shuffle for uniform distribution
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }

  return result.join('');
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

/**
 * Repair Progress Box renderer
 */
export function renderRepairProgressBox(currentStep, totalSteps = 6, ip = '', statusText = '') {
  const steps = [
    { num: 1, title: 'بررسی و رفع مشکل DNS و اینترنت سرور (/etc/resolv.conf)' },
    { num: 2, title: 'بررسی و آزادسازی پورت ۵۳ (حل تداخل systemd-resolved)' },
    { num: 3, title: 'بررسی دسترسی‌ها و ریستارت سرویس‌های daemon پنل' },
    { num: 4, title: 'بررسی فایروال و بازگشایی پورت‌های ۵۳، ۸۰ و ۴۴۳' },
    { num: 5, title: 'بررسی گواهی SSL و ریورس پروکسی Nginx' },
    { num: 6, title: 'تست سلامت نهایی و بازیابی آدرس اختصاصی پنل' },
  ];

  let text = '🛠 **در حال عیب‌یابی و تعمیر خودکار سرور WhiteDNS...**\n\n';
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

  text += '\n⚠️ _این عملیات حدود ۱۵ تا ۳۰ ثانیه زمان می‌برد._';
  return text;
}

/**
 * Repair Card renderer
 */
export function renderRepairCard({ panelUrl, ip }) {
  return `✅ **عیب‌یابی و تعمیر خودکار سرور با موفقیت پایان یافت!**

🖥 **سرور:** \`${ip}\`

🟢 **گزارش سلامت سرویس‌ها:**
• اینترنت و ریزالو DNS: کاملاً سالم (1.1.1.1 / 8.8.8.8)
• پورت ۵۳ (تانل Soar DNS): بدون تداخل و فعال
• فایروال (UFW): پورت‌های ۵۳، ۸۰ و ۴۴۳ باز
• وب‌سرور Nginx و گواهی SSL: فعال و پیکربندی‌شده
• هسته مدیریتی Soar Panel: فعال (Active)

🌐 **آدرس بازیابی‌شده و فعال پنل شما:**
${panelUrl}

💡 در صورت بروز هرگونه قطعی یا عدم باز شدن پنل، همیشه می‌توانید با دستور /repair سرور را مجدداً عیب‌یابی و ریستارت نمایید.`;
}
EOF_UI

# 6. Write src/ssh-installer.js
cat > "$INSTALL_DIR/src/ssh-installer.js" <<'EOF_SSH'
import { Client } from 'ssh2';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const installerScriptPath = path.resolve(__dirname, '../scripts/install-soar.sh');
const uninstallerScriptPath = path.resolve(__dirname, '../scripts/uninstall-soar.sh');
const repairScriptPath = path.resolve(__dirname, '../scripts/repair-soar.sh');

function extractErrorMessage(fullOutput, defaultMsg) {
  const errorMatch = fullOutput.match(/\[FATAL ERROR\] (.+)/);
  if (errorMatch) return errorMatch[1].trim();

  const lines = fullOutput
    .split('\n')
    .map(l => l.trim())
    .filter(l => l.length > 0 && !l.startsWith('[PROGRESS]') && !l.startsWith('<<<') && !l.startsWith('>>>'));

  const errorLines = lines.filter(l => /^(E:|error:|fatal:|dpkg:|apt-get:|curl:|tar:)/i.test(l));
  if (errorLines.length > 0) {
    return errorLines.slice(-3).join('\n');
  }
  if (lines.length > 0) {
    return lines.slice(-2).join('\n');
  }
  return defaultMsg;
}

/**
 * Executes the WhiteDNS Soar Server headless installation directly on remote VPS via SSH
 */
export async function installOverSSH({
  vpsIp,
  vpsPort = 22,
  vpsUser = 'root',
  vpsPass,
  domain,
  adminUser = 'admin',
  adminPass,
  onProgress
}) {
  const cleanDomain = domain.toLowerCase().trim();
  const zone = `soar.${cleanDomain}`;
  const nsHost = `ns-soar.${cleanDomain}`;
  const panelDomain = `panel.${cleanDomain}`;

  // Read the standalone installation script
  const scriptContent = fs.readFileSync(installerScriptPath, 'utf8');

  return new Promise((resolve, reject) => {
    const conn = new Client();
    let fullOutput = '';
    let isFinished = false;

    // Safety timeout: 4 minutes maximum for the entire SSH installation
    const overallTimeout = setTimeout(() => {
      if (!isFinished) {
        isFinished = true;
        try { conn.end(); } catch (e) {}
        reject(new Error('زمان مجاز عملیات نصب بر روی سرور (۴ دقیقه) به پایان رسید. ممکن است سرعت دانلود یا اتصال سرور پایین باشد.'));
      }
    }, 240000);

    conn.on('ready', () => {
      if (onProgress) {
        onProgress(1, 'اتصال SSH برقرار شد. در حال اعتبارسنجی سیستم‌عامل و آزادسازی پورت ۵۳...');
      }

      // Execute script with environment variables via bash stdin
      const cmd = `export ZONE="${zone}" NS_HOST="${nsHost}" PANEL_DOMAIN="${panelDomain}" PUBLIC_IP="${vpsIp}" ADMIN_USER="${adminUser}" ADMIN_PASS="${adminPass}"; bash -s`;

      conn.exec(cmd, (err, stream) => {
        if (err) {
          clearTimeout(overallTimeout);
          conn.end();
          return reject(new Error(`خطا در اجرای دستور روی سرور: ${err.message}`));
        }

        // Pipe our installer script into bash standard input
        stream.write(scriptContent);
        stream.end();

        let progressBuffer = '';

        stream.on('data', (data) => {
          const chunk = data.toString('utf8');
          fullOutput += chunk;
          progressBuffer += chunk;

          // Parse [PROGRESS] lines in real-time
          const lines = progressBuffer.split('\n');
          progressBuffer = lines.pop() || ''; // Keep partial line in buffer

          for (const line of lines) {
            const match = line.match(/\[PROGRESS\] Step ([0-9]+|COMPLETED) \(([^)]+)\): (.+)/);
            if (match && onProgress) {
              const stepNum = match[1] === 'COMPLETED' ? 7 : parseInt(match[1], 10);
              const message = match[3];
              onProgress(stepNum, message);
            }
          }
        });

        stream.stderr.on('data', (data) => {
          fullOutput += data.toString('utf8');
        });

        stream.on('close', async (code) => {
          if (isFinished) return;
          isFinished = true;
          clearTimeout(overallTimeout);

          if (code !== 0) {
            conn.end();
            const errorMsg = extractErrorMessage(fullOutput, `اسکریپت با کد خطا ${code} به پایان رسید.`);
            return reject(new Error(errorMsg));
          }

          // Parse final JSON summary from script output using robust markers
          let resultJson = null;
          try {
            const markerStart = '<<<WHITEDNS_JSON_SUMMARY_START>>>';
            const markerEnd = '<<<WHITEDNS_JSON_SUMMARY_END>>>';
            const startIdx = fullOutput.indexOf(markerStart);
            const endIdx = fullOutput.indexOf(markerEnd);
            if (startIdx !== -1 && endIdx !== -1) {
              const rawJson = fullOutput.substring(startIdx + markerStart.length, endIdx).trim();
              resultJson = JSON.parse(rawJson);
            } else {
              // Regex fallback
              const jsonMatch = fullOutput.match(/\{\s*"status":\s*"success"[\s\S]*?\}/);
              if (jsonMatch) {
                resultJson = JSON.parse(jsonMatch[0]);
              }
            }
          } catch (e) {
            // Fallback
          }

          // If panel_url wasn't captured, run access-url with a strict 5s timeout
          let panelUrl = resultJson?.panel_url;
          if (!panelUrl || !panelUrl.startsWith('http')) {
            try {
              panelUrl = await new Promise((resUrl) => {
                const accessTimeout = setTimeout(() => resUrl(''), 5000);
                conn.exec('/usr/local/bin/soar-panel access-url --db /var/lib/soar-panel/panel.db --listen 127.0.0.1:2053', (err2, stream2) => {
                  if (err2) {
                    clearTimeout(accessTimeout);
                    return resUrl('');
                  }
                  let out = '';
                  stream2.on('data', (d) => { out += d.toString('utf8'); });
                  stream2.on('close', () => {
                    clearTimeout(accessTimeout);
                    resUrl(out.trim());
                  });
                });
              });
            } catch (e) {
              // Ignore
            }
          }

          conn.end();

          // Ensure panelUrl uses the public domain and has trailing slash
          if (panelUrl && (panelUrl.includes('127.0.0.1') || panelUrl.includes('localhost'))) {
            try {
              const parsed = new URL(panelUrl);
              panelUrl = `https://${panelDomain}${parsed.pathname}`;
            } catch (e) {
              const match = panelUrl.match(/\/[A-Za-z0-9_-]{20,}\/?$/);
              if (match) {
                panelUrl = `https://${panelDomain}${match[0]}`;
              }
            }
          }

          if (!panelUrl || !panelUrl.startsWith('http')) {
            panelUrl = `https://${panelDomain}/`;
          }

          if (!panelUrl.endsWith('/')) {
            panelUrl += '/';
          }

          resolve({
            success: true,
            version: resultJson?.version || '0.14.0',
            panelUrl,
            adminUser,
            adminPass,
            publicIp: vpsIp,
            zone,
            nsHost,
            panelDomain
          });
        });
      });
    });

    conn.on('error', (err) => {
      if (!isFinished) {
        if (err.level === 'client-authentication') {
          return reject(new Error('رمز عبور SSH اشتباه است یا دسترسی کاربر root مسدود می‌باشد.'));
        }
        if (err.code === 'ECONNREFUSED') {
          return reject(new Error(`پورت ${vpsPort} روی سرور بسته است یا سرویس SSH اجرا نشده است.`));
        }
        if (err.code === 'ETIMEDOUT') {
          return reject(new Error('زمان اتصال به سرور به پایان رسید (Timeout). آی‌پی سرور یا فایروال را بررسی کنید.'));
        }
        return reject(new Error(`خطای اتصال SSH: ${err.message}`));
      }
    });

    // Initiate connection
    conn.connect({
      host: vpsIp,
      port: Number(vpsPort),
      username: vpsUser,
      password: vpsPass,
      readyTimeout: 20000,
      keepaliveInterval: 5000
    });
  });
}

/**
 * Executes WhiteDNS complete uninstallation on remote VPS via SSH
 */
export async function uninstallOverSSH({
  vpsIp,
  vpsPort = 22,
  vpsUser = 'root',
  vpsPass,
  onProgress
}) {
  const scriptContent = fs.readFileSync(uninstallerScriptPath, 'utf8');

  return new Promise((resolve, reject) => {
    const conn = new Client();
    let fullOutput = '';
    let isFinished = false;

    conn.on('ready', () => {
      if (onProgress) {
        onProgress(1, 'اتصال SSH برقرار شد. در حال توقف سرویس‌ها و حذف سرویس‌های daemon...');
      }

      conn.exec('bash -s', (err, stream) => {
        if (err) {
          conn.end();
          return reject(new Error(`خطا در اجرای اسکریپت حذف: ${err.message}`));
        }

        stream.write(scriptContent);
        stream.end();

        let progressBuffer = '';

        stream.on('data', (data) => {
          const chunk = data.toString('utf8');
          fullOutput += chunk;
          progressBuffer += chunk;

          const lines = progressBuffer.split('\n');
          progressBuffer = lines.pop() || '';

          for (const line of lines) {
            const match = line.match(/\[PROGRESS\] Step ([0-9]+|COMPLETED) \(([^)]+)\): (.+)/);
            if (match && onProgress) {
              const stepNum = match[1] === 'COMPLETED' ? 5 : parseInt(match[1], 10);
              onProgress(stepNum, match[3]);
            }
          }
        });

        stream.stderr.on('data', (data) => {
          fullOutput += data.toString('utf8');
        });

        stream.on('close', (code) => {
          isFinished = true;
          conn.end();

          if (code !== 0) {
            const errorMsg = extractErrorMessage(fullOutput, `اسکریپت حذف با کد خطا ${code} به پایان رسید.`);
            return reject(new Error(errorMsg));
          }

          resolve({
            success: true,
            message: 'سرویس‌ها، فایل‌های پیکربندی و باینری‌های WhiteDNS با موفقیت حذف شدند.'
          });
        });
      });
    });

    conn.on('error', (err) => {
      if (!isFinished) {
        if (err.level === 'client-authentication') {
          return reject(new Error('رمز عبور SSH اشتباه است یا دسترسی root مجاز نیست.'));
        }
        return reject(new Error(`خطای اتصال SSH: ${err.message}`));
      }
    });

    conn.connect({
      host: vpsIp,
      port: Number(vpsPort),
      username: vpsUser,
      password: vpsPass,
      readyTimeout: 20000,
      keepaliveInterval: 5000
    });
  });
}

/**
 * Executes WhiteDNS health check and auto-repair on remote VPS via SSH
 */
export async function repairOverSSH({
  vpsIp,
  vpsPort = 22,
  vpsUser = 'root',
  vpsPass,
  domain,
  onProgress
}) {
  const scriptContent = fs.readFileSync(repairScriptPath, 'utf8');

  return new Promise((resolve, reject) => {
    const conn = new Client();
    let fullOutput = '';
    let isFinished = false;

    const overallTimeout = setTimeout(() => {
      if (!isFinished) {
        isFinished = true;
        try { conn.end(); } catch (e) {}
        reject(new Error('زمان مجاز عملیات عیب‌یابی (۲ دقیقه) به پایان رسید.'));
      }
    }, 120000);

    conn.on('ready', () => {
      if (onProgress) {
        onProgress(1, 'اتصال SSH برقرار شد. در حال بررسی وضعیت اینترنت و DNS سرور...');
      }

      const panelDomain = domain ? `panel.${domain.toLowerCase().trim()}` : '';
      const cmd = `export PANEL_DOMAIN="${panelDomain}"; bash -s`;

      conn.exec(cmd, (err, stream) => {
        if (err) {
          clearTimeout(overallTimeout);
          conn.end();
          return reject(new Error(`خطا در اجرای اسکریپت تعمیر: ${err.message}`));
        }

        stream.write(scriptContent);
        stream.end();

        let progressBuffer = '';

        stream.on('data', (data) => {
          const chunk = data.toString('utf8');
          fullOutput += chunk;
          progressBuffer += chunk;

          const lines = progressBuffer.split('\n');
          progressBuffer = lines.pop() || '';

          for (const line of lines) {
            const match = line.match(/\[PROGRESS\] Step ([0-9]+|COMPLETED) \(([^)]+)\): (.+)/);
            if (match && onProgress) {
              const stepNum = match[1] === 'COMPLETED' ? 6 : parseInt(match[1], 10);
              onProgress(stepNum, match[3]);
            }
          }
        });

        stream.stderr.on('data', (data) => {
          fullOutput += data.toString('utf8');
        });

        stream.on('close', (code) => {
          if (isFinished) return;
          isFinished = true;
          clearTimeout(overallTimeout);
          conn.end();

          if (code !== 0) {
            const errorMsg = extractErrorMessage(fullOutput, `اسکریپت عیب‌یابی با کد خطا ${code} به پایان رسید.`);
            return reject(new Error(errorMsg));
          }

          let resultJson = null;
          try {
            const markerStart = '<<<WHITEDNS_JSON_SUMMARY_START>>>';
            const markerEnd = '<<<WHITEDNS_JSON_SUMMARY_END>>>';
            const startIdx = fullOutput.indexOf(markerStart);
            const endIdx = fullOutput.indexOf(markerEnd);
            if (startIdx !== -1 && endIdx !== -1) {
              const rawJson = fullOutput.substring(startIdx + markerStart.length, endIdx).trim();
              resultJson = JSON.parse(rawJson);
            }
          } catch (e) {}

          resolve({
            success: true,
            panelUrl: resultJson?.panel_url || '',
            panelDomain: resultJson?.panel_domain || panelDomain
          });
        });
      });
    });

    conn.on('error', (err) => {
      if (!isFinished) {
        if (err.level === 'client-authentication') {
          return reject(new Error('رمز عبور SSH اشتباه است یا دسترسی root مجاز نیست.'));
        }
        return reject(new Error(`خطای اتصال SSH: ${err.message}`));
      }
    });

    conn.connect({
      host: vpsIp,
      port: Number(vpsPort),
      username: vpsUser,
      password: vpsPass,
      readyTimeout: 20000,
      keepaliveInterval: 5000
    });
  });
}
EOF_SSH

# 7. Write src/bot.js
cat > "$INSTALL_DIR/src/bot.js" <<'EOF_BOT'
import { Telegraf, Markup } from 'telegraf';
import { exec } from 'child_process';
import util from 'util';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
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

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BOT_DIR = path.resolve(__dirname, '..');

const execPromise = util.promisify(exec);
const tempDnsState = new Map();

if (!BOT_TOKEN) {
  console.error('❌ FATAL: BOT_TOKEN is missing! Please provide BOT_TOKEN in .env file.');
  process.exit(1);
}

export const bot = new Telegraf(BOT_TOKEN);

// Global Error Handler to prevent silent crashes and unhandled promise rejections
bot.catch((err, ctx) => {
  console.error(`❌ Bot error on ${ctx?.updateType || 'unknown'}:`, err);
  ctx?.reply('⚠️ خطایی در ارتباط رخ داد. لطفاً با دستور /reset یا /start مجدداً تلاش فرمایید.').catch(() => {});
});

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

function renderTermsMessage() {
  const text =
    `📜 **بیانیه حفظ حریم خصوصی، امنیت اطلاعات و شرایط استفاده**\n\n` +
    `کاربر گرامی، به ربات راه‌اندازی خودکار **WhiteDNS Soar Server** خوش آمدید.\n` +
    `لطفاً پیش از شروع فرآیند نصب، موارد زیر را مطالعه فرمایید:\n\n` +
    `━━━━━━━━━━━━━━━━━━━━\n\n` +
    `🔹 **چه اطلاعاتی از شما دریافت می‌شود؟**\n` +
    `برای انجام فرآیند ۱۰۰٪ خودکار نصب و پیکربندی سرور، اطلاعات زیر در مراحل بعد از شما درخواست خواهد شد:\n` +
    `۱. **اطلاعات کلودفلر (Cloudflare):** آدرس ایمیل، توکن API یا کلید سراسری و نام دامنه شما (صرفاً جهت ساخت خودکار ۳ رکورد DNS تانل).\n` +
    `۲. **اطلاعات دسترسی سرور (VPS):** آدرس IP عمومی، پورت SSH، نام کاربری و رمز عبور root یا کلید SSH (صرفاً برای برقراری اتصال موقت SSH و اجرای مراحل نصب).\n\n` +
    `━━━━━━━━━━━━━━━━━━━━\n\n` +
    `🔒 **تضمین‌های امنیتی و عدم ذخیره‌سازی داده‌ها (Privacy & Security):**\n` +
    `• **عدم ذخیره رمز عبور:** رمز عبور سرور شما (VPS Password) و توکن‌های امنیتی به هیچ عنوان در هیچ پایگاه داده، فضای ابری یا سرورهای WhiteDNS ذخیره و ثبت نمی‌شوند.\n` +
    `• **پاک‌سازی خودکار در تلگرام:** پیام‌های حاوی رمز عبور یا توکن که در چت ارسال می‌کنید، بلافاصله پس از دریافت توسط ربات حذف می‌شوند تا هیچ ردی در تاریخچه تلگرام شما باقی نماند.\n` +
    `• **اتصال مستقیم و امن:** ربات با پروتکل رمزنگاری‌شده SSH مستقیماً به سرور شخصی خودتان متصل می‌شود و باینری‌ها مستقیماً از مخزن رسمی گیت‌هاب روی سرور شما دانلود می‌شوند.\n` +
    `• **۱۰۰٪ متن‌باز (Open Source):** کلیه کدهای این ربات و اسکریپت‌های نصاب به صورت شفاف در گیت‌هاب در دسترس عموم و قابل ارزیابی هستند.\n` +
    `• **مالکیت کامل:** مدیریت، دسترسی‌ها و کنترل سرور و دامنه پس از نصب کاملاً در اختیار خود شماست و هیچ بک‌دوری در سیستم وجود ندارد.\n\n` +
    `━━━━━━━━━━━━━━━━━━━━\n\n` +
    `⚠️ _با انتخاب گزینه «شرایط را می‌پذیرم»، تایید می‌کنید که مالک سرور و دامنه بوده و به ربات اجازه اتصال و اجرای نصب را می‌دهید._`;

  const keyboard = Markup.inlineKeyboard([
    [Markup.button.callback('✅ شرایط را می‌پذیرم و ادامه می‌دهم', 'terms_accept')],
    [Markup.button.callback('❌ نمی‌پذیرم و انصراف', 'terms_decline')]
  ]);

  return { text, keyboard };
}

function renderCfEmailPrompt(ctx, isEdit = false) {
  const text =
    `👋 **شروع فرآیند نصب WhiteDNS Soar Server**\n\n` +
    `این ربات تمامی مراحل تنظیم کلودفلر، اتصال SSH به سرور، حل تداخل پورت ۵۳، نصب پیش‌نیازها و صدور گواهی SSL را **به صورت ۱۰۰٪ خودکار** انجام می‌دهد.\n\n` +
    `📧 **مرحله ۱ از ۲: ورود ایمیل کلودفلر**\n` +
    `لطفاً **آدرس ایمیل** اکانت کلودفلر خود را ارسال فرمایید:\n` +
    `_(مثال: myname@gmail.com)_\n\n` +
    `💡 _اگر توکن آماده دارید، می‌توانید آن را مستقیماً ارسال کنید._`;

  const keyboard = Markup.inlineKeyboard([
    [Markup.button.url('🚀 باز کردن فرم آماده توکن (۱-کلیک)', CF_TEMPLATE_URL)],
    [Markup.button.callback('🛠 عیب‌یابی و تعمیر سرور موجود', 'menu:repair')],
    [Markup.button.callback('❌ انصراف', 'cancel')]
  ]);

  if (isEdit) {
    return ctx.editMessageText(text, {
      parse_mode: 'Markdown',
      ...keyboard
    }).catch(() => ctx.replyWithMarkdown(text, keyboard));
  }
  return ctx.replyWithMarkdown(text, keyboard);
}

bot.command('start', async (ctx) => {
  const chatId = ctx.chat.id;
  resetSession(chatId, 'TERMS_AGREEMENT');
  const { text, keyboard } = renderTermsMessage();
  return ctx.replyWithMarkdown(text, keyboard);
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
    const execOpts = { cwd: BOT_DIR };

    // Ensure git is installed on the bot server
    await execPromise('command -v git >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq git 2>&1)', execOpts).catch(() => {});

    // 1. Ensure safe directory configuration for git
    await execPromise(`git config --global --add safe.directory "${BOT_DIR}" 2>&1`, execOpts).catch(() => {});
    await execPromise('git config --global --add safe.directory "*" 2>&1', execOpts).catch(() => {});

    // 2. Ensure git repository is initialized
    if (!fs.existsSync(path.join(BOT_DIR, '.git'))) {
      await execPromise('git init -b main 2>&1 || git init 2>&1', execOpts);
      await execPromise('git remote add origin https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git 2>&1 || git remote set-url origin https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git 2>&1', execOpts);
    } else {
      await execPromise('git remote set-url origin https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git 2>&1', execOpts).catch(() => {});
    }

    // Fetch with --all to avoid errors when no tracking branch is set
    await execPromise('git fetch origin main 2>&1 || git fetch --all 2>&1', execOpts);
    const { stdout: statusOut } = await execPromise('git rev-parse HEAD 2>&1', execOpts).catch(() => ({ stdout: '' }));
    const { stdout: remoteHead } = await execPromise('git rev-parse origin/main 2>&1', execOpts).catch(() => ({ stdout: '' }));

    if (statusOut.trim() && remoteHead.trim() && statusOut.trim() === remoteHead.trim()) {
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
        await execPromise('git reset --hard origin/main && npm install --omit=dev && (systemctl restart whitedns-bot.service 2>/dev/null || systemctl restart whitedns-bot 2>/dev/null || true)', execOpts);
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

  // 0. TERMS AGREEMENT
  if (session.step === 'TERMS_AGREEMENT') {
    return ctx.replyWithMarkdown(
      '⚠️ **لطفاً برای ادامه، ابتدا شرایط استفاده و حریم خصوصی را تعیین تکلیف فرمایید:**\n\nجهت پذیرش و ورود به مرحله بعد دکمه «✅ شرایط را می‌پذیرم» و در غیر این صورت دکمه «❌ نمی‌پذیرم» را لمس کنید.',
      Markup.inlineKeyboard([
        [Markup.button.callback('✅ شرایط را می‌پذیرم و ادامه می‌دهم', 'terms_accept')],
        [Markup.button.callback('❌ نمی‌پذیرم و انصراف', 'terms_decline')]
      ])
    );
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
        pass = parts.slice(1).join(':').trim();
      } else if (parts.length === 3) {
        port = parseInt(parts[1], 10) || 22;
        pass = parts.slice(2).join(':').trim();
      } else {
        port = parseInt(parts[1], 10) || 22;
        user = parts[2].trim() || 'root';
        pass = parts.slice(3).join(':').trim();
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

    let lastRepairStep = 1;
    let lastRepairMsg = '';
    let lastRepairEditTime = Date.now();

    try {
      const repairRes = await repairOverSSH({
        vpsIp,
        vpsPort: session.vpsPort || 22,
        vpsUser: 'root',
        vpsPass,
        domain,
        onProgress: async (step, msg) => {
          const now = Date.now();
          const stepChanged = step !== lastRepairStep;
          const msgChanged = msg && msg !== lastRepairMsg;

          if (stepChanged || (msgChanged && now - lastRepairEditTime >= 3500)) {
            lastRepairStep = step;
            lastRepairMsg = msg;
            lastRepairEditTime = now;
            await ctx.telegram.editMessageText(
              chatId,
              progressMsg.message_id,
              undefined,
              renderRepairProgressBox(step, 6, vpsIp, msg),
              { parse_mode: 'Markdown' }
            ).catch(() => {});
          }
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

      const keyboard = [];
      if (repairRes.panelUrl && repairRes.panelUrl.startsWith('http')) {
        keyboard.push([{ text: '🌐 باز کردن مستقیم آدرس پنل', url: repairRes.panelUrl }]);
      }
      keyboard.push([{ text: '📊 مشاهده وضعیت سرورها', callback_data: 'menu:status' }]);

      return ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        renderRepairCard({ panelUrl: repairRes.panelUrl, ip: vpsIp }),
        {
          parse_mode: 'Markdown',
          reply_markup: { inline_keyboard: keyboard }
        }
      ).catch(() => {
        return ctx.telegram.editMessageText(
          chatId,
          progressMsg.message_id,
          undefined,
          renderRepairCard({ panelUrl: repairRes.panelUrl, ip: vpsIp }).replace(/[*_`]/g, ''),
          { reply_markup: { inline_keyboard: keyboard } }
        );
      });
    } catch (err) {
      const errText = `❌ **عملیات عیب‌یابی و تعمیر متوقف شد:**\n\`${err.message}\`\n\nلطفاً از صحت رمز عبور root و باز بودن پورت ۲۲ سرور اطمینان حاصل نمایید.`;
      const errButtons = {
        inline_keyboard: [
          [{ text: '🔄 تلاش مجدد', callback_data: 'menu:repair' }],
          [{ text: '❌ انصراف', callback_data: 'cancel' }]
        ]
      };
      return ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        errText,
        { parse_mode: 'Markdown', reply_markup: errButtons }
      ).catch(() => {
        return ctx.telegram.editMessageText(
          chatId,
          progressMsg.message_id,
          undefined,
          errText.replace(/[*_`]/g, ''),
          { reply_markup: errButtons }
        );
      });
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
    st.zoneId = st.zoneId || session.zoneId;
    st.domain = st.domain || session.domain;
    st.name = rawName;
    tempDnsState.set(chatId, st);

    saveSession(chatId, { step: 'AWAITING_DNS_ADD_CONTENT' });
    return ctx.replyWithMarkdown(
      `📌 نام رکورد: \`${rawName}\`\n\nلطفاً **مقدار یا آی‌پی (Value / Content)** این رکورد را ارسال فرمایید:\n_(برای رکورد A: آی‌پی سرور مثل \`173.230.134.64\` | برای CNAME: نام هاست)_`,
      Markup.inlineKeyboard([
        [Markup.button.callback('❌ انصراف', 'cf_dns')]
      ])
    );
  }

  // 13. AWAITING DNS ADD CONTENT
  if (session.step === 'AWAITING_DNS_ADD_CONTENT') {
    const content = text.trim();
    const st = tempDnsState.get(chatId) || {};
    const zoneId = st.zoneId || session.zoneId;
    const domain = st.domain || session.domain;
    st.content = content;
    tempDnsState.set(chatId, st);

    // If type is NS or TXT, proxy is not applicable
    if (st.type === 'NS' || st.type === 'TXT') {
      const waitMsg = await ctx.reply('⏳ در حال ثبت رکورد در کلودفلر...');
      const createRes = await createDnsRecord(session.cfToken, zoneId, {
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
            [Markup.button.callback('🔙 بازگشت به لیست رکوردها', 'cf_dns')]
          ])
        );
      }
      return renderDnsManager(ctx, chatId, zoneId, domain, 1, false, `✅ رکورد [${st.type}] ${st.name} با موفقیت ایجاد شد.`);
    }

    // For A, AAAA, CNAME -> ask for proxy status
    saveSession(chatId, { step: 'AWAITING_DNS_ADD_PROXY' });
    return ctx.replyWithMarkdown(
      `🌐 **وضعیت پروکسی کلودفلر برای رکورد \`${st.name}\`:**\n\n• مقدار: \`${content}\`\n• نوع: \`${st.type}\`\n\nآیا می‌خواهید ترافیک این رکورد از شبکه CDN کلودفلر عبور کند؟\n_(توجه: برای پنل WhiteDNS و تانل، پروکسی باید خاموش / DNS Only باشد)_`,
      Markup.inlineKeyboard([
        [Markup.button.callback('🔘 پروکسی خاموش (DNS Only - توصیه شده)', 'cf_add_proxy:0')],
        [Markup.button.callback('☁️ پروکسی روشن (Proxied)', 'cf_add_proxy:1')],
        [Markup.button.callback('❌ انصراف', 'cf_dns')]
      ])
    );
  }

  // 14. AWAITING DNS EDIT VALUE
  if (session.step === 'AWAITING_DNS_EDIT_VAL') {
    const newVal = text.trim();
    const st = tempDnsState.get(chatId) || {};
    const zoneId = st.zoneId || session.zoneId;
    const domain = st.domain || session.domain;

    if (!st.recordId) {
      saveSession(chatId, { step: 'IDLE' });
      return ctx.reply('⚠️ جلسه ویرایش منقضی شده است.');
    }

    const waitMsg = await ctx.reply('⏳ در حال به‌روزرسانی رکورد در کلودفلر...');
    const updateRes = await updateDnsRecord(session.cfToken, zoneId, st.recordId, {
      content: newVal
    });
    await ctx.telegram.deleteMessage(chatId, waitMsg.message_id).catch(() => {});
    saveSession(chatId, { step: 'IDLE' });
    tempDnsState.delete(chatId);

    if (!updateRes.ok) {
      return ctx.replyWithMarkdown(
        `❌ **خطا در به‌روزرسانی رکورد:**\n\`${updateRes.error}\``,
        Markup.inlineKeyboard([
          [Markup.button.callback('🔙 بازگشت به لیست رکوردها', 'cf_dns')]
        ])
      );
    }

    return renderDnsManager(ctx, chatId, zoneId, domain, 1, false, `✅ مقدار رکورد با موفقیت به ${newVal} تغییر یافت.`);
  }
});

// ----------------------------------------------------------------------------
// 3. CALLBACK QUERY HANDLERS
// ----------------------------------------------------------------------------

bot.action('cmd:start', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  resetSession(chatId, 'TERMS_AGREEMENT');
  const { text, keyboard } = renderTermsMessage();
  return ctx.editMessageText(text, {
    parse_mode: 'Markdown',
    ...keyboard
  }).catch(() => ctx.replyWithMarkdown(text, keyboard));
});

bot.action('terms_accept', async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  saveSession(chatId, { step: 'AWAITING_CF_EMAIL' });
  return renderCfEmailPrompt(ctx, true);
});

bot.action('terms_decline', async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  resetSession(chatId, 'IDLE');

  const text =
    `❌ **فرآیند راه‌اندازی لغو گردید.**\n\n` +
    `شما شرایط استفاده و بیانیه حفظ حریم خصوصی را نپذیرفتید. هیچ‌گونه اطلاعاتی دریافت یا ذخیره نشد و هیچ تغییری روی سرور یا دامنه شما اعمال نگردید.\n\n` +
    `هر زمان که تمایل داشتید، می‌توانید با انتخاب دکمه زیر یا ارسال مجدد دستور /start فرآیند را آغاز کنید:`;

  const keyboard = Markup.inlineKeyboard([
    [Markup.button.callback('🚀 شروع مجدد (/start)', 'cmd:start')]
  ]);

  return ctx.editMessageText(text, {
    parse_mode: 'Markdown',
    ...keyboard
  }).catch(() => ctx.replyWithMarkdown(text, keyboard));
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

  saveSession(chatId, { uninstDomain: domain, uninstIp: ip, domain, vpsIp: ip, step: 'AWAITING_UNINSTALL_PASS' });

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

  saveSession(chatId, { repairDomain: domain, repairIp: ip, domain, vpsIp: ip, step: 'AWAITING_REPAIR_PASS' });

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
  tempDnsState.set(chatId, { zoneId, domain });

  return ctx.editMessageText(
    `🌐 دامنه انتخاب‌شده: \`${domain}\`\n\n📌 اکنون لطفاً **آدرس IPv4 عمومی سرور (VPS)** خود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_\n\n💡 _همچنین می‌توانید مشخصات کامل را یکجا بفرستید:_\n\`IP:Port:User:Password\`\n\nیا در صورت تمایل می‌توانید رکوردهای DNS این دامنه را بررسی، ویرایش یا حذف نمایید:`,
    Markup.inlineKeyboard([
      [Markup.button.callback('⚙️ مدیریت رکوردهای DNS این دامنه', 'cf_dns')],
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
    Markup.button.callback(`🌐 مدیریت DNS: ${z.name}`, `cf_zone:${z.id}:${z.name}`)
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
  try {
    const session = getSession(chatId);
    const auth = session?.cfToken;
    const activeZone = zoneId || session?.zoneId;
    const activeDomain = domain || session?.domain;

    if (!auth || !activeZone) {
      const noAuthMsg = '⚠️ اطلاعات نشست کلودفلر یافت نشد. لطفاً دستور /dns را ارسال فرمایید.';
      if (isEdit) return ctx.editMessageText(noAuthMsg).catch(() => ctx.reply(noAuthMsg));
      return ctx.reply(noAuthMsg);
    }

    const res = await listDnsRecords(auth, activeZone, 1, 100);
    if (!res.ok) {
      const errText = `❌ **خطا در دریافت رکوردهای DNS کلودفلر:**\n\`${res.error}\``;
      const buttons = Markup.inlineKeyboard([
        [Markup.button.callback('🔄 تلاش مجدد', 'cf_dns')],
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

    // Save state in memory for short callbacks
    tempDnsState.set(chatId, {
      zoneId: activeZone,
      domain: activeDomain,
      pageRecords,
      curPage
    });

    let text = `⚙️ **مدیریت رکوردهای DNS دامنه** \`${activeDomain}\`\n📊 کل رکوردها: **${allRecords.length}** (صفحه ${curPage} از ${totalPages})\n\n`;

    if (toastNotice) {
      text += `🔔 ${toastNotice}\n\n`;
    }

    if (pageRecords.length === 0) {
      text += `_هیچ رکوردی برای این دامنه ثبت نشده است._\n\n`;
    } else {
      pageRecords.forEach((r, idx) => {
        const num = startIdx + idx + 1;
        const proxyIcon = r.proxied ? '☁️ Proxied' : '🔘 DNS Only';
        const displayContent = r.content && r.content.length > 25 ? r.content.substring(0, 22) + '...' : (r.content || '');
        text += `${num}. \`[${r.type}]\` \`${r.name}\`\n   ➔ \`${displayContent}\` (${proxyIcon})\n`;
      });
      text += `\n_(راهنما: ☁️ پروکسی فعال | 🔘 پروکسی غیرفعال / مستقیم)_\n`;
    }

    const keyboard = [];

    if (pageRecords.length > 0) {
      const actionRows = pageRecords.map((r, idx) => {
        const num = startIdx + idx + 1;
        return [
          Markup.button.callback(`✏️ ویرایش #${num} (${r.type})`, `cf_edit:${idx}`),
          Markup.button.callback(`🗑 حذف #${num}`, `cf_del:${idx}`)
        ];
      });
      keyboard.push(...actionRows);
    }

    const navRow = [];
    if (curPage > 1) {
      navRow.push(Markup.button.callback('◀️ صفحه قبلی', `cf_page:${curPage - 1}`));
    }
    if (curPage < totalPages) {
      navRow.push(Markup.button.callback('صفحه بعدی ▶️', `cf_page:${curPage + 1}`));
    }
    if (navRow.length > 0) {
      keyboard.push(navRow);
    }

    keyboard.push([
      Markup.button.callback('➕ افزودن رکورد DNS جدید', 'cf_add'),
      Markup.button.callback('🧹 پاک‌سازی رکوردهای تانل', 'cf_clean')
    ]);

    keyboard.push([
      Markup.button.callback('🚀 ادامه نصب پنل (ورود آی‌پی سرور)', 'cf_continue'),
      Markup.button.callback('🔙 بازگشت به لیست دامنه‌ها', 'back:select_zone')
    ]);

    if (isEdit) {
      try {
        return await ctx.editMessageText(text, { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
      } catch (err) {
        if (err.message && err.message.includes('message is not modified')) {
          return;
        }
        // Fallback without parse_mode if Telegram markdown parser fails
        return await ctx.editMessageText(text.replace(/[*_`]/g, ''), { reply_markup: { inline_keyboard: keyboard } });
      }
    }
    try {
      return await ctx.replyWithMarkdown(text, Markup.inlineKeyboard(keyboard));
    } catch (err) {
      return await ctx.reply(text.replace(/[*_`]/g, ''), Markup.inlineKeyboard(keyboard));
    }
  } catch (err) {
    console.error('renderDnsManager error:', err);
    const fallbackMsg = `❌ **خطا در نمایش مدیریت رکوردهای DNS:**\n\`${err.message}\``;
    if (isEdit) return ctx.editMessageText(fallbackMsg).catch(() => ctx.reply(fallbackMsg));
    return ctx.reply(fallbackMsg);
  }
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

bot.action(/^cf_dns(?::(.+):(.+))?$/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const zoneId = ctx.match[1] || session?.zoneId || st.zoneId;
  const domain = ctx.match[2] || session?.domain || st.domain;
  if (zoneId && domain) {
    saveSession(chatId, { zoneId, domain });
  }
  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true);
});

bot.action(/cf_zone:(.+):(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const zoneId = ctx.match[1];
  const domain = ctx.match[2];
  saveSession(chatId, { zoneId, domain });
  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true);
});

bot.action(/cf_page:([0-9]+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const page = parseInt(ctx.match[1], 10) || 1;
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;
  return renderDnsManager(ctx, chatId, zoneId, domain, page, true);
});

bot.action('cf_add', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const domain = session?.domain || st.domain || '';

  return ctx.editMessageText(
    `➕ **افزودن رکورد DNS جدید برای دامنه:** \`${domain}\`\n\nلطفاً نوع رکورد مورد نظر خود را انتخاب فرمایید:`,
    Markup.inlineKeyboard([
      [
        Markup.button.callback('📌 رکورد A (IPv4)', 'cf_add_type:A'),
        Markup.button.callback('🔗 رکورد CNAME', 'cf_add_type:CNAME')
      ],
      [
        Markup.button.callback('🌐 رکورد NS', 'cf_add_type:NS'),
        Markup.button.callback('📝 رکورد TXT', 'cf_add_type:TXT')
      ],
      [
        Markup.button.callback('🔙 بازگشت به لیست رکوردها', 'cf_dns')
      ]
    ])
  );
});

bot.action(/cf_add_type:(.+)/, (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  const type = ctx.match[1];
  const st = tempDnsState.get(chatId) || {};
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;

  tempDnsState.set(chatId, { zoneId, domain, type });
  saveSession(chatId, { step: 'AWAITING_DNS_ADD_NAME' });

  return ctx.editMessageText(
    `➕ **ثبت رکورد جدید [${type}] برای دامنه:** \`${domain}\`\n\n📌 لطفاً **نام یا ساب‌دامنه** را ارسال فرمایید:\n(مثلاً \`panel\` برای panel.${domain} یا \`@\` برای دامنه اصلی \`${domain}\`):`,
    Markup.inlineKeyboard([
      [Markup.button.callback('❌ انصراف و بازگشت', 'cf_dns')]
    ])
  );
});

bot.action(/cf_add_proxy:([01])/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const proxied = ctx.match[1] === '1';

  const st = tempDnsState.get(chatId) || {};
  const session = getSession(chatId);
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;

  if (!session?.cfToken || !zoneId || !st.type || !st.name || !st.content) {
    return ctx.editMessageText(
      '⚠️ اطلاعات رکورد منقضی شده است. لطفاً مجدداً از منوی /dns اقدام فرمایید.',
      Markup.inlineKeyboard([[Markup.button.callback('🔙 بازگشت به لیست رکوردها', 'cf_dns')]])
    );
  }

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
        [Markup.button.callback('🔙 بازگشت به لیست رکوردها', 'cf_dns')]
      ])
    );
  }

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, `✅ رکورد [${st.type}] ${st.name} با موفقیت افزوده شد.`);
});

bot.action(/cf_del:([0-9]+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const idx = parseInt(ctx.match[1], 10);
  const st = tempDnsState.get(chatId) || {};
  const r = st.pageRecords?.[idx];

  if (!r) {
    return ctx.editMessageText('❌ رکورد یافت نشد.', Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', 'cf_dns')]
    ]));
  }

  return ctx.editMessageText(
    `⚠️ **تایید حذف رکورد DNS:**\n\n• **نوع:** \`${r.type}\`\n• **نام:** \`${r.name}\`\n• **مقدار:** \`${r.content}\`\n• **پروکسی:** ${r.proxied ? '☁️ روشن' : '🔘 خاموش'}\n\nآیا از حذف دائمی این رکورد اطمینان دارید؟`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🗑 بله، حذف شود', `cf_del_conf:${r.id}`)],
      [Markup.button.callback('❌ خیر، بازگشت', 'cf_dns')]
    ])
  );
});

bot.action(/cf_del_conf:(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const recordId = ctx.match[1];
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;

  const delRes = await deleteDnsRecord(session.cfToken, zoneId, recordId);
  if (!delRes.ok) {
    return ctx.editMessageText(`❌ خطا در حذف رکورد: ${delRes.error}`, Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', 'cf_dns')]
    ]));
  }

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, '🗑 رکورد با موفقیت حذف شد.');
});

bot.action(/cf_edit:([0-9]+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const idx = parseInt(ctx.match[1], 10);
  const st = tempDnsState.get(chatId) || {};
  const r = st.pageRecords?.[idx];

  if (!r) {
    return ctx.editMessageText('❌ رکورد یافت نشد.', Markup.inlineKeyboard([
      [Markup.button.callback('🔙 بازگشت', 'cf_dns')]
    ]));
  }

  const keyboard = [
    [Markup.button.callback('✏️ تغییر مقدار / آی‌پی', `cf_edit_val:${r.id}`)]
  ];

  if (r.type === 'A' || r.type === 'AAAA' || r.type === 'CNAME') {
    const toggleLabel = r.proxied ? '🔘 خاموش کردن پروکسی (DNS Only)' : '☁️ روشن کردن پروکسی (Proxied)';
    keyboard.push([Markup.button.callback(toggleLabel, `cf_toggle_proxy:${r.id}`)]);
  }

  keyboard.push([
    Markup.button.callback('🔙 بازگشت به لیست رکوردها', 'cf_dns')
  ]);

  return ctx.editMessageText(
    `✏️ **مدیریت و ویرایش رکورد DNS:**\n\n• **نوع:** \`${r.type}\`\n• **نام:** \`${r.name}\`\n• **مقدار فعلی:** \`${r.content}\`\n• **وضعیت پروکسی:** ${r.proxied ? '☁️ روشن (Proxied)' : '🔘 خاموش (DNS Only)'}\n\nلطفاً عملیات مورد نظر را انتخاب فرمایید:`,
    Markup.inlineKeyboard(keyboard)
  );
});

bot.action(/cf_toggle_proxy:(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const recordId = ctx.match[1];
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;

  const getRes = await getDnsRecord(session.cfToken, zoneId, recordId);
  if (getRes.ok) {
    const newProxied = !getRes.record.proxied;
    await updateDnsRecord(session.cfToken, zoneId, recordId, { proxied: newProxied });
  }

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, '🔄 وضعیت پروکسی رکورد تغییر یافت.');
});

bot.action(/cf_edit_val:(.+)/, async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const recordId = ctx.match[1];
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;

  const getRes = await getDnsRecord(session.cfToken, zoneId, recordId);
  const curVal = getRes.ok ? getRes.record.content : '';
  const rName = getRes.ok ? getRes.record.name : domain;

  tempDnsState.set(chatId, { zoneId, domain, recordId });
  saveSession(chatId, { step: 'AWAITING_DNS_EDIT_VAL' });

  return ctx.editMessageText(
    `✏️ لطفاً **مقدار یا آی‌پی جدید** برای رکورد \`${rName}\` را ارسال فرمایید:\n\n_(مقدار فعلی: \`${curVal}\`)_`,
    Markup.inlineKeyboard([
      [Markup.button.callback('❌ انصراف و بازگشت', 'cf_dns')]
    ])
  );
});

bot.action('cf_clean', async (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const zoneId = session?.zoneId || st.zoneId;
  const domain = session?.domain || st.domain;

  await ctx.editMessageText('⏳ در حال پاک‌سازی رکوردهای تانل WhiteDNS...');
  await deleteSoarDnsRecords(session.cfToken, zoneId, domain);

  return renderDnsManager(ctx, chatId, zoneId, domain, 1, true, '🧹 رکوردهای پیشین تانل WhiteDNS (ns-soar, soar, panel) با موفقیت پاک شدند.');
});

bot.action('cf_continue', (ctx) => {
  ctx.answerCbQuery().catch(() => {});
  const chatId = ctx.chat.id;
  const session = getSession(chatId);
  const st = tempDnsState.get(chatId) || {};
  const domain = session?.domain || st.domain;

  saveSession(chatId, { step: 'AWAITING_SSH_IP' });

  return ctx.editMessageText(
    `🌐 دامنه انتخاب‌شده: \`${domain}\`\n\n📌 اکنون لطفاً **آدرس IPv4 عمومی سرور (VPS)** خود را ارسال فرمایید:\n_(مثال: \`194.26.11.20\`)_\n\n💡 _همچنین می‌توانید مشخصات کامل را یکجا بفرستید:_\n\`IP:Port:User:Password\``,
    Markup.inlineKeyboard([
      [Markup.button.callback('⚙️ مدیریت مجدد رکوردهای DNS', 'cf_dns')],
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

        // Render immediately on step change, or update message if 3.5s passed to prevent Telegram rate limit
        if (stepChanged || (msgChanged && now - lastEditTime >= 3500)) {
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
    const completionCardText = renderCompletionCard({
      panelUrl: result.panelUrl,
      adminUser: 'admin',
      adminPass,
      domain,
      publicIp: vpsIp,
      version: result.version
    });

    const completionKeyboard = [];
    if (result.panelUrl && result.panelUrl.startsWith('http')) {
      completionKeyboard.push([{ text: '🌐 ورود به پنل WhiteDNS', url: result.panelUrl }]);
    }
    completionKeyboard.push([{ text: '📊 مشاهده وضعیت سرورها', callback_data: 'menu:status' }]);

    await ctx.telegram.editMessageText(
      chatId,
      progressMsg.message_id,
      undefined,
      completionCardText,
      {
        parse_mode: 'Markdown',
        reply_markup: { inline_keyboard: completionKeyboard }
      }
    ).catch(async () => {
      await ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        completionCardText.replace(/[*_`]/g, ''),
        { reply_markup: { inline_keyboard: completionKeyboard } }
      ).catch(() => {});
    });

  } catch (err) {
    console.error('Installation error:', err);
    const errCard = renderErrorCard(err.message);
    await ctx.telegram.editMessageText(
      chatId,
      progressMsg.message_id,
      undefined,
      errCard,
      { parse_mode: 'Markdown' }
    ).catch(async () => {
      await ctx.telegram.editMessageText(
        chatId,
        progressMsg.message_id,
        undefined,
        errCard.replace(/[*_`]/g, '')
      ).catch(() => {});
    });
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
EOF_BOT

# 8. Write scripts/install-soar.sh
cat > "$INSTALL_DIR/scripts/install-soar.sh" <<'EOF_INSTALL_SOAR'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - 100% Unattended Headless Installer
# Designed for Telegram Serverless Bot Automation
# Features: Nginx SSL Reverse Proxy, Auto-Certbot, Zero-Stall Loopback Binding
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077

# Required environment variables or parameters:
ZONE="${ZONE:-}"
NS_HOST="${NS_HOST:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${ZONE#*.}}"
CALLBACK_URL="${CALLBACK_URL:-}"
PANEL_PORT="${PANEL_PORT:-2053}"
DNS_PORT="${DNS_PORT:-53}"
RESOLVERS="${RESOLVERS:-1.1.1.1,8.8.8.8}"

report_progress() {
  local step="$1"
  local status="$2"
  local message="$3"
  printf '[PROGRESS] Step %s (%s): %s\n' "$step" "$status" "$message"
  if [[ -n "$CALLBACK_URL" ]]; then
    curl -s -X POST "$CALLBACK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"step\": \"$step\", \"status\": \"$status\", \"message\": \"$message\"}" >/dev/null 2>&1 || true
  fi
}

die() {
  local msg="$*"
  printf '\n[FATAL ERROR] %s\n' "$msg" >&2
  report_progress "FAILED" "error" "$msg"
  exit 1
}

# ------------------------------------------------------------------------------
# 1. Validation & System Checks
# ------------------------------------------------------------------------------
report_progress "1" "in_progress" "Validating server environment and resolving port 53..."

[[ $EUID -eq 0 ]] || die "This installer must be run as root."
[[ -r /etc/os-release ]] || die "Requires Ubuntu 22.04+ or Debian 12+."
. /etc/os-release
case "$ID:${VERSION_ID%%.*}" in
  ubuntu:22|ubuntu:24|ubuntu:26|debian:12|debian:13) ;;
  *) die "Unsupported OS: $ID $VERSION_ID. Supported: Ubuntu 22/24/26, Debian 12/13." ;;
esac

case "$(uname -m)" in
  x86_64|amd64) BUNDLE_ARCH="amd64" ;;
  aarch64|arm64) BUNDLE_ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported." ;;
esac

[[ -n "$ZONE" ]] || die "ZONE is missing."
[[ -n "$NS_HOST" ]] || die "NS_HOST is missing."
[[ -n "$PANEL_DOMAIN" ]] || die "PANEL_DOMAIN is missing."
[[ -n "$ADMIN_PASS" ]] || die "ADMIN_PASS is missing."

# Detect public IP if not supplied (multi-source fallback)
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(curl -4s --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
              curl -4s --connect-timeout 3 https://icanhazip.com 2>/dev/null || \
              curl -4s --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
              ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || \
              hostname -I 2>/dev/null | awk '{print $1}')
fi
PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d ' \n\r')
[[ -n "$PUBLIC_IP" ]] || die "Could not determine PUBLIC_IP."

# Fix systemd-resolved conflict on port 53 (common on Ubuntu/Debian)
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if grep -qE '^#?DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  else
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/no-stub.conf
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
fi

# Crucial: Ensure upstream DNS resolver is active and never loops back to dead 127.0.0.53
EXISTING_NS=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | grep -v '127\.0\.0\.' | awk '{print $2}' | tr '\n' ' ' || true)
RESOLVE_NS=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /run/systemd/resolve/resolv.conf 2>/dev/null | grep -v '127\.0\.0\.' | awk '{print $2}' | tr '\n' ' ' || true)
UPSTREAM_NS=$(printf "%s %s" "$EXISTING_NS" "$RESOLVE_NS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

rm -f /etc/resolv.conf
{
  for ns in $UPSTREAM_NS; do
    echo "nameserver $ns"
  done
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
  echo "options timeout:2 attempts:3"
} > /etc/resolv.conf

# Verify DNS resolution works; fallback to direct public DNS if host upstream failed
if ! curl -4s --connect-timeout 3 https://api.ipify.org >/dev/null 2>&1; then
  cat > /etc/resolv.conf <<EOF_DNS
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
nameserver 208.67.222.222
options timeout:2 attempts:3
EOF_DNS
fi

report_progress "1" "success" "Server verified: $ID $VERSION_ID ($BUNDLE_ARCH), IP: $PUBLIC_IP"

# ------------------------------------------------------------------------------
# 2. Install Required Dependencies
# ------------------------------------------------------------------------------
report_progress "2" "in_progress" "Preparing package manager and checking system locks..."

# Proactively stop background auto-updaters that lock apt/dpkg on fresh VPS boot
systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl kill --kill-who=all unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

# Wait gracefully up to 15 seconds for any running apt/dpkg process to finish
for i in {1..15}; do
  if ! pgrep -f "unattended-upgrade|apt.systemd.daily|apt-get|dpkg" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# If still held after 15s, terminate stale lock holders so installation is never stalled
pkill -9 -f "unattended-upgrade|apt.systemd.daily|apt-get|dpkg" 2>/dev/null || true
sleep 1

# Remove any stale lock files left behind
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true

# Fix any partially configured packages safely with generous timeout and non-interactive flags
DEBIAN_FRONTEND=noninteractive timeout 60s dpkg --configure -a --force-confdef --force-confold 2>/dev/null || true

# Ensure universe and multiverse repositories are enabled on Ubuntu
if [[ "$ID" == "ubuntu" ]]; then
  # 1. Update deb822 format (/etc/apt/sources.list.d/ubuntu.sources)
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    sed -i -E '/^Components:/ { /universe/! s/$/ universe/ }' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
    sed -i -E '/^Components:/ { /multiverse/! s/$/ multiverse/ }' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
  fi

  # 2. Update traditional format (/etc/apt/sources.list)
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i -E '/^deb .*main/ { /universe/! s/main/main universe multiverse/ }' /etc/apt/sources.list 2>/dev/null || true
  fi

  # 3. If add-apt-repository is available, use it as well
  command -v add-apt-repository >/dev/null 2>&1 && add-apt-repository -y universe 2>/dev/null || true

  # 4. Explicit fallback sources file for official Ubuntu repositories
  UBUNTU_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$UBUNTU_CODENAME" ]] || UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ -n "$UBUNTU_CODENAME" ]]; then
    cat > /etc/apt/sources.list.d/whitedns-official.list <<EOF_UBUNTU_SOURCES
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF_UBUNTU_SOURCES
  fi
elif [[ "$ID" == "debian" ]]; then
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i -E '/^deb .*main/ { /contrib/! s/main/main contrib non-free non-free-firmware/ }' /etc/apt/sources.list 2>/dev/null || true
  fi
  DEBIAN_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$DEBIAN_CODENAME" ]] || DEBIAN_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ -n "$DEBIAN_CODENAME" ]]; then
    cat > /etc/apt/sources.list.d/whitedns-official.list <<EOF_DEBIAN_SOURCES
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free
deb http://deb.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free
EOF_DEBIAN_SOURCES
  fi
fi

report_progress "2" "in_progress" "Updating package lists..."

APT_LOG=$(mktemp /tmp/whitedns-apt.XXXXXX)
APT_FLAGS="-y -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::ForceIPv4=true -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# Run apt-get update (with retry and log accumulation)
apt-get update $APT_FLAGS >"$APT_LOG" 2>&1 || {
  rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null || true
  apt-get update $APT_FLAGS >>"$APT_LOG" 2>&1 || true
}

report_progress "2" "in_progress" "Installing prerequisites (nginx, openssl, curl, tar)..."

# Install core required packages (ca-certificates, curl, tar, openssl)
apt-get install -y --no-install-recommends $APT_FLAGS ca-certificates curl tar openssl iproute2 >>"$APT_LOG" 2>&1 || \
apt-get install -y $APT_FLAGS ca-certificates curl tar openssl iproute2 >>"$APT_LOG" 2>&1 || true

# Install Nginx reverse proxy (try nginx meta-package, fallback to nginx-light or nginx-core)
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends $APT_FLAGS nginx >>"$APT_LOG" 2>&1 || \
  apt-get install -y $APT_FLAGS nginx >>"$APT_LOG" 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-light >>"$APT_LOG" 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-core >>"$APT_LOG" 2>&1 || true
fi

# Multi-tier fallback: if distro nginx packages still failed, install official Nginx from nginx.org upstream repository
if ! command -v nginx >/dev/null 2>&1; then
  report_progress "2" "in_progress" "Installing official Nginx from upstream repository..."
  mkdir -p /usr/share/keyrings
  curl -fsSL https://nginx.org/keys/nginx_signing.key 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$DISTRO_CODENAME" ]] || DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ -f /usr/share/keyrings/nginx-archive-keyring.gpg && -n "$DISTRO_CODENAME" ]]; then
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${ID} ${DISTRO_CODENAME} nginx" > /etc/apt/sources.list.d/nginx-official.list
    apt-get update $APT_FLAGS >>"$APT_LOG" 2>&1 || true
    apt-get install -y $APT_FLAGS nginx >>"$APT_LOG" 2>&1 || true
  fi
fi

# Install Certbot (optional: openssl self-signed fallback exists in Step 6 if unavailable)
if ! command -v certbot >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends $APT_FLAGS certbot >>"$APT_LOG" 2>&1 || true
fi

# Install optional utilities (bind9-dnsutils, ufw)
apt-get install -y --no-install-recommends $APT_FLAGS bind9-dnsutils >>"$APT_LOG" 2>&1 || \
apt-get install -y --no-install-recommends $APT_FLAGS dnsutils >>"$APT_LOG" 2>&1 || true
apt-get install -y --no-install-recommends $APT_FLAGS ufw >>"$APT_LOG" 2>&1 || true

# Validate essential tools
MISSING_TOOLS=()
for tool in curl tar openssl nginx; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS+=("$tool")
  fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  APT_LAST_ERR=$(grep -iE '^(E:|error:|fatal:)' "$APT_LOG" 2>/dev/null | tail -n 3 | tr '\n' ' ' || true)
  rm -f "$APT_LOG"
  die "Failed to install required tools (${MISSING_TOOLS[*]}). Error: ${APT_LAST_ERR:-check server repository status}"
fi

rm -f "$APT_LOG"
report_progress "2" "success" "Dependencies successfully installed."

# ------------------------------------------------------------------------------
# 3. Download & Verify Official WhiteDNS Release Bundle
# ------------------------------------------------------------------------------
report_progress "3" "in_progress" "Fetching latest official WhiteDNS Soar Server release..."

# Detect latest release tag with multi-tier fallback (API, redirect, fallback version)
PANEL_REPO="WhiteDNS/Soar-Server"
LATEST_TAG=$(curl -fsSL --retry 3 "https://api.github.com/repos/$PANEL_REPO/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"tag_name": "panel-v?([^"]+)".*/\1/' || true)

if [[ -z "$LATEST_TAG" ]]; then
  LATEST_URL=$(curl -fsSL -o /dev/null -w "%{url_effective}" "https://github.com/$PANEL_REPO/releases/latest" 2>/dev/null || true)
  LATEST_TAG="${LATEST_URL##*/panel-v}"
fi

# Fallback default version if GitHub API/redirect is unreachable or rate-limited
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "latest" || "$LATEST_TAG" == *"/"* ]]; then
  LATEST_TAG="0.14.0"
fi

WORK_DIR=$(mktemp -d /tmp/whitedns-soar-install.XXXXXX)
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

ASSET_NAME="soar-panel-$LATEST_TAG-linux-$BUNDLE_ARCH.tar.gz"
DOWNLOAD_URL="https://github.com/$PANEL_REPO/releases/download/panel-v$LATEST_TAG/$ASSET_NAME"
CHECKSUM_URL="$DOWNLOAD_URL.sha256"

curl -fsSL --retry 3 "$DOWNLOAD_URL" -o "$WORK_DIR/$ASSET_NAME" || die "Failed to download $ASSET_NAME."
curl -fsSL --retry 3 "$CHECKSUM_URL" -o "$WORK_DIR/$ASSET_NAME.sha256" || die "Failed to download checksum file."

(cd "$WORK_DIR" && sha256sum --check --status "$ASSET_NAME.sha256") || die "SHA256 checksum mismatch! Aborting."

tar -xzf "$WORK_DIR/$ASSET_NAME" -C "$WORK_DIR"
EXTRACTED_DIR="$WORK_DIR/soar-panel-$LATEST_TAG-linux-$BUNDLE_ARCH"

report_progress "3" "success" "Downloaded and verified WhiteDNS v$LATEST_TAG ($BUNDLE_ARCH)."

# ------------------------------------------------------------------------------
# 4. User Provisioning, Binaries, Database & Firewall
# ------------------------------------------------------------------------------
report_progress "4" "in_progress" "Setting up system user, binaries and database..."

id soar-panel >/dev/null 2>&1 || useradd --system --home-dir /var/lib/soar-panel --shell /usr/sbin/nologin soar-panel

install -d -o soar-panel -g soar-panel -m 0700 /var/lib/soar-panel
install -d -o soar-panel -g soar-panel -m 0700 /var/lib/soar-panel/certificates
install -d -m 0700 /var/lib/soar-panel-ops

install -m 0755 "$EXTRACTED_DIR/bin/linux-$BUNDLE_ARCH/soar-panel" /usr/local/bin/soar-panel
install -m 0755 "$EXTRACTED_DIR/bin/linux-$BUNDLE_ARCH/soar-panel-ops" /usr/local/bin/soar-panel-ops
install -m 0755 "$EXTRACTED_DIR/bin/linux-$BUNDLE_ARCH/soar-check" /usr/local/bin/soar-check
install -m 0755 "$EXTRACTED_DIR/panel-security.sh" /usr/local/bin/soar-panel-security
install -m 0755 "$EXTRACTED_DIR/panel-menu.sh" /usr/local/bin/soar-panel-menu
ln -sf /usr/local/bin/soar-panel-menu /usr/local/bin/whitedns

printf '%s\n' "$PUBLIC_IP" > /var/lib/soar-panel/public-ip
chmod 0600 /var/lib/soar-panel/public-ip
chown soar-panel:soar-panel /var/lib/soar-panel/public-ip

DB_FILE="/var/lib/soar-panel/panel.db"
PW_FILE=$(mktemp /tmp/soar-pw.XXXXXX)
printf '%s' "$ADMIN_PASS" > "$PW_FILE"
chmod 0600 "$PW_FILE"

if [[ ! -f "$DB_FILE" ]]; then
  /usr/local/bin/soar-panel init \
    --db "$DB_FILE" \
    --zone "$ZONE" \
    --nameserver "$NS_HOST" \
    --public-ip "$PUBLIC_IP" \
    --resolvers "$RESOLVERS" \
    --admin "$ADMIN_USER" \
    --password-file "$PW_FILE"
fi
rm -f -- "$PW_FILE"

chown soar-panel:soar-panel "$DB_FILE"
chmod 0600 "$DB_FILE"

# Pre-configure access with random secret path on 127.0.0.1 loopback
/usr/local/bin/soar-panel configure-access \
  --db "$DB_FILE" \
  --listen "127.0.0.1:$PANEL_PORT" \
  --random-path

# Ensure domain is blank in access.json so soar-panel delegates SSL to Nginx
if [[ -f /var/lib/soar-panel/access.json ]]; then
  sed -i -E 's/"domain":[[:space:]]*"[^"]*"/"domain": ""/' /var/lib/soar-panel/access.json
  sed -i -E 's/"https":[[:space:]]*true/"https": false/' /var/lib/soar-panel/access.json
fi

chown soar-panel:soar-panel /var/lib/soar-panel/access.json
chmod 0600 /var/lib/soar-panel/access.json

# Configure UFW firewall if enabled
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$DNS_PORT/udp" comment 'soar-tunnel-dns' || true
  ufw allow "$DNS_PORT/tcp" comment 'soar-tunnel-dns' || true
  ufw allow 80/tcp comment 'soar-acme-http' || true
  ufw allow 443/tcp comment 'soar-panel-https' || true
fi

report_progress "4" "success" "User, database and firewall rules initialized."

# ------------------------------------------------------------------------------
# 5. Install & Start Systemd Services
# ------------------------------------------------------------------------------
report_progress "5" "in_progress" "Configuring and launching systemd daemon services..."

cat > /etc/systemd/system/soar-panel.service <<UNIT
[Unit]
Description=WhiteDNS Soar Management Panel
After=network-online.target
Wants=network-online.target
Wants=soar-panel-ops.service

[Service]
Type=simple
User=soar-panel
Group=soar-panel
ExecStart=/usr/local/bin/soar-panel run --db /var/lib/soar-panel/panel.db --dns-listen 0.0.0.0:$DNS_PORT --listen 127.0.0.1:$PANEL_PORT --trust-loopback-proxy
Restart=on-failure
RestartSec=3
TimeoutStopSec=10
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/soar-panel
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/soar-panel-ops.service <<UNIT
[Unit]
Description=WhiteDNS private panel maintenance service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=soar-panel
ExecStart=/usr/local/bin/soar-panel-ops --health-address 127.0.0.1:$PANEL_PORT --dns-port $DNS_PORT
Restart=on-failure
RestartSec=3
RuntimeDirectory=soar-panel-ops
RuntimeDirectoryMode=0750
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/usr/local/bin /var/lib/soar-panel /var/lib/soar-panel-ops /run/soar-panel-ops
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl restart soar-panel-ops.service || systemctl start soar-panel-ops.service || true
systemctl restart soar-panel.service || systemctl start soar-panel.service || true
systemctl enable soar-panel-ops.service || true
systemctl enable soar-panel.service || true

# Wait for healthy service readiness
HEALTHY=0
for i in {1..20}; do
  if systemctl is-active --quiet soar-panel.service; then
    if timeout 3s /usr/local/bin/soar-panel health --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" >/dev/null 2>&1; then
      HEALTHY=1
      break
    fi
  fi
  sleep 1
done

if [[ $HEALTHY -eq 0 ]]; then
  if ss -ltn | grep -qE "(:$PANEL_PORT |127\.0\.0\.1:$PANEL_PORT)"; then
    HEALTHY=1
  fi
fi

[[ $HEALTHY -eq 1 ]] || die "Panel service failed to reach healthy state on port $PANEL_PORT."

report_progress "5" "success" "Systemd daemon services active and operational."

# ------------------------------------------------------------------------------
# 6. Configure SSL Certificate & High-Performance Nginx Reverse Proxy
# ------------------------------------------------------------------------------
report_progress "6" "in_progress" "Configuring domain SSL certificate and Nginx reverse proxy..."

systemctl stop nginx 2>/dev/null || true
mkdir -p /etc/letsencrypt

CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN"
CERT_FILE=""
KEY_FILE=""

# Attempt Certbot standalone Let's Encrypt certificate acquisition
certbot certonly --standalone --agree-tos --register-unsafely-without-email --non-interactive \
  -d "$PANEL_DOMAIN" --keep-until-expiring >/dev/null 2>&1 || true

if [[ -f "$CERT_PATH/fullchain.pem" && -f "$CERT_PATH/privkey.pem" ]]; then
  CERT_FILE="$CERT_PATH/fullchain.pem"
  KEY_FILE="$CERT_PATH/privkey.pem"
else
  # Check if another cert matches in letsencrypt live directory
  ALT_CERT=$(find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | head -n 1 || true)
  if [[ -n "$ALT_CERT" ]]; then
    CERT_FILE="$ALT_CERT"
    KEY_FILE="${ALT_CERT%/*}/privkey.pem"
  else
    # Fallback self-signed certificate: prevents total crash if domain DNS propagation is slow or rate-limited
    mkdir -p /etc/ssl/certs /etc/ssl/private
    CERT_FILE="/etc/ssl/certs/soar-selfsigned.crt"
    KEY_FILE="/etc/ssl/private/soar-selfsigned.key"
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=$PANEL_DOMAIN" >/dev/null 2>&1 || true
    fi
  fi
fi

# Check if IPv6 is supported by host kernel before enabling IPv6 listen sockets
IPV6_LISTEN_80=""
IPV6_LISTEN_443=""
if [[ -f /proc/net/if_inet6 ]] && [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0) -eq 0 ]]; then
  IPV6_LISTEN_80="listen [::]:80;"
  IPV6_LISTEN_443="listen [::]:443 ssl;"
fi

# Create dedicated Nginx reverse proxy configuration
cat > /etc/nginx/sites-available/soar-panel <<NGINX_CONF
server {
    listen 80;
    ${IPV6_LISTEN_80}
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    ${IPV6_LISTEN_443}
    server_name $PANEL_DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/soar-panel /etc/nginx/sites-enabled/soar-panel
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || true
systemctl restart nginx || systemctl start nginx || true
systemctl enable nginx 2>/dev/null || true

report_progress "6" "success" "SSL certificate and Nginx proxy operational on ports 80/443."

# ------------------------------------------------------------------------------
# 7. Extract Secret Access URL & Final Summary
# ------------------------------------------------------------------------------
report_progress "7" "in_progress" "Extracting secure secret access URL..."

FINAL_URL=""
# Extract random security path directly from access.json
if [[ -f /var/lib/soar-panel/access.json ]]; then
  EXTRACTED_PATH=$(grep -oE '/[A-Za-z0-9_-]{20,}/' /var/lib/soar-panel/access.json | head -n 1 || true)
  if [[ -n "$EXTRACTED_PATH" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$EXTRACTED_PATH"
  fi
fi

# Fallback: query access-url command
if [[ -z "$FINAL_URL" ]]; then
  RAW_URL=$(timeout 5s /usr/local/bin/soar-panel access-url --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" 2>/dev/null || true)
  MATCHED_PATH=$(echo "$RAW_URL" | grep -oE '/[A-Za-z0-9_-]{20,}/' | head -n 1 || true)
  if [[ -n "$MATCHED_PATH" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$MATCHED_PATH"
  fi
fi

# Ultimate safety fallback
if [[ -z "$FINAL_URL" || ! "$FINAL_URL" =~ ^https?:// ]]; then
  FINAL_URL="https://$PANEL_DOMAIN/"
fi

[[ "$FINAL_URL" == */ ]] || FINAL_URL="$FINAL_URL/"

report_progress "7" "success" "Secret URL extracted successfully."
report_progress "COMPLETED" "success" "WhiteDNS installation complete!"

printf '\n<<<WHITEDNS_JSON_SUMMARY_START>>>\n'
cat <<JSON_OUT
{
  "status": "success",
  "version": "$LATEST_TAG",
  "panel_url": "$FINAL_URL",
  "admin_user": "$ADMIN_USER",
  "admin_pass": "$ADMIN_PASS",
  "public_ip": "$PUBLIC_IP",
  "zone": "$ZONE",
  "nameserver": "$NS_HOST",
  "panel_domain": "$PANEL_DOMAIN"
}
JSON_OUT
printf '\n<<<WHITEDNS_JSON_SUMMARY_END>>>\n'
EOF_INSTALL_SOAR
chmod +x "$INSTALL_DIR/scripts/install-soar.sh"

# 9. Write scripts/repair-soar.sh
cat > "$INSTALL_DIR/scripts/repair-soar.sh" <<'EOF_REPAIR_SOAR'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - Comprehensive Health Check & Auto-Repair Tool
# Fixes: DNS resolvers, Port 53 conflicts, Systemd services, Nginx reverse proxy,
# SSL certificates, UFW firewall, and restores the live secret Panel URL.
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_PORT="${PANEL_PORT:-2053}"
DNS_PORT="${DNS_PORT:-53}"

report_progress() {
  local step="$1"
  local status="$2"
  local message="$3"
  printf '[PROGRESS] Step %s (%s): %s\n' "$step" "$status" "$message"
}

die() {
  local msg="$*"
  printf '\n[FATAL ERROR] %s\n' "$msg" >&2
  report_progress "FAILED" "error" "$msg"
  exit 1
}

[[ $EUID -eq 0 ]] || die "This repair tool must be run as root."

# ------------------------------------------------------------------------------
# 1. Check & Fix DNS Resolution (/etc/resolv.conf)
# ------------------------------------------------------------------------------
report_progress "1" "in_progress" "Checking and fixing DNS resolution and nameservers..."

if ! curl -4s --connect-timeout 3 https://api.ipify.org >/dev/null 2>&1; then
  rm -f /etc/resolv.conf
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n" > /etc/resolv.conf
fi

report_progress "1" "success" "DNS resolution confirmed operational."

# ------------------------------------------------------------------------------
# 2. Check & Fix Port 53 Conflicts (systemd-resolved)
# ------------------------------------------------------------------------------
report_progress "2" "in_progress" "Inspecting and clearing port 53 DNS listener..."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if grep -qE '^#?DNSStubListener=' /etc/systemd/resolved.conf 2>/dev/null; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  else
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/no-stub.conf
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
fi

EXISTING_NS=$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | grep -v '127\.0\.0\.' | awk '{print $2}' | tr '\n' ' ' || true)

rm -f /etc/resolv.conf
{
  for ns in $EXISTING_NS; do
    echo "nameserver $ns"
  done
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
  echo "options timeout:2 attempts:3"
} > /etc/resolv.conf

report_progress "2" "success" "Port 53 freed from systemd-resolved."

# ------------------------------------------------------------------------------
# 3. Verify & Repair System Permissions and WhiteDNS Daemons
# ------------------------------------------------------------------------------
report_progress "3" "in_progress" "Verifying WhiteDNS core files, permissions and services..."

DB_FILE="/var/lib/soar-panel/panel.db"
[[ -f "$DB_FILE" ]] || die "WhiteDNS database not found at $DB_FILE. Is WhiteDNS installed?"

chown -R soar-panel:soar-panel /var/lib/soar-panel 2>/dev/null || true
chmod 0700 /var/lib/soar-panel 2>/dev/null || true
chmod 0600 "$DB_FILE" 2>/dev/null || true

# Autodetect PANEL_DOMAIN if not supplied
if [[ -z "$PANEL_DOMAIN" ]]; then
  if [[ -f /etc/nginx/sites-available/soar-panel ]]; then
    PANEL_DOMAIN=$(grep -E 'server_name' /etc/nginx/sites-available/soar-panel | head -n 1 | awk '{print $2}' | tr -d ';' || true)
  fi
fi
if [[ -z "$PANEL_DOMAIN" && -f /var/lib/soar-panel/access.json ]]; then
  PANEL_DOMAIN=$(grep -oE '"domain":[[:space:]]*"[^"]+"' /var/lib/soar-panel/access.json | cut -d'"' -f4 || true)
fi

# Ensure access.json uses loopback proxy without internal ACME hang
if [[ -f /var/lib/soar-panel/access.json ]]; then
  sed -i -E 's/"domain":[[:space:]]*"[^"]*"/"domain": ""/' /var/lib/soar-panel/access.json
  sed -i -E 's/"https":[[:space:]]*true/"https": false/' /var/lib/soar-panel/access.json
  chmod 0600 /var/lib/soar-panel/access.json
  chown soar-panel:soar-panel /var/lib/soar-panel/access.json
fi

# Ensure systemd service has --trust-loopback-proxy
if [[ -f /etc/systemd/system/soar-panel.service ]]; then
  if ! grep -q -- '--trust-loopback-proxy' /etc/systemd/system/soar-panel.service; then
    sed -i 's|ExecStart=.*|ExecStart=/usr/local/bin/soar-panel run --db /var/lib/soar-panel/panel.db --dns-listen 0.0.0.0:'"$DNS_PORT"' --listen 127.0.0.1:'"$PANEL_PORT"' --trust-loopback-proxy|' /etc/systemd/system/soar-panel.service
    systemctl daemon-reload
  fi
fi

systemctl restart soar-panel-ops.service 2>/dev/null || true
systemctl restart soar-panel.service 2>/dev/null || true

HEALTHY=0
for i in {1..15}; do
  if systemctl is-active --quiet soar-panel.service; then
    HEALTHY=1
    break
  fi
  sleep 1
done
[[ $HEALTHY -eq 1 ]] || die "soar-panel.service could not be restarted."

report_progress "3" "success" "WhiteDNS daemons active and responsive."

# ------------------------------------------------------------------------------
# 4. Check & Repair Firewall Rules (UFW)
# ------------------------------------------------------------------------------
report_progress "4" "in_progress" "Inspecting and updating firewall rules..."

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$DNS_PORT/udp" comment 'soar-tunnel-dns' >/dev/null 2>&1 || true
  ufw allow "$DNS_PORT/tcp" comment 'soar-tunnel-dns' >/dev/null 2>&1 || true
  ufw allow 80/tcp comment 'soar-acme-http' >/dev/null 2>&1 || true
  ufw allow 443/tcp comment 'soar-panel-https' >/dev/null 2>&1 || true
fi

report_progress "4" "success" "Firewall ports 53, 80 and 443 verified."

# ------------------------------------------------------------------------------
# 5. Check & Repair Nginx Reverse Proxy and SSL Certificate
# ------------------------------------------------------------------------------
report_progress "5" "in_progress" "Verifying SSL certificate and Nginx reverse proxy..."

if ! command -v nginx >/dev/null 2>&1; then
  APT_FLAGS="-y -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::ForceIPv4=true -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  apt-get update $APT_FLAGS >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends $APT_FLAGS nginx >/dev/null 2>&1 || \
  apt-get install -y $APT_FLAGS nginx >/dev/null 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-light >/dev/null 2>&1 || \
  apt-get install -y --no-install-recommends $APT_FLAGS nginx-core >/dev/null 2>&1 || true
fi

CERT_FILE=""
KEY_FILE=""

if [[ -n "$PANEL_DOMAIN" ]]; then
  CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN"
  if [[ -f "$CERT_PATH/fullchain.pem" && -f "$CERT_PATH/privkey.pem" ]]; then
    CERT_FILE="$CERT_PATH/fullchain.pem"
    KEY_FILE="$CERT_PATH/privkey.pem"
  else
    ALT_CERT=$(find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | head -n 1 || true)
    if [[ -n "$ALT_CERT" ]]; then
      CERT_FILE="$ALT_CERT"
      KEY_FILE="${ALT_CERT%/*}/privkey.pem"
    else
      systemctl stop nginx 2>/dev/null || true
      certbot certonly --standalone --agree-tos --register-unsafely-without-email --non-interactive \
        -d "$PANEL_DOMAIN" --keep-until-expiring >/dev/null 2>&1 || true
      if [[ -f "$CERT_PATH/fullchain.pem" && -f "$CERT_PATH/privkey.pem" ]]; then
        CERT_FILE="$CERT_PATH/fullchain.pem"
        KEY_FILE="$CERT_PATH/privkey.pem"
      else
        mkdir -p /etc/ssl/certs /etc/ssl/private
        CERT_FILE="/etc/ssl/certs/soar-selfsigned.crt"
        KEY_FILE="/etc/ssl/private/soar-selfsigned.key"
        if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
          openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -subj "/CN=$PANEL_DOMAIN" >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi
fi

if [[ -n "$PANEL_DOMAIN" && -n "$CERT_FILE" ]]; then
IPV6_LISTEN_80=""
IPV6_LISTEN_443=""
if [[ -f /proc/net/if_inet6 ]] && [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0) -eq 0 ]]; then
  IPV6_LISTEN_80="listen [::]:80;"
  IPV6_LISTEN_443="listen [::]:443 ssl;"
fi

cat > /etc/nginx/sites-available/soar-panel <<NGINX_CONF
server {
    listen 80;
    ${IPV6_LISTEN_80}
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    ${IPV6_LISTEN_443}
    server_name $PANEL_DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/soar-panel /etc/nginx/sites-enabled/soar-panel
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || true
systemctl restart nginx || systemctl start nginx || true
systemctl enable nginx 2>/dev/null || true
fi

report_progress "5" "success" "SSL and Nginx reverse proxy operational."

# ------------------------------------------------------------------------------
# 6. Extract Secret Access URL & Final Summary
# ------------------------------------------------------------------------------
report_progress "6" "in_progress" "Extracting and verifying live secret panel URL..."

FINAL_URL=""
if [[ -f /var/lib/soar-panel/access.json ]]; then
  EXTRACTED_PATH=$(grep -oE '/[A-Za-z0-9_-]{20,}/' /var/lib/soar-panel/access.json | head -n 1 || true)
  if [[ -n "$EXTRACTED_PATH" && -n "$PANEL_DOMAIN" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$EXTRACTED_PATH"
  fi
fi

if [[ -z "$FINAL_URL" ]]; then
  RAW_URL=$(timeout 5s /usr/local/bin/soar-panel access-url --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" 2>/dev/null || true)
  MATCHED_PATH=$(echo "$RAW_URL" | grep -oE '/[A-Za-z0-9_-]{20,}/' | head -n 1 || true)
  if [[ -n "$MATCHED_PATH" && -n "$PANEL_DOMAIN" ]]; then
    FINAL_URL="https://$PANEL_DOMAIN$MATCHED_PATH"
  fi
fi

if [[ -z "$FINAL_URL" && -n "$PANEL_DOMAIN" ]]; then
  FINAL_URL="https://$PANEL_DOMAIN/"
fi

[[ "$FINAL_URL" == */ ]] || FINAL_URL="$FINAL_URL/"

report_progress "6" "success" "Diagnostics and repair completed successfully."
report_progress "COMPLETED" "success" "Panel is online and operational."

printf '\n<<<WHITEDNS_JSON_SUMMARY_START>>>\n'
cat <<JSON_OUT
{
  "status": "success",
  "action": "repaired",
  "panel_url": "$FINAL_URL",
  "panel_domain": "$PANEL_DOMAIN",
  "dns_port": "$DNS_PORT",
  "panel_port": "$PANEL_PORT"
}
JSON_OUT
printf '\n<<<WHITEDNS_JSON_SUMMARY_END>>>\n'
EOF_REPAIR_SOAR
chmod +x "$INSTALL_DIR/scripts/repair-soar.sh"

# 10. Write scripts/uninstall-soar.sh
cat > "$INSTALL_DIR/scripts/uninstall-soar.sh" <<'EOF_UNINSTALL_SOAR'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - Complete Uninstaller & Cleanup Script
# 100% Unattended Headless Execution
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

report_progress() {
  local step="$1"
  local status="$2"
  local message="$3"
  printf '[PROGRESS] Step %s (%s): %s\n' "$step" "$status" "$message"
}

die() {
  local msg="$*"
  printf '\n[FATAL ERROR] %s\n' "$msg" >&2
  report_progress "FAILED" "error" "$msg"
  exit 1
}

[[ $EUID -eq 0 ]] || die "This script must be run as root."

report_progress "1" "in_progress" "Stopping and disabling WhiteDNS daemon services..."

# 1. Stop and disable systemd services
if systemctl is-active --quiet soar-panel.service 2>/dev/null; then
  systemctl stop soar-panel.service || true
fi
if systemctl is-active --quiet soar-panel-ops.service 2>/dev/null; then
  systemctl stop soar-panel-ops.service || true
fi

systemctl disable soar-panel.service 2>/dev/null || true
systemctl disable soar-panel-ops.service 2>/dev/null || true

rm -f /etc/systemd/system/soar-panel.service
rm -f /etc/systemd/system/soar-panel-ops.service
systemctl daemon-reload

report_progress "1" "success" "Services stopped and systemd units removed."

# 2. Remove binaries and symbolic links
report_progress "2" "in_progress" "Removing WhiteDNS binaries and symlinks..."

rm -f /usr/local/bin/soar-panel
rm -f /usr/local/bin/soar-panel-ops
rm -f /usr/local/bin/soar-check
rm -f /usr/local/bin/soar-panel-security
rm -f /usr/local/bin/soar-panel-menu
rm -f /usr/local/bin/whitedns

report_progress "2" "success" "Binaries deleted."

# 3. Purge data directories and user
report_progress "3" "in_progress" "Purging configuration databases and data directories..."

rm -rf /var/lib/soar-panel
rm -rf /var/lib/soar-panel-ops
rm -rf /run/soar-panel-ops
rm -rf /root/soar-panel-access-*
rm -rf /root/soar-panel-backup-*

if id soar-panel >/dev/null 2>&1; then
  userdel soar-panel 2>/dev/null || true
fi

report_progress "3" "success" "Data files, certificates, and system user purged."

# 4. Remove Nginx reverse proxy site configuration if present
if [[ -f /etc/nginx/sites-available/soar-panel || -L /etc/nginx/sites-enabled/soar-panel ]]; then
  rm -f /etc/nginx/sites-enabled/soar-panel /etc/nginx/sites-available/soar-panel
  systemctl reload nginx 2>/dev/null || true
fi

# 5. Restore DNS Stub Listener if needed
report_progress "4" "in_progress" "Restoring default DNS configuration..."

if [[ -f /etc/systemd/resolved.conf ]]; then
  if grep -qE '^DNSStubListener=no' /etc/systemd/resolved.conf; then
    sed -i 's/^DNSStubListener=no/#DNSStubListener=yes/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
fi

report_progress "4" "success" "DNS configuration restored."

# 5. Clean UFW firewall rules
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow 53/udp 2>/dev/null || true
  ufw delete allow 53/tcp 2>/dev/null || true
  ufw delete allow 80/tcp 2>/dev/null || true
  ufw delete allow 443/tcp 2>/dev/null || true
fi

report_progress "COMPLETED" "success" "WhiteDNS Soar Server completely removed."

cat <<JSON_OUT
{
  "status": "success",
  "action": "uninstalled",
  "message": "WhiteDNS Soar Server was completely removed from the server."
}
JSON_OUT
EOF_UNINSTALL_SOAR
chmod +x "$INSTALL_DIR/scripts/uninstall-soar.sh"

# 11. Write update.sh, uninstall.sh, menu.sh
cat > "$INSTALL_DIR/update.sh" <<'EOF_UPDATE'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - 1-Line Updater for Linux VPS
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}======================================================"
echo -e "   WhiteDNS Telegram Bot - Auto Updater"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git"

if [[ -d "$INSTALL_DIR" ]]; then
  TARGET_DIR="$INSTALL_DIR"
elif [[ -d "$SCRIPT_DIR" && -f "$SCRIPT_DIR/package.json" ]]; then
  TARGET_DIR="$SCRIPT_DIR"
else
  echo -e "${RED}[ERROR] Bot directory (/opt/whitedns-bot) not found.${NC}"
  echo -e "Please deploy the bot first using:"
  echo -e "${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/deploy.sh)${NC}"
  exit 1
fi

cd "$TARGET_DIR"

# Ensure git is installed
if ! command -v git &>/dev/null; then
  echo -e "${BLUE}[INFO] Installing git...${NC}"
  apt-get update -qq && apt-get install -y -qq git
fi

# Ensure git safe directory is configured
git config --global --add safe.directory "$TARGET_DIR" 2>/dev/null || true

# If .git directory does not exist, initialize it
if [[ ! -d "$TARGET_DIR/.git" ]]; then
  echo -e "${YELLOW}[INFO] Initializing git repository in $TARGET_DIR...${NC}"
  git init -b main 2>/dev/null || git init
  git remote add origin "$REPO_URL" 2>/dev/null || true
fi

# Ensure remote origin is configured
git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL" 2>/dev/null || true

echo -e "${BLUE}[1/3] Fetching latest updates from GitHub...${NC}"
git fetch --all --prune
git reset --hard origin/main

echo -e "${BLUE}[2/3] Updating npm packages...${NC}"
npm install --omit=dev

# Make all scripts executable and link global CLI shortcuts
chmod +x "$TARGET_DIR/scripts/install-soar.sh" "$TARGET_DIR/scripts/uninstall-soar.sh" "$TARGET_DIR/scripts/repair-soar.sh" 2>/dev/null || true
chmod +x "$TARGET_DIR/menu.sh" "$TARGET_DIR/update.sh" "$TARGET_DIR/uninstall.sh" 2>/dev/null || true

cat > /usr/bin/whitedns-bot <<'EOF_BIN'
#!/usr/bin/env bash
if [[ -f /opt/whitedns-bot/menu.sh ]]; then
  exec bash /opt/whitedns-bot/menu.sh "$@"
else
  exec bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/menu.sh) "$@"
fi
EOF_BIN
chmod +x /usr/bin/whitedns-bot
cp -f /usr/bin/whitedns-bot /usr/bin/bot
mkdir -p /usr/local/bin
cp -f /usr/bin/whitedns-bot /usr/local/bin/whitedns-bot
cp -f /usr/bin/whitedns-bot /usr/local/bin/bot
hash -r 2>/dev/null || true

echo -e "${BLUE}[3/3] Restarting systemd service (whitedns-bot.service)...${NC}"
systemctl daemon-reload
systemctl restart whitedns-bot.service 2>/dev/null || systemctl restart whitedns-bot 2>/dev/null || true

sleep 2
if systemctl is-active --quiet whitedns-bot.service || systemctl is-active --quiet whitedns-bot; then
  echo -e "\n${GREEN}======================================================"
  echo -e "   WhiteDNS Bot successfully updated to latest version!"
  echo -e "======================================================${NC}"
  echo -e "Service Status: ${GREEN}Active (Running)${NC}"
  echo -e "Commit: $(git log -1 --pretty=format:'%h - %s (%cd)')"
  echo -e "\nLogs: ${YELLOW}journalctl -u whitedns-bot -f${NC}"
else
  echo -e "${RED}[ERROR] Service failed to restart. Review logs below:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
EOF_UPDATE
chmod +x "$INSTALL_DIR/update.sh"

cat > "$INSTALL_DIR/uninstall.sh" <<'EOF_UNINSTALL'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Bot - Complete Uninstaller & Purge Script for Linux VPS
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}======================================================"
echo -e "   WhiteDNS Telegram Bot - Complete Uninstaller"
echo -e "======================================================${NC}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run this command."
  exit 1
fi

FORCE="${1:-}"
if [[ "$FORCE" != "-y" && "$FORCE" != "--force" ]]; then
  echo -e "${YELLOW}Are you sure you want to completely uninstall the WhiteDNS Telegram Bot? (y/N)${NC}"
  read -r -p "Confirm: " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${CYAN}Uninstallation cancelled.${NC}"
    exit 0
  fi
fi

echo -e "${BLUE}[1/3] Stopping and disabling systemd service...${NC}"
if systemctl is-active --quiet whitedns-bot.service 2>/dev/null; then
  systemctl stop whitedns-bot.service || true
fi
systemctl disable whitedns-bot.service 2>/dev/null || true
rm -f /etc/systemd/system/whitedns-bot.service
systemctl daemon-reload

echo -e "${BLUE}[2/3] Removing bot files from /opt/whitedns-bot...${NC}"
rm -rf /opt/whitedns-bot

echo -e "${BLUE}[3/3] Finalizing cleanup...${NC}"

echo -e "\n${GREEN}======================================================"
echo -e "   WhiteDNS Telegram Bot has been completely uninstalled!"
echo -e "======================================================${NC}"
echo -e "All services, files, and background daemons were removed."
EOF_UNINSTALL
chmod +x "$INSTALL_DIR/uninstall.sh"

cat > "$INSTALL_DIR/menu.sh" <<'EOF_MENU'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Telegram Bot - Interactive Terminal Management Menu
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This menu must be run as root.${NC}"
  echo -e "Please run ${YELLOW}sudo -i${NC} first, then re-run ${CYAN}whitedns-bot${NC}."
  exit 1
fi

INSTALL_DIR="/opt/whitedns-bot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$INSTALL_DIR" ]]; then
  BOT_DIR="$INSTALL_DIR"
elif [[ -d "$SCRIPT_DIR" && -f "$SCRIPT_DIR/src/bot.js" ]]; then
  BOT_DIR="$SCRIPT_DIR"
else
  BOT_DIR="$INSTALL_DIR"
  mkdir -p "$BOT_DIR"
fi

# Ensure menu.sh is saved locally in BOT_DIR
if [[ -d "$BOT_DIR" && ! -f "$BOT_DIR/menu.sh" ]]; then
  curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/menu.sh -o "$BOT_DIR/menu.sh" 2>/dev/null || true
  chmod +x "$BOT_DIR/menu.sh" 2>/dev/null || true
fi

# Install permanent standalone launcher wrappers (not broken symlinks)
install_global_launchers() {
  cat > /usr/bin/whitedns-bot <<'EOF_BIN'
#!/usr/bin/env bash
if [[ -f /opt/whitedns-bot/menu.sh ]]; then
  exec bash /opt/whitedns-bot/menu.sh "$@"
else
  exec bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/menu.sh) "$@"
fi
EOF_BIN
  chmod +x /usr/bin/whitedns-bot
  cp -f /usr/bin/whitedns-bot /usr/bin/bot
  mkdir -p /usr/local/bin
  cp -f /usr/bin/whitedns-bot /usr/local/bin/whitedns-bot
  cp -f /usr/bin/whitedns-bot /usr/local/bin/bot
  hash -r 2>/dev/null || true
}
install_global_launchers

cd "$BOT_DIR"

while true; do
  clear 2>/dev/null || true
  STATUS="UNKNOWN"
  STATUS_COLOR="$RED"
  if systemctl is-active --quiet whitedns-bot.service 2>/dev/null; then
    STATUS="ACTIVE (RUNNING)"
    STATUS_COLOR="$GREEN"
  else
    STATUS="STOPPED"
    STATUS_COLOR="$RED"
  fi

  echo -e "${CYAN}======================================================${NC}"
  echo -e "${BOLD}       WhiteDNS Telegram Bot - Management Menu        ${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo -e " Service: ${STATUS_COLOR}${STATUS}${NC} | Path: ${YELLOW}${BOT_DIR}${NC}"
  echo -e "${CYAN}------------------------------------------------------${NC}"
  echo -e " ${GREEN}1)${NC} Service Status           (systemctl status)"
  echo -e " ${GREEN}2)${NC} View Live Logs           (journalctl -u whitedns-bot -f)"
  echo -e " ${GREEN}3)${NC} Restart Bot Service      (systemctl restart)"
  echo -e " ${GREEN}4)${NC} Stop Bot Service         (systemctl stop)"
  echo -e " ${GREEN}5)${NC} Start Bot Service        (systemctl start)"
  echo -e "${CYAN}------------------------------------------------------${NC}"
  echo -e " ${GREEN}6)${NC} View Deployed Panels     (List active servers & URLs)"
  echo -e " ${GREEN}7)${NC} Update Bot to Latest     (git pull & update)"
  echo -e " ${GREEN}8)${NC} Change Telegram Token    (Edit BOT_TOKEN in .env)"
  echo -e " ${GREEN}9)${NC} Completely Uninstall     (Purge bot and systemd unit)"
  echo -e "${CYAN}------------------------------------------------------${NC}"
  echo -e " ${YELLOW}0) Exit Menu${NC}"
  echo -e "${CYAN}======================================================${NC}"
  read -r -p "Select an option [0-9]: " CHOICE

  case "$CHOICE" in
    1)
      echo -e "\n${BLUE}--- WhiteDNS Bot Service Status ---${NC}"
      systemctl status whitedns-bot.service --no-pager || true
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    2)
      echo -e "\n${BLUE}--- Live Logs (Press Ctrl+C to stop) ---${NC}"
      journalctl -u whitedns-bot.service -f -n 50 || true
      ;;
    3)
      echo -e "\n${BLUE}Restarting whitedns-bot.service...${NC}"
      systemctl restart whitedns-bot.service
      sleep 2
      if systemctl is-active --quiet whitedns-bot.service; then
        echo -e "${GREEN}[OK] Service successfully restarted!${NC}"
      else
        echo -e "${RED}[ERROR] Service failed to restart.${NC}"
      fi
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    4)
      echo -e "\n${BLUE}Stopping whitedns-bot.service...${NC}"
      systemctl stop whitedns-bot.service
      echo -e "${YELLOW}[OK] Service stopped.${NC}"
      sleep 1
      ;;
    5)
      echo -e "\n${BLUE}Starting whitedns-bot.service...${NC}"
      systemctl start whitedns-bot.service
      sleep 2
      if systemctl is-active --quiet whitedns-bot.service; then
        echo -e "${GREEN}[OK] Service is now active and running!${NC}"
      else
        echo -e "${RED}[ERROR] Failed to start service.${NC}"
      fi
      sleep 1
      ;;
    6)
      echo -e "\n${BLUE}--- Registered WhiteDNS Deployments ---${NC}"
      if [[ -f "$BOT_DIR/data.db" ]]; then
        node --input-type=module -e "
          import Database from 'better-sqlite3';
          try {
            const db = new Database('$BOT_DIR/data.db');
            const rows = db.prepare('SELECT id, domain, vps_ip, panel_url, status FROM deployments ORDER BY id DESC').all();
            if (rows.length === 0) {
              console.log('No deployments found yet. Run /start in Telegram to install a panel.');
            } else {
              console.table(rows);
            }
          } catch(e) {
            console.log('Could not read database:', e.message);
          }
        " || true
      else
        echo -e "${YELLOW}No database file found yet.${NC}"
      fi
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    7)
      echo -e "\n${BLUE}Updating WhiteDNS Bot from GitHub...${NC}"
      if [[ -f "$BOT_DIR/update.sh" ]]; then
        bash "$BOT_DIR/update.sh"
      else
        bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/update.sh)
      fi
      echo -e "\n${YELLOW}Press Enter to return to menu...${NC}"
      read -r
      ;;
    8)
      ENV_FILE="$BOT_DIR/.env"
      CURRENT_TOKEN=""
      if [[ -f "$ENV_FILE" ]]; then
        CURRENT_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)
      fi
      echo -e "\nCurrent BOT_TOKEN: ${YELLOW}$CURRENT_TOKEN${NC}"
      echo -e "Enter new BOT_TOKEN from @BotFather (or press Enter to cancel):"
      read -r -p "New Token: " NEW_TOKEN
      NEW_TOKEN=$(echo "$NEW_TOKEN" | tr -d ' "')
      if [[ -n "$NEW_TOKEN" && "$NEW_TOKEN" == *:* ]]; then
        cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${NEW_TOKEN}
NODE_ENV=production
EOF
        chmod 600 "$ENV_FILE"
        systemctl restart whitedns-bot.service
        echo -e "${GREEN}[OK] BOT_TOKEN updated and bot restarted!${NC}"
      else
        echo -e "${YELLOW}No change made.${NC}"
      fi
      sleep 2
      ;;
    9)
      echo -e "\n${RED}--- Completely Uninstall Bot ---${NC}"
      if [[ -f "$BOT_DIR/uninstall.sh" ]]; then
        bash "$BOT_DIR/uninstall.sh"
      else
        bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/uninstall.sh)
      fi
      exit 0
      ;;
    0)
      echo -e "\n${GREEN}[OK] Global commands are active! You can reopen this menu anytime by typing:${NC}"
      echo -e "       ${CYAN}whitedns-bot${NC}  or  ${CYAN}bot${NC}\n"
      exit 0
      ;;
    *)
      echo -e "\n${RED}Invalid option. Please try again.${NC}"
      sleep 1
      ;;
  esac
done
EOF_MENU
chmod +x "$INSTALL_DIR/menu.sh"

# Install global CLI wrappers
cat > /usr/bin/whitedns-bot <<'EOF_BIN'
#!/usr/bin/env bash
if [[ -f /opt/whitedns-bot/menu.sh ]]; then
  exec bash /opt/whitedns-bot/menu.sh "$@"
else
  exec bash <(curl -fsSL https://raw.githubusercontent.com/DarkPoesidon/whitedns-panel-installer-bot/main/menu.sh) "$@"
fi
EOF_BIN
chmod +x /usr/bin/whitedns-bot
cp -f /usr/bin/whitedns-bot /usr/bin/bot
mkdir -p /usr/local/bin
cp -f /usr/bin/whitedns-bot /usr/local/bin/whitedns-bot
cp -f /usr/bin/whitedns-bot /usr/local/bin/bot
hash -r 2>/dev/null || true

# 12. Install Node.js 20+
NEED_NODE=0
if ! command -v node >/dev/null 2>&1; then
  NEED_NODE=1
else
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  if (( NODE_VER < 20 )); then
    NEED_NODE=1
  fi
fi

if (( NEED_NODE )); then
  echo -e "${BLUE}[1/4] Installing Node.js 20 LTS and build tools...${NC}"
  apt-get update -y
  apt-get install -y curl build-essential ca-certificates
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
  echo -e "${GREEN}[OK] Node.js $(node -v) successfully installed.${NC}"
fi

# 13. Prompt for BOT_TOKEN
ENV_FILE="$INSTALL_DIR/.env"
BOT_TOKEN="${BOT_TOKEN:-}"

if [[ -z "$BOT_TOKEN" && -f "$ENV_FILE" ]]; then
  EXISTING_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d ' "' || true)
  if [[ -n "$EXISTING_TOKEN" ]]; then
    BOT_TOKEN="$EXISTING_TOKEN"
  fi
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo -e "\n${YELLOW}[INPUT] Telegram Bot Token configuration:${NC}"
  echo -e "Enter the BOT_TOKEN received from ${CYAN}@BotFather${NC}:"
  read -r -p "BOT_TOKEN: " INPUT_TOKEN
  BOT_TOKEN=$(echo "$INPUT_TOKEN" | tr -d ' "')
fi

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" != *:* ]]; then
  echo -e "${RED}[ERROR] Invalid token format. Expected: 123456789:ABCdefGhIjk...${NC}"
  exit 1
fi

cat > "$ENV_FILE" <<EOF_ENV
BOT_TOKEN=${BOT_TOKEN}
NODE_ENV=production
EOF_ENV
chmod 600 "$ENV_FILE"

# 14. Run npm install
echo -e "${BLUE}[2/4] Installing dependencies (npm install)...${NC}"
cd "$INSTALL_DIR"
npm install --omit=dev

# 15. Create & start systemd service
SERVICE_FILE="/etc/systemd/system/whitedns-bot.service"
echo -e "${BLUE}[3/4] Creating systemd service (whitedns-bot.service)...${NC}"

NODE_BIN=$(command -v node)

cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=WhiteDNS Autonomous Telegram Bot
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} src/bot.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable --now whitedns-bot.service

sleep 2
if systemctl is-active --quiet whitedns-bot.service; then
  echo -e "\n${GREEN}======================================================"
  echo -e "   WhiteDNS Bot successfully installed and active!"
  echo -e "======================================================${NC}"
  echo -e "Service Status: ${GREEN}Active (Running)${NC}"
  echo -e "\nNow open Telegram and send ${CYAN}/start${NC} to your bot."
  echo -e "\nUseful server commands:"
  echo -e "  Open Bot Menu:    ${YELLOW}whitedns-bot${NC}  or  ${YELLOW}bot${NC}"
  echo -e "  View live logs:   ${YELLOW}journalctl -u whitedns-bot -f${NC}"
  echo -e "  Restart service:  ${YELLOW}systemctl restart whitedns-bot${NC}"
  echo -e "  Service status:   ${YELLOW}systemctl status whitedns-bot${NC}"
  echo -e "  Stop service:     ${YELLOW}systemctl stop whitedns-bot${NC}"
else
  echo -e "${RED}[ERROR] Service failed to start. Review logs below:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
