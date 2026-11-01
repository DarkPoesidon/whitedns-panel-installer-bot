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
