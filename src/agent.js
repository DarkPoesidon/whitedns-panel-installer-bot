import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { AGENT_SCRIPT, bundleUrl, panelHash } from './config.js';
import { SshError, shellQuote } from './ssh.js';

const DIR = '/var/lib/whitedns-agent';
const UNIT = 'whitedns-agent';
const LOG = `${DIR}/job.log`;
const JOB_KEYS = ['ZONE', 'NS_HOST', 'PANEL_DOMAIN', 'PUBLIC_IP', 'LISTEN_IP', 'ADMIN_USER', 'ADMIN_EMAIL', 'VERSION', 'BUNDLE_SHA256', 'RESET_ADMIN', 'ON_ZONE_MISMATCH', 'ALLOW_MIGRATE', 'UNINSTALL_MODE'];
const RECONNECT_WINDOW_MS = 5 * 60 * 1000;
const JOB_DEADLINE_MS = 35 * 60 * 1000;

const agentScript = () => fs.readFileSync(AGENT_SCRIPT, 'utf8').replace(/\r\n/g, '\n');
const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

export function parseEvent(line) {
  const match = /^@@ (\S+) (\S+)(?: (\S+))?(?: (.*))?$/.exec(line);
  if (!match) return null;
  return { stage: match[1], status: match[2], code: match[3] === '-' ? '' : (match[3] ?? ''), detail: (match[4] ?? '').trim() };
}

export function parseKeyValues(text) {
  const out = { warnings: [], localIps: [] };
  for (const line of String(text).split('\n')) {
    const index = line.indexOf('=');
    if (index < 1) continue;
    const key = line.slice(0, index).trim();
    const value = line.slice(index + 1).trim();
    if (key === 'warning') out.warnings.push(value);
    else if (key === 'local_ip') out.localIps.push(value);
    else out[key] = value;
  }
  return out;
}

export function buildJobEnv(params) {
  const lines = [];
  for (const [key, value] of Object.entries(params)) {
    if (!JOB_KEYS.includes(key)) throw new Error(`unknown job key ${key}`);
    if (value === undefined || value === null || value === '') continue;
    if (/[\r\n]/.test(String(value))) throw new Error(`invalid value for ${key}`);
    lines.push(`${key}=${value}`);
  }
  return `${lines.join('\n')}\n`;
}

/** Read-only inspection; piped to bash so nothing is left on the server. */
export async function probe(session, sshHost) {
  const { code, stdout, stderr } = await session.exec(`bash -s -- probe ${shellQuote(sshHost)}`, { stdin: agentScript(), timeoutMs: 45000 });
  if (code !== 0) throw new SshError('PROBE_FAILED', stderr.trim().split('\n').pop() || `exit ${code}`);
  return parseKeyValues(stdout);
}

async function startJob(session, op, params, secret) {
  const active = await session.exec(`systemctl is-active --quiet ${UNIT}; echo $?`);
  if (active.stdout.trim() === '0') return { attached: true };

  await session.exec(`install -d -m 0700 ${DIR}; rm -f ${DIR}/result.env; : > ${LOG}; chmod 0600 ${LOG}`);
  await session.writeFile(`${DIR}/agent.sh`, agentScript());
  try {
    await session.writeFile(`${DIR}/job.env`, buildJobEnv(params));
    if (secret) await session.writeFile(`${DIR}/admin.secret`, secret);

    const started = await session.exec(
      `systemctl reset-failed ${UNIT} 2>/dev/null; systemd-run --quiet --collect --unit=${UNIT} -p RuntimeMaxSec=1800 `
      + `-p StandardOutput=append:${LOG} -p StandardError=append:${LOG} bash ${DIR}/agent.sh ${op}`,
    );
    if (started.code !== 0) throw new SshError('JOB_START_FAILED', started.stderr.trim());
  } catch (err) {
    // The agent's own cleanup never ran, so the password would otherwise stay on the server.
    await session.exec(`rm -f ${DIR}/admin.secret ${DIR}/job.env`).catch(() => {});
    throw err;
  }
  return { attached: false };
}

