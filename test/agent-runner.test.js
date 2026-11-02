import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { parseEvent, parseKeyValues, buildJobEnv, runJob, followJob, probe } from '../src/agent.js';
import { RemoteSession, SshError, connectSsh, classifyConnectError, shellQuote } from '../src/ssh.js';

test('parseEvent reads agent lines and ignores noise', () => {
  assert.deepEqual(parseEvent('@@ https warn CERT_FAILED rate limited for now'), { stage: 'https', status: 'warn', code: 'CERT_FAILED', detail: 'rate limited for now' });
  assert.deepEqual(parseEvent('@@ deps start -  '), { stage: 'deps', status: 'start', code: '', detail: '' });
  assert.equal(parseEvent('Hit:1 http://archive.ubuntu.com'), null);
});

test('parseKeyValues collects repeated warnings and keeps = in values', () => {
  const out = parseKeyValues('status=ok\npanel_url=https://x/?a=b\nwarning=A\nwarning=B\nlocal_ip=1.1.1.1\nbad line\n');
  assert.equal(out.status, 'ok');
  assert.equal(out.panel_url, 'https://x/?a=b');
  assert.deepEqual(out.warnings, ['A', 'B']);
  assert.deepEqual(out.localIps, ['1.1.1.1']);
});

test('buildJobEnv rejects unknown keys and newline injection', () => {
  assert.equal(buildJobEnv({ ZONE: 'a.b', PANEL_DOMAIN: '' }), 'ZONE=a.b\n');
  assert.throws(() => buildJobEnv({ EVIL: '1' }), /unknown job key/);
  assert.throws(() => buildJobEnv({ ZONE: 'a\nFAULT=activate' }), /invalid value/);
});

test('shellQuote survives quotes', () => {
  assert.equal(shellQuote("a'b"), `'a'\\''b'`);
});

/** A scripted session recording every command, so tests can assert what reaches the server. */
function fakeSession({ results = [{ status: 'ok' }], active = false, logs = [] } = {}) {
  const calls = [];
  const writes = [];
  let tails = 0;
  return {
    calls,
    writes,
    close() {},
    async writeFile(path, content) { writes.push({ path, content }); },
    async exec(command, { onData, stdin } = {}) {
      calls.push({ command, stdin });
      if (command.includes('is-active --quiet whitedns-agent; echo')) return { code: 0, stdout: active ? '0\n' : '3\n', stderr: '' };
      if (command.startsWith('tail ')) {
        const chunk = logs[tails];
        tails += 1;
        if (chunk instanceof Error) throw chunk;
        if (chunk) onData(Buffer.from(chunk));
        return { code: 0, stdout: '', stderr: '' };
      }
      if (command.startsWith('cat ')) {
        const result = results.shift() ?? {};
        return { code: 0, stdout: Object.entries(result).map(([k, v]) => `${k}=${v}`).join('\n'), stderr: '' };
      }
      return { code: 0, stdout: '', stderr: '' };
    },
  };
}

test('runJob never puts the admin password on a command line', async () => {
  const session = fakeSession();
  await runJob({ session, connect: async () => session, op: 'install', params: { ZONE: 'a.b' }, secret: 'SuperSecretPass', arch: 'amd64', onEvent() {} });
  assert.equal(session.calls.some((c) => c.command.includes('SuperSecretPass')), false);
  assert.deepEqual(session.writes.find((w) => w.path.endsWith('admin.secret')).content, 'SuperSecretPass');
  assert.equal(session.writes.find((w) => w.path.endsWith('job.env')).content.includes('SuperSecretPass'), false);
});

test('runJob attaches to a running job without overwriting its files', async () => {
  const session = fakeSession({ active: true });
  const out = await runJob({ session, connect: async () => session, op: 'install', params: {}, onEvent() {} });
  assert.equal(out.attached, true);
  assert.equal(session.writes.length, 0);
  assert.equal(session.calls.some((c) => c.command.includes('systemd-run')), false);
});

