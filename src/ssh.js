import { createHash } from 'node:crypto';
import { Client } from 'ssh2';

export class SshError extends Error {
  constructor(code, message = code) {
    super(message);
    this.code = code;
  }
}

export const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;

export function classifyConnectError(err) {
  if (err.level === 'client-authentication') return new SshError('AUTH_FAILED', err.message);
  if (err.code === 'ECONNREFUSED') return new SshError('REFUSED', err.message);
  if (err.code === 'ETIMEDOUT' || err.level === 'client-timeout' || /timed out/i.test(err.message)) return new SshError('TIMEOUT', err.message);
  if (err.code === 'ENOTFOUND' || err.code === 'EAI_AGAIN') return new SshError('DNS', err.message);
  if (err.code === 'EHOSTUNREACH' || err.code === 'ENETUNREACH') return new SshError('UNREACHABLE', err.message);
  if (/encrypted private ot|passphrase|Cannot parse privateKey/i.test(err.message)) return new SshError('BAD_KEY', err.message);
  return new SshError('CONNECT_FAILED', err.message);
}

const SUDO_FAILURE = /(a terminal is required|a password is required|incorrect password|is not in the sudoers|may not run sudo|sudo: command not found|sudo: .*: command not found)/i;

/** Runs commands as root over one connection. Passwords only ever travel on stdin. */
export class RemoteSession {
  constructor(conn, { user, password, fingerprint }) {
    this.conn = conn;
    this.user = user;
    this.password = password;
    this.fingerprint = fingerprint;
  }

  /** Wraps a command so it runs as root, returning the command and any stdin prefix sudo consumes. */
  rootCommand(command) {
    if (this.user === 'root') return { command: `bash -c ${shellQuote(command)}`, prefix: '' };
    if (this.password) return { command: `sudo -S -p '' bash -c ${shellQuote(command)}`, prefix: `${this.password}\n` };
    return { command: `sudo -n bash -c ${shellQuote(command)}`, prefix: '' };
  }

  exec(rawCommand, { stdin, timeoutMs = 60000, onData } = {}) {
    const { command, prefix } = this.rootCommand(rawCommand);
    return new Promise((resolve, reject) => {
      this.conn.exec(command, (err, stream) => {
        if (err) {
          reject(new SshError('EXEC_FAILED', err.message));
          return;
        }
        let stdout = '';
        let stderr = '';
        const timer = setTimeout(() => {
          stream.close();
          reject(new SshError('COMMAND_TIMEOUT', rawCommand.slice(0, 80)));
        }, timeoutMs);
        stream.on('data', (chunk) => {
          if (onData) onData(chunk);
          else stdout += chunk.toString('utf8');
        });
        stream.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
        stream.on('close', (code, signal) => {
          clearTimeout(timer);
          if (code !== 0 && this.user !== 'root' && SUDO_FAILURE.test(stderr)) {
            reject(new SshError('SUDO_FAILED', stderr.trim().split('\n').pop()));
            return;
          }
          // A null code with no signal means the channel died, not that the command finished.
          if (code === null || code === undefined) {
            reject(new SshError('CHANNEL_CLOSED', `signal ${signal ?? 'none'}`));
            return;
          }
          resolve({ code, stdout, stderr });
        });
        if (prefix) stream.write(prefix);
        if (stdin === undefined) stream.end();
        else stream.end(stdin);
      });
    });
  }

  /** Writes content to a private file as root. */
  writeFile(path, content) {
    return this.exec(`umask 077; cat > ${shellQuote(path)}`, { stdin: content, timeoutMs: 180000 });
  }

  close() {
    this.conn.end();
  }
}

/**
 * Connects and pins the host key. `expectedFingerprint` null means first contact (trust on first use).
 * A changed key aborts before any credential or command is sent over the session.
 */
export function connectSsh({ host, port = 22, user = 'root', password, privateKey, passphrase, expectedFingerprint = null, ClientImpl = Client }) {
  return new Promise((resolve, reject) => {
    const conn = new ClientImpl();
    let fingerprint = null;
    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      fn(value);
    };

    conn.on('ready', () => settle(resolve, new RemoteSession(conn, { user, password, fingerprint })));
    conn.on('error', (err) => {
      if (fingerprint && expectedFingerprint && fingerprint !== expectedFingerprint) {
        settle(reject, Object.assign(new SshError('HOST_KEY_CHANGED'), { fingerprint }));
      } else {
        settle(reject, classifyConnectError(err));
      }
    });
    conn.on('keyboard-interactive', (_name, _instructions, _lang, prompts, finish) => {
      finish(prompts.map(() => password ?? ''));
    });

    try {
      conn.connect({
        host,
        port: Number(port),
        username: user,
        ...(privateKey ? { privateKey, passphrase } : { password }),
        tryKeyboard: !privateKey,
        readyTimeout: 25000,
        keepaliveInterval: 15000,
        keepaliveCountMax: 4,
        hostVerifier: (key) => {
          fingerprint = createHash('sha256').update(key).digest('base64');
          return !expectedFingerprint || fingerprint === expectedFingerprint;
        },
      });
    } catch (err) {
      settle(reject, classifyConnectError(err));
    }
  });
}