/** Streams the job log from a byte offset until the unit stops. */
function tailJob(session, offset, onChunk) {
  const script = `tail -c +${offset + 1} -F ${LOG} 2>/dev/null & t=$!; `
    + `while systemctl is-active --quiet ${UNIT}; do sleep 1; done; sleep 1; kill $t 2>/dev/null; wait $t 2>/dev/null; exit 0`;
  return session.exec(script, { timeoutMs: JOB_DEADLINE_MS, onData: onChunk });
}

/**
 * Follows the detached job, reconnecting when SSH drops. The job keeps running on the server
 * either way, so losing the connection is reported rather than treated as failure.
 */
export async function followJob({ connect, session, onEvent, retryDelayMs = 5000, reconnectWindowMs = RECONNECT_WINDOW_MS }) {
  let current = session;
  let offset = 0;
  let buffer = Buffer.alloc(0);

  const consume = (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    let index;
    while ((index = buffer.indexOf(0x0a)) >= 0) {
      const line = buffer.subarray(0, index).toString('utf8');
      offset += index + 1;
      buffer = buffer.subarray(index + 1);
      const event = parseEvent(line);
      if (event) onEvent(event);
    }
  };

  for (;;) {
    try {
      await tailJob(current, offset, consume);
      const { stdout } = await current.exec(`cat ${DIR}/result.env 2>/dev/null || true`);
      return { session: current, result: parseKeyValues(stdout) };
    } catch (err) {
      if (err.code === 'SUDO_FAILED') throw err;
      buffer = Buffer.alloc(0);
      const deadline = Date.now() + reconnectWindowMs;
      current = null;
      while (!current) {
        if (Date.now() > deadline) throw new SshError('LOST_CONNECTION');
        await sleep(retryDelayMs);
        try {
          current = await connect();
        } catch (connectErr) {
          if (connectErr.code === 'AUTH_FAILED' || connectErr.code === 'HOST_KEY_CHANGED') throw connectErr;
        }
      }
    }
  }
}

let bundleCache = null;

/** For servers that cannot reach GitHub. The bot's copy is checked again by the agent on arrival. */
export async function downloadBundle(arch, fetchImpl = fetch) {
  const url = bundleUrl(arch);
  if (bundleCache?.url === url) return bundleCache.data;
  const res = await fetchImpl(url, { signal: AbortSignal.timeout(180000) });
  if (!res.ok) throw new SshError('BUNDLE_DOWNLOAD_FAILED', `HTTP ${res.status}`);
  const data = Buffer.from(await res.arrayBuffer());
  const expected = panelHash(arch);
  if (expected && createHash('sha256').update(data).digest('hex') !== expected) {
    throw new SshError('BUNDLE_DOWNLOAD_FAILED', 'checksum mismatch');
  }
  bundleCache = { url, data };
  return data;
}

/**
 * Runs an agent operation to its end: start or attach, follow, and on NEED_BUNDLE upload the
 * panel release and run once more. `connect` opens a fresh session for reconnects.
 * `attachOnly` never starts anything: a job that ended meanwhile must not become a new one.
 */
export async function runJob({ session, connect, op, params, secret, arch, onEvent, attachOnly = false, download = downloadBundle, retryDelayMs }) {
  let current = session;
  for (let attempt = 0; ; attempt += 1) {
    const { attached } = attachOnly ? { attached: true } : await startJob(current, op, params, secret);
    const followed = await followJob({ connect, session: current, onEvent, retryDelayMs });
    current = followed.session;
    if (followed.result.code === 'NEED_BUNDLE' && attempt === 0 && !attached) {
      onEvent({ stage: 'fetch', status: 'start', code: 'UPLOADING_BUNDLE', detail: '' });
      const data = await download(arch);
      await current.writeFile(`${DIR}/bundle.tar.gz`, data);
      continue;
    }
    if (!followed.result.status) throw new SshError('NO_RESULT');
    return { ...followed.result, attached, session: current };
  }
}

export async function cleanupAgentDir(session) {
  await session.exec(`rm -rf ${DIR}`).catch(() => {});
}