test('attachOnly never starts a job, even when none is running', async () => {
  const session = fakeSession({ active: false });
  const out = await runJob({ session, connect: async () => session, op: 'uninstall', params: { UNINSTALL_MODE: 'purge' }, attachOnly: true, onEvent() {} });
  assert.equal(out.attached, true);
  assert.equal(session.calls.some((c) => c.command.includes('systemd-run')), false);
  assert.equal(session.writes.length, 0);
});

test('a job that fails to start leaves no password on the server', async () => {
  const session = fakeSession();
  const realExec = session.exec;
  session.exec = async (command, options) => {
    if (command.includes('systemd-run')) return { code: 1, stdout: '', stderr: 'no systemd' };
    return realExec(command, options);
  };
  await assert.rejects(
    runJob({ session, connect: async () => session, op: 'install', params: {}, secret: 'pw', onEvent() {} }),
    (err) => err.code === 'JOB_START_FAILED',
  );
  assert.ok(session.calls.some((c) => c.command.includes('rm -f') && c.command.includes('admin.secret')));
});

test('NEED_BUNDLE uploads the release and runs again', async () => {
  const session = fakeSession({ results: [{ status: 'failed', code: 'NEED_BUNDLE' }, { status: 'ok' }] });
  const out = await runJob({
    session, connect: async () => session, op: 'install', params: {}, secret: 's', arch: 'amd64', onEvent() {},
    download: async () => Buffer.from('tarball'),
  });
  assert.equal(out.status, 'ok');
  assert.ok(session.writes.some((w) => w.path.endsWith('bundle.tar.gz')));
  assert.equal(session.calls.filter((c) => c.command.includes('systemd-run')).length, 2);
});

test('a second NEED_BUNDLE is returned instead of looping', async () => {
  const session = fakeSession({ results: [{ status: 'failed', code: 'NEED_BUNDLE' }, { status: 'failed', code: 'NEED_BUNDLE' }] });
  const out = await runJob({ session, connect: async () => session, op: 'install', params: {}, arch: 'amd64', onEvent() {}, download: async () => Buffer.alloc(1) });
  assert.equal(out.code, 'NEED_BUNDLE');
});

test('followJob resumes from the last complete line after SSH drops', async () => {
  const events = [];
  const first = fakeSession({ logs: ['@@ deps ok -\n@@ fetch st', new SshError('CHANNEL_CLOSED')] });
  first.exec = (orig => async (command, opts) => {
    if (command.startsWith('tail ')) {
      opts.onData(Buffer.from('@@ deps ok -\n@@ fetch st'));
      throw new SshError('CHANNEL_CLOSED');
    }
    return orig(command, opts);
  })(first.exec);
  const second = fakeSession({ logs: ['@@ fetch start -\n@@ verify ok -\n'], results: [{ status: 'ok' }] });
  const out = await followJob({ session: first, connect: async () => second, onEvent: (e) => events.push(e.stage), retryDelayMs: 1 });
  assert.deepEqual(events, ['deps', 'fetch', 'verify']);
  assert.equal(out.result.status, 'ok');
  const tail = second.calls.find((c) => c.command.startsWith('tail ')).command;
  assert.match(tail, /tail -c \+14 /);
});

test('followJob gives up when the server stays unreachable', async () => {
  const session = fakeSession({ logs: [new SshError('CHANNEL_CLOSED')] });
  await assert.rejects(
    followJob({ session, connect: async () => { throw new SshError('TIMEOUT'); }, onEvent() {}, retryDelayMs: 1, reconnectWindowMs: 5 }),
    (err) => err.code === 'LOST_CONNECTION',
  );
});

test('followJob stops retrying when the credentials are refused', async () => {
  const session = fakeSession({ logs: [new SshError('CHANNEL_CLOSED')] });
  await assert.rejects(
    followJob({ session, connect: async () => { throw new SshError('AUTH_FAILED'); }, onEvent() {}, retryDelayMs: 1 }),
    (err) => err.code === 'AUTH_FAILED',
  );
});

