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

# Initialize git repository so self-updates work
if command -v git &>/dev/null; then
  git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true
  if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    (cd "$INSTALL_DIR" && (git init -b main 2>/dev/null || git init) && (git remote add origin https://github.com/DarkPoesidon/whitedns-panel-installer-bot.git 2>/dev/null || true)) 2>/dev/null || true
  fi
fi

# 1. Write package.json
cat > "$INSTALL_DIR/package.json" <<'EOF'
{
  "name": "whitedns-server-bot",
  "version": "1.0.0",
  "description": "Autonomous Telegram Bot with direct SSH execution for WhiteDNS deployment",
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
  }
}
EOF

# 2. Write src/config.js
cat > "$INSTALL_DIR/src/config.js" <<'EOF'
import 'dotenv/config';

export const BOT_TOKEN = process.env.BOT_TOKEN || '';

if (!BOT_TOKEN) {
  console.warn('⚠️ WARNING: BOT_TOKEN is not defined in your environment or .env file!');
}

export const CF_TEMPLATE_URL = 'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&accountId=*&zoneId=all&name=WhiteDNS';
EOF

# 3. Write src/db.js
cat > "$INSTALL_DIR/src/db.js" <<'EOF'
import Database from 'better-sqlite3';
import { fileURLToPath } from 'url';
import path from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const dbPath = path.resolve(__dirname, '../data.db');

export const db = new Database(dbPath);
db.pragma('journal_mode = WAL');

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
EOF

# 4. Write src/cloudflare.js
cat > "$INSTALL_DIR/src/cloudflare.js" <<'EOF'
const CF_API_BASE = 'https://api.cloudflare.com/client/v4';

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

export async function verifyToken(authInput) {
  try {
    const headers = getAuthHeaders(authInput);
    const endpoint = headers['X-Auth-Key'] ? `${CF_API_BASE}/user` : `${CF_API_BASE}/user/tokens/verify`;

    const res = await fetch(endpoint, { method: 'GET', headers });
    if (res.ok) {
      const data = await res.json();
      if (data.success) {
        return { ok: true, resolvedAuth: authInput };
      }
    }

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

    return { ok: false, error: 'کلید یا توکن نامعتبر است. لطفاً مجدداً بررسی فرمایید.' };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

export async function listZones(authInput) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones?status=active&per_page=50`, { method: 'GET', headers });
    if (!res.ok) return { ok: false, error: `HTTP ${res.status}` };
    const data = await res.json();
    if (!data.success) return { ok: false, error: data.errors?.[0]?.message || 'Unknown API error' };
    const zones = (data.result || []).map(z => ({ id: z.id, name: z.name }));
    return { ok: true, zones };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function upsertDnsRecord(authInput, zoneId, type, name, content, proxied = false) {
  const headers = getAuthHeaders(authInput);
  const searchUrl = `${CF_API_BASE}/zones/${zoneId}/dns_records?type=${type}&name=${encodeURIComponent(name)}`;
  const searchRes = await fetch(searchUrl, { headers });
  const searchData = await searchRes.json();
  const existing = searchData.result?.[0];

  const payload = { type, name, content, ttl: 1, proxied: !!proxied };

  if (existing) {
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

export async function setupSoarDnsRecords(authInput, zoneId, domain, vpsIp) {
  const cleanDomain = domain.toLowerCase().trim();
  const nsHost = `ns-soar.${cleanDomain}`;
  const tunnelZone = `soar.${cleanDomain}`;
  const panelHost = `panel.${cleanDomain}`;

  const nsARecord = await upsertDnsRecord(authInput, zoneId, 'A', nsHost, vpsIp, false);
  const soarNsRecord = await upsertDnsRecord(authInput, zoneId, 'NS', tunnelZone, nsHost, false);
  const panelARecord = await upsertDnsRecord(authInput, zoneId, 'A', panelHost, vpsIp, false);

  return { ok: true, nsARecord, soarNsRecord, panelARecord };
}
EOF

# 5. Write src/ui.js
cat > "$INSTALL_DIR/src/ui.js" <<'EOF'
export function generateStrongPassword(length = 16) {
  const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*';
  let pass = '';
  pass += 'abcdefghjkmnpqrstuvwxyz'[Math.floor(Math.random() * 23)];
  pass += 'ABCDEFGHJKLMNPQRSTUVWXYZ'[Math.floor(Math.random() * 23)];
  pass += '23456789'[Math.floor(Math.random() * 8)];
  pass += '!@#$%^&*'[Math.floor(Math.random() * 8)];
  for (let i = 4; i < length; i++) {
    pass += chars[Math.floor(Math.random() * chars.length)];
  }
  return pass.split('').sort(() => 0.5 - Math.random()).join('');
}

export function renderProgressBox(currentStep, totalSteps = 6, domain = '', ip = '', statusText = '') {
  const steps = [
    { num: 1, title: 'اتصال SSH به سرور و حل تداخل پورت ۵۳' },
    { num: 2, title: 'نصب بسته‌های سیستمی و نیازمندی‌ها' },
    { num: 3, title: 'دانلود باینری رسمی WhiteDNS و اعتبارسنجی SHA256' },
    { num: 4, title: 'راه‌اندازی دیتابیس، کاربر سیستمی و فایروال' },
    { num: 5, title: 'راه‌اندازی سرویس‌های daemon و صدور SSL' },
    { num: 6, title: 'استخراج آدرس اختصاصی و نهایی پنل' },
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

  text += '\n⚠️ _این فرآیند روی سرور شما اجرا می‌شود و حدود ۶۰ ثانیه زمان می‌برد._';
  return text;
}

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

export function renderErrorCard(errorMsg) {
  return `❌ **عملیات نصب بر روی سرور متوقف شد**

علت خطا:
\`${errorMsg}\`

💡 **راهنما و راه‌حل:**
۱. اتصال اینترنت سرور و در دسترس بودن پورت ۲۲ را بررسی کنید.
۲. از صحت پسورد root اطمینان حاصل نمایید.
۳. مطمئن شوید پورت‌های ۵۳، ۸۰ و ۴۴۳ در فایروال پرووایدر VPS مسدود نیستند.`;
}
EOF

# 6. Write src/ssh-installer.js
cat > "$INSTALL_DIR/src/ssh-installer.js" <<'EOF'
import { Client } from 'ssh2';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const installerScriptPath = path.resolve(__dirname, '../scripts/install-soar.sh');

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

  const scriptContent = fs.readFileSync(installerScriptPath, 'utf8');

  return new Promise((resolve, reject) => {
    const conn = new Client();
    let fullOutput = '';
    let isFinished = false;

    conn.on('ready', () => {
      if (onProgress) {
        onProgress(1, 'اتصال SSH برقرار شد. در حال اعتبارسنجی سیستم‌عامل و آزادسازی پورت ۵۳...');
      }

      const cmd = `export ZONE="${zone}" NS_HOST="${nsHost}" PANEL_DOMAIN="${panelDomain}" PUBLIC_IP="${vpsIp}" ADMIN_USER="${adminUser}" ADMIN_PASS="${adminPass}"; bash -s`;

      conn.exec(cmd, (err, stream) => {
        if (err) {
          conn.end();
          return reject(new Error(`خطا در اجرای دستور روی سرور: ${err.message}`));
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
          isFinished = true;

          if (code !== 0) {
            conn.end();
            const errorMatch = fullOutput.match(/\[FATAL ERROR\] (.+)/);
            const errorMsg = errorMatch ? errorMatch[1] : `اسکریپت با کد خطا ${code} به پایان رسید.`;
            return reject(new Error(errorMsg));
          }

          let resultJson = null;
          try {
            const jsonStart = fullOutput.indexOf('{\n  "status":');
            const jsonEnd = fullOutput.lastIndexOf('}\n');
            if (jsonStart !== -1 && jsonEnd !== -1) {
              const rawJson = fullOutput.substring(jsonStart, jsonEnd + 2);
              resultJson = JSON.parse(rawJson);
            }
          } catch (e) {}

          let panelUrl = resultJson?.panel_url;
          if (!panelUrl || !panelUrl.startsWith('http')) {
            try {
              panelUrl = await new Promise((resUrl) => {
                conn.exec('/usr/local/bin/soar-panel access-url --db /var/lib/soar-panel/panel.db --listen 127.0.0.1:2053', (err2, stream2) => {
                  if (err2) return resUrl('');
                  let out = '';
                  stream2.on('data', (d) => { out += d.toString('utf8'); });
                  stream2.on('close', () => { resUrl(out.trim()); });
                });
              });
            } catch (e) {}
          }

          conn.end();

          if (panelUrl && (panelUrl.includes('127.0.0.1') || panelUrl.includes('localhost'))) {
            try {
              const parsed = new URL(panelUrl);
              panelUrl = `https://${panelDomain}${parsed.pathname}`;
            } catch (e) {
              const match = panelUrl.match(/\/[A-Za-z0-9_-]{20,}\/?$/);
              if (match) panelUrl = `https://${panelDomain}${match[0]}`;
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
EOF

# 7. Write src/bot.js
cat > "$INSTALL_DIR/src/bot.js" <<'EOF'
import { Telegraf, Markup } from 'telegraf';
import { BOT_TOKEN, CF_TEMPLATE_URL } from './config.js';
import { getSession, saveSession, resetSession, addDeployment, listDeployments } from './db.js';
import { verifyToken, listZones, setupSoarDnsRecords } from './cloudflare.js';
import { installOverSSH } from './ssh-installer.js';
import { generateStrongPassword, renderProgressBox, renderCompletionCard, renderErrorCard } from './ui.js';

if (!BOT_TOKEN) {
  console.error('❌ FATAL: BOT_TOKEN is missing! Please provide BOT_TOKEN in .env file.');
  process.exit(1);
}

export const bot = new Telegraf(BOT_TOKEN);

async function registerCommands() {
  try {
    await bot.telegram.setMyCommands([
      { command: 'start', description: '🚀 شروع و نصب پنل WhiteDNS' },
      { command: 'status', description: '📊 مشاهده سرورها و پنل‌های فعال' },
      { command: 'help', description: '❓ راهنمای استفاده و پیش‌نیازها' },
      { command: 'reset', description: '🔄 لغو و شروع مجدد' }
    ]);
  } catch (err) {
    console.warn('Could not set commands:', err.message);
  }
}

bot.command('start', async (ctx) => {
  const chatId = ctx.chat.id;
  resetSession(chatId, 'AWAITING_CF_EMAIL');

  return ctx.replyWithMarkdown(
    `👋 **به ربات نصب کاملاً خودکار WhiteDNS Soar Server خوش آمدید.**\n\nاین ربات تمامی مراحل تنظیم کلودفلر، اتصال SSH به سرور، حل تداخل پورت ۵۳، نصب پیش‌نیازها و صدور گواهی SSL را **به صورت ۱۰۰٪ خودکار** انجام می‌دهد.\n\n📧 **مرحله ۱ از ۲: ورود ایمیل کلودفلر**\nلطفاً **آدرس ایمیل** اکانت کلودفلر خود را ارسال فرمایید:\n_(مثال: myname@gmail.com)_\n\n💡 _اگر توکن آماده دارید، می‌توانید آن را مستقیماً ارسال کنید._`,
    Markup.inlineKeyboard([
      [Markup.button.url('🚀 باز کردن فرم آماده توکن (۱-کلیک)', CF_TEMPLATE_URL)],
      [Markup.button.callback('❌ انصراف', 'cancel')]
    ])
  );
});

bot.command('help', async (ctx) => {
  return ctx.replyWithMarkdown(
    `📖 **راهنمای جامع ربات نصب خودکار WhiteDNS**\n\n🔹 **این ربات چه کار می‌کند؟**\nاین ربات مستقیماً از طریق پروتکل امن SSH به سرور شما متصل شده، تانل DNS (Soar و Cotten) را کانفیگ کرده و پنل وب مدیریتی را با آدرس امن فعال می‌کند.\n\n🔹 **پیش‌نیازها:**\n۱. یک سرور خام با سیستم‌عامل Ubuntu 22/24 یا Debian 12/13.\n۲. یک دامنه متصل به اکانت کلودفلر.\n\n🔹 **دستورات منو:**\n• /start - شروع فرآیند نصب\n• /status - مشاهده پنل‌ها و لینک‌های فعال\n• /reset - ریست و لغو مرحله جاری\n• /help - نمایش این راهنما`,
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 شروع نصب جدید', 'cmd:start')]
    ])
  );
});

bot.command('status', async (ctx) => {
  const chatId = ctx.chat.id;
  const list = listDeployments(chatId);

  if (!list || list.length === 0) {
    return ctx.replyWithMarkdown(
      `📊 **وضعیت سرورها:**\n\nشما هنوز هیچ پنلی راه‌اندازی نکرده‌اید.\nبرای شروع نصب اولین سرور، روی دکمه زیر بزنید:`,
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

  return ctx.replyWithMarkdown(
    text,
    Markup.inlineKeyboard([
      [Markup.button.callback('🚀 نصب سرور جدید', 'cmd:start')]
    ])
  );
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

bot.on('text', async (ctx) => {
  const chatId = ctx.chat.id;
  const text = ctx.message.text.trim();
  const session = getSession(chatId);

  if (!session || session.step === 'IDLE') return;

  if (session.step === 'AWAITING_CF_EMAIL') {
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

  if (session.step === 'AWAITING_CF_KEY') {
    await ctx.deleteMessage().catch(() => {});
    let authInput = text;
    if (session.cfToken && session.cfToken.includes('@') && !text.includes(':')) {
      authInput = `${session.cfToken}:${text}`;
    }
    return handleCloudflareAuth(ctx, chatId, authInput);
  }

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

  if (session.step === 'AWAITING_SSH_USER_CUSTOM') {
    if (!text || text.length > 32) return ctx.replyWithMarkdown('❌ نام کاربری نامعتبر است.');
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
});

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
    `🌐 دامنه انتخاب‌شده: \`${domain}\`\n\n📌 اکنون لطفاً **آدرس IPv4 عمومی سرور (VPS)** خود را ارسال کنید:\n_(مثال: \`194.26.11.20\`)_\n\n💡 _همچنین می‌توانید مشخصات کامل را یکجا بفرستید:_\n\`IP:Port:User:Password\``,
    Markup.inlineKeyboard([
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
    await setupSoarDnsRecords(cfToken, zoneId, domain, vpsIp);

    await ctx.telegram.editMessageText(
      chatId,
      progressMsg.message_id,
      undefined,
      renderProgressBox(1, 6, domain, vpsIp, 'رکوردهای DNS با موفقیت ثبت شدند. در حال اتصال SSH به سرور...'),
      { parse_mode: 'Markdown' }
    );

    let lastRenderedStep = 1;

    const result = await installOverSSH({
      vpsIp,
      vpsPort,
      vpsUser,
      vpsPass,
      domain,
      adminUser: 'admin',
      adminPass,
      onProgress: async (step, msg) => {
        if (step !== lastRenderedStep && step <= 6) {
          lastRenderedStep = step;
          await ctx.telegram.editMessageText(
            chatId,
            progressMsg.message_id,
            undefined,
            renderProgressBox(step, 6, domain, vpsIp, msg),
            { parse_mode: 'Markdown' }
          ).catch(() => {});
        }
      }
    });

    addDeployment({
      chatId,
      domain,
      vpsIp,
      panelUrl: result.panelUrl,
      status: 'COMPLETED'
    });

    saveSession(chatId, { step: 'COMPLETED' });

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

registerCommands();

bot.launch(() => {
  console.log('🤖 WhiteDNS Linux Server Bot is online and listening for updates!');
});

process.once('SIGINT', () => bot.stop('SIGINT'));
process.once('SIGTERM', () => bot.stop('SIGTERM'));
EOF

# 8. Copy install-soar.sh
cat > "$INSTALL_DIR/scripts/install-soar.sh" <<'EOF_SOAR'
#!/usr/bin/env bash
# ==============================================================================
# WhiteDNS Soar Server - 100% Unattended Headless Installer
# ==============================================================================
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077

ZONE="${ZONE:-}"
NS_HOST="${NS_HOST:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${ZONE#*.}}"
PANEL_PORT="${PANEL_PORT:-2053}"
DNS_PORT="${DNS_PORT:-53}"
RESOLVERS="${RESOLVERS:-1.1.1.1,8.8.8.8}"

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

report_progress "1" "in_progress" "Validating server environment and ports..."

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
  *) die "Unsupported architecture: $(uname -m)." ;;
esac

[[ -n "$ZONE" ]] || die "ZONE is missing."
[[ -n "$NS_HOST" ]] || die "NS_HOST is missing."
[[ -n "$PANEL_DOMAIN" ]] || die "PANEL_DOMAIN is missing."
[[ -n "$ADMIN_PASS" ]] || die "ADMIN_PASS is missing."

if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(curl -4s --connect-timeout 5 https://api.ipify.org || ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
fi
[[ -n "$PUBLIC_IP" ]] || die "Could not determine PUBLIC_IP."

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if grep -qE '^#?DNSStubListener=yes' /etc/systemd/resolved.conf; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved || true
  fi
fi

report_progress "1" "success" "Server verified: $ID $VERSION_ID ($BUNDLE_ARCH), IP: $PUBLIC_IP"

report_progress "2" "in_progress" "Installing prerequisites (curl, dnsutils, iproute2, ufw, tar)..."
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl dnsutils iproute2 ufw tar coreutils util-linux
report_progress "2" "success" "Dependencies successfully installed."

report_progress "3" "in_progress" "Fetching latest official WhiteDNS Soar Server release..."
PANEL_REPO="WhiteDNS/Soar-Server"
LATEST_TAG=$(curl -fsSL --retry 3 "https://api.github.com/repos/$PANEL_REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": "panel-v?([^"]+)".*/\1/')
if [[ -z "$LATEST_TAG" ]]; then
  LATEST_URL=$(curl -fsSL -o /dev/null -w "%{url_effective}" "https://github.com/$PANEL_REPO/releases/latest")
  LATEST_TAG="${LATEST_URL##*/panel-v}"
fi
[[ -n "$LATEST_TAG" ]] || die "Failed to determine latest WhiteDNS release version."

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

report_progress "4" "in_progress" "Setting up system user and binaries..."
id soar-panel >/dev/null 2>&1 || useradd --system --home-dir /var/lib/soar-panel --shell /usr/sbin/nologin soar-panel
install -d -o soar-panel -g soar-panel -m 0700 /var/lib/soar-panel
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

report_progress "4" "success" "Binaries and directories initialized."

report_progress "5" "in_progress" "Initializing database and security parameters..."
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

/usr/local/bin/soar-panel configure-access \
  --db "$DB_FILE" \
  --listen "127.0.0.1:$PANEL_PORT" \
  --random-path

chown soar-panel:soar-panel /var/lib/soar-panel/access.json
chmod 0600 /var/lib/soar-panel/access.json

report_progress "5" "success" "Database initialized with zone $ZONE and admin $ADMIN_USER."

report_progress "6" "in_progress" "Creating and launching systemd daemon services..."

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

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$DNS_PORT/udp" comment 'soar-tunnel-dns' || true
  ufw allow "$DNS_PORT/tcp" comment 'soar-tunnel-dns' || true
  ufw allow 80/tcp comment 'soar-acme-http' || true
  ufw allow 443/tcp comment 'soar-panel-https' || true
fi

systemctl daemon-reload
systemctl enable --now soar-panel-ops.service
systemctl enable --now soar-panel.service

HEALTHY=0
for i in {1..30}; do
  if systemctl is-active --quiet soar-panel.service && \
     /usr/local/bin/soar-panel health --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 1
done

[[ $HEALTHY -eq 1 ]] || die "Panel service failed to reach healthy state."

report_progress "6" "success" "Systemd services active and healthy."

report_progress "7" "in_progress" "Acquiring Let's Encrypt certificate for $PANEL_DOMAIN..."

systemctl stop soar-panel.service || true

FINAL_URL=""
if /usr/local/bin/soar-panel configure-access \
    --db "$DB_FILE" \
    --listen "127.0.0.1:$PANEL_PORT" \
    --domain "$PANEL_DOMAIN" \
    --email "$ADMIN_EMAIL" \
    --random-path; then
  chown soar-panel:soar-panel /var/lib/soar-panel/access.json || true
  if [[ -d /var/lib/soar-panel/certificates ]]; then
    chown -R soar-panel:soar-panel /var/lib/soar-panel/certificates || true
  fi
fi

systemctl start soar-panel.service || true
sleep 3

FINAL_URL=$(/usr/local/bin/soar-panel access-url --db "$DB_FILE" --listen "127.0.0.1:$PANEL_PORT" 2>/dev/null || true)

if [[ "$FINAL_URL" == http://127.0.0.1* || "$FINAL_URL" == http://localhost* ]]; then
  SECRET_PATH="${FINAL_URL#*:$PANEL_PORT}"
  FINAL_URL="https://$PANEL_DOMAIN$SECRET_PATH"
elif [[ -z "$FINAL_URL" ]]; then
  FINAL_URL="https://$PANEL_DOMAIN/"
fi

report_progress "7" "success" "SSL and HTTPS access configured."
report_progress "COMPLETED" "success" "Installation 100% completed!"

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
EOF_SOAR

chmod +x "$INSTALL_DIR/scripts/install-soar.sh"

# 9. Install Node.js 20+
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

# 10. Prompt for BOT_TOKEN
ENV_FILE="$INSTALL_DIR/.env"
BOT_TOKEN="${BOT_TOKEN:-}"

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

cat > "$ENV_FILE" <<EOF
BOT_TOKEN=${BOT_TOKEN}
NODE_ENV=production
EOF
chmod 600 "$ENV_FILE"

# 11. Run npm install
echo -e "${BLUE}[2/4] Installing dependencies (npm install)...${NC}"
cd "$INSTALL_DIR"
npm install --omit=dev

# 12. Create & start systemd service
SERVICE_FILE="/etc/systemd/system/whitedns-bot.service"
echo -e "${BLUE}[3/4] Creating systemd service (whitedns-bot.service)...${NC}"

NODE_BIN=$(command -v node)

cat > "$SERVICE_FILE" <<EOF
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
EOF

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
  echo -e "  View live logs:   ${YELLOW}journalctl -u whitedns-bot -f${NC}"
  echo -e "  Restart service:  ${YELLOW}systemctl restart whitedns-bot${NC}"
  echo -e "  Service status:   ${YELLOW}systemctl status whitedns-bot${NC}"
  echo -e "  Stop service:     ${YELLOW}systemctl stop whitedns-bot${NC}"
else
  echo -e "${RED}[ERROR] Service failed to start. Review logs below:${NC}"
  journalctl -u whitedns-bot -n 20 --no-pager
  exit 1
fi
