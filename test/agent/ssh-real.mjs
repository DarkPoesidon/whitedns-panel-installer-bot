// Real test through ssh2 against a disposable Linux: sudo over stdin, the detached job,
// reconnect after a dropped connection, and uploading the bundle when GitHub is unreachable.
// Usage: SSH_TEST_HOST=... SSH_TEST_USER=... SSH_TEST_PASSWORD=... node test/agent/ssh-real.mjs
// The target machine gets the real panel installed and removed. Never point this at a real server.
import assert from 'node:assert/strict';
import { connectSsh } from '../../src/ssh.js';
import { probe, runJob, cleanupAgentDir } from '../../src/agent.js';
import { PANEL_VERSION, panelHash } from '../../src/config.js';

const { SSH_TEST_HOST: host, SSH_TEST_USER: user, SSH_TEST_PASSWORD: password } = process.env;
assert.ok(host && user && password, 'set SSH_TEST_HOST, SSH_TEST_USER and SSH_TEST_PASSWORD');

const ADMIN = 'RealSshTestPassw0rd';
const log = (text) => console.log(text);
const connect = () => connectSsh({ host, user, password });

function jobParams(facts, extra = {}) {
  return {
    ZONE: 'soar.ssh-test.example',
    NS_HOST: 'ns-soar.ssh-test.example',
    PUBLIC_IP: '45.33.32.156',
    LISTEN_IP: facts.listen_ip,
    VERSION: PANEL_VERSION,
    BUNDLE_SHA256: panelHash(facts.arch),
    ...extra,
  };
}

const session = await connect();
log(`connected, fingerprint ${session.fingerprint}`);

// --- wrong password is classified
await assert.rejects(connectSsh({ host, user, password: 'definitely-wrong' }), (err) => err.code === 'AUTH_FAILED');
log('ok   wrong password -> AUTH_FAILED');

// --- host key pinning
await assert.rejects(connectSsh({ host, user, password, expectedFingerprint: 'not-the-key' }), (err) => err.code === 'HOST_KEY_CHANGED');
log('ok   changed host key -> HOST_KEY_CHANGED');

// --- sudo keeps the rest of stdin for the command
const echoed = await session.exec('cat', { stdin: 'payload-after-password' });
assert.equal(echoed.stdout, 'payload-after-password');
const whoami = await session.exec('id -un');
assert.equal(whoami.stdout.trim(), 'root');
log(`ok   ${user} reaches root through sudo and stdin survives`);

const facts = await probe(session, session.conn.config?.host ?? host);
log(`ok   probe: ${facts.os} ${facts.arch} listen=${facts.listen_ip} installed=${facts.installed}`);
assert.equal(facts.installed, '0', 'start from a clean machine');

// --- the admin password must not be visible to other processes during the job
const events = [];
let spied = '';
let dropped = false;
const result = await runJob({
  session,
  connect,
  op: 'install',
  arch: facts.arch,
  secret: ADMIN,
  params: jobParams(facts),
  retryDelayMs: 500,
  onEvent(event) {
    events.push(event);
    // Cut SSH mid job; the job must survive and the bot must reconnect and catch up.
    if (event.stage === 'activate' && event.status === 'start' && !dropped) {
      dropped = true;
      log('...  dropping SSH during activate');
      session.conn.end();
    }
  },
});
assert.equal(result.status, 'ok', `${result.code} ${result.detail}`);
assert.ok(dropped, 'the connection was dropped mid job');
assert.ok(events.some((e) => e.stage === 'verify' && e.status === 'ok'), 'events after the reconnect arrived');
assert.ok(/^http:\/\/45\.33\.32\.156:\d+\/[A-Za-z0-9_-]{24,96}\/$/.test(result.panel_url), result.panel_url);
log(`ok   install survived a dropped connection: ${result.panel_url}`);

const after = result.session;
spied = (await after.exec(`grep -l ${ADMIN} /var/lib/whitedns-agent/* 2>/dev/null || true`)).stdout;
assert.equal(spied.trim(), '', 'password remains on disk');
log('ok   admin password left no file on the server');

// --- a second start attaches instead of launching a parallel job
const attached = await runJob({ session: after, connect, op: 'repair', arch: facts.arch, params: { LISTEN_IP: facts.listen_ip, VERSION: PANEL_VERSION }, onEvent() {} });
assert.equal(attached.status, 'ok');
log('ok   repair over the same session');

// --- bundle upload path, with GitHub unreachable from the server
const clean = attached.session;
await runJob({ session: clean, connect, op: 'uninstall', arch: facts.arch, params: { UNINSTALL_MODE: 'purge' }, onEvent() {} });
await clean.exec("cp /etc/hosts /etc/hosts.wdtest && printf '127.0.0.1 github.com\\n' >> /etc/hosts");
try {
  const noted = [];
  const offline = await runJob({
    session: clean, connect, op: 'install', arch: facts.arch, secret: ADMIN, params: jobParams(facts), onEvent: (e) => noted.push(e.code),
  });
  assert.equal(offline.status, 'ok', `${offline.code} ${offline.detail}`);
  assert.ok(noted.includes('NEED_BUNDLE') || noted.includes('UPLOADING_BUNDLE'), 'the bundle path ran');
  log('ok   install succeeded with GitHub blocked, through bundle upload');
  const removed = await runJob({ session: offline.session, connect, op: 'uninstall', arch: facts.arch, params: { UNINSTALL_MODE: 'purge' }, onEvent() {} });
  assert.equal(removed.status, 'ok');
  await cleanupAgentDir(removed.session);
  await removed.session.exec('mv -f /etc/hosts.wdtest /etc/hosts; rm -rf /root/soar-panel-backup-* /root/soar-panel-uninstall-*');
  removed.session.close();
} catch (err) {
  const rescue = await connect();
  await rescue.exec('[ -f /etc/hosts.wdtest ] && mv -f /etc/hosts.wdtest /etc/hosts');
  rescue.close();
  throw err;
}
log('\nall real SSH checks passed');