test('probe pipes the script on stdin and quotes the host', async () => {
  const session = fakeSession();
  session.exec = async (command, { stdin }) => {
    session.calls.push({ command, stdin });
    return { code: 0, stdout: 'arch=amd64\ninstalled=0\n', stderr: '' };
  };
  const facts = await probe(session, "1.2.3.4'; rm -rf /");
  assert.equal(facts.arch, 'amd64');
  assert.ok(session.calls[0].command.includes(`'1.2.3.4'\\''; rm -rf /'`));
  assert.match(session.calls[0].stdin, /^#!\/usr\/bin\/env bash/);
});

function fakeConn() {
  const conn = new EventEmitter();
  conn.execCalls = [];
  conn.exec = (command, cb) => {
    conn.execCalls.push(command);
    const stream = new EventEmitter();
    stream.stderr = new EventEmitter();
    stream.written = '';
    stream.write = (data) => { stream.written += data; };
    stream.end = (data) => {
      if (data) stream.written += data;
      conn.lastStream = stream;
      queueMicrotask(() => {
        if (conn.stderrText) stream.stderr.emit('data', Buffer.from(conn.stderrText));
        stream.emit('close', conn.exitCode ?? 0);
      });
    };
    stream.close = () => {};
    cb(null, stream);
  };
  conn.end = () => {};
  return conn;
}

test('sudo password goes to stdin, before the payload, never on the command line', async () => {
  const conn = fakeConn();
  const session = new RemoteSession(conn, { user: 'ubuntu', password: 'P@ss' });
  await session.exec('cat > /x', { stdin: 'payload' });
  assert.match(conn.execCalls[0], /^sudo -S -p ''/);
  assert.equal(conn.execCalls[0].includes('P@ss'), false);
  assert.equal(conn.lastStream.written, 'P@ss\npayload');
});

test('key login uses sudo -n and root runs without sudo', async () => {
  const conn = fakeConn();
  await new RemoteSession(conn, { user: 'ubuntu' }).exec('id');
  assert.match(conn.execCalls[0], /^sudo -n /);
  await new RemoteSession(conn, { user: 'root', password: 'x' }).exec('id');
  assert.match(conn.execCalls[1], /^bash -c /);
});

test('sudo refusal becomes a specific error', async () => {
  const conn = fakeConn();
  conn.exitCode = 1;
  conn.stderrText = 'sudo: a terminal is required to read the password\n';
  await assert.rejects(new RemoteSession(conn, { user: 'ubuntu', password: 'x' }).exec('id'), (err) => err.code === 'SUDO_FAILED');
});

test('connect errors map to stable codes', () => {
  assert.equal(classifyConnectError({ level: 'client-authentication', message: 'x' }).code, 'AUTH_FAILED');
  assert.equal(classifyConnectError({ code: 'ECONNREFUSED', message: 'x' }).code, 'REFUSED');
  assert.equal(classifyConnectError({ code: 'ETIMEDOUT', message: 'x' }).code, 'TIMEOUT');
  assert.equal(classifyConnectError({ code: 'ENOTFOUND', message: 'x' }).code, 'DNS');
});

function fakeClient({ key, ready = true }) {
  return class extends EventEmitter {
    connect(options) {
      this.options = options;
      queueMicrotask(() => {
        const accepted = options.hostVerifier(Buffer.from(key));
        if (!accepted) {
          this.emit('error', Object.assign(new Error('host denied'), { level: 'handshake' }));
          return;
        }
        if (ready) this.emit('ready');
      });
    }
    end() {}
  };
}

test('first contact records the host key fingerprint', async () => {
  const session = await connectSsh({ host: 'h', password: 'p', ClientImpl: fakeClient({ key: 'k1' }) });
  assert.equal(typeof session.fingerprint, 'string');
  assert.ok(session.fingerprint.length > 20);
});

test('a changed host key is refused before login', async () => {
  const session = await connectSsh({ host: 'h', password: 'p', ClientImpl: fakeClient({ key: 'k1' }) });
  await assert.rejects(
    connectSsh({ host: 'h', password: 'p', expectedFingerprint: session.fingerprint, ClientImpl: fakeClient({ key: 'k2' }) }),
    (err) => err.code === 'HOST_KEY_CHANGED',
  );
});
