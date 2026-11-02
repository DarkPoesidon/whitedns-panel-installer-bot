import net from 'node:net';
import { randomInt } from 'node:crypto';

// Limit from the panel's Settings.Validate (internal/panel/store.go).
export const MAX_ZONE_LENGTH = 24;

export function isIPv4(value) {
  return net.isIPv4(String(value ?? ''));
}

export function isPublicIPv4(value) {
  if (!isIPv4(value)) return false;
  const [a, b, c] = value.split('.').map(Number);
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 192 && b === 0 && (c === 0 || c === 2)) return false;
  if (a === 192 && b === 88 && c === 99) return false;
  if (a === 198 && (b === 18 || b === 19)) return false;
  if (a === 198 && b === 51 && c === 100) return false;
  if (a === 203 && b === 0 && c === 113) return false;
  return true;
}

export function isHostname(value) {
  const name = String(value ?? '').toLowerCase();
  return name.length <= 253 && /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(name) && !/^[0-9.]+$/.test(name);
}

export function isSshHost(value) {
  return isIPv4(value) || net.isIPv6(String(value ?? '')) || isHostname(value);
}

export function parsePort(value) {
  const text = String(value ?? '').trim();
  if (!/^[0-9]{1,5}$/.test(text)) return null;
  const port = Number(text);
  return port >= 1 && port <= 65535 ? port : null;
}

export function isSshUser(value) {
  return /^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$/.test(String(value ?? ''));
}

/**
 * Parses the one-line form: host:password, host:port:password or host:port:user:password.
 * The password may itself contain ':'. IPv6 hosts have no one-line form because ':' is the separator.
 * Returns null when the text is not a one-line server spec, { error } when it is but is invalid.
 */
export function parseServerLine(text) {
  const parts = String(text ?? '').trim().split(':');
  if (parts.length < 2 || net.isIPv6(String(text ?? '').trim())) return null;
  const host = parts[0].trim();
  if (!isSshHost(host)) return { error: 'host' };

  if (parts.length === 2) return { host, port: 22, user: 'root', password: parts[1] };

  const port = parsePort(parts[1]);
  if (port === null) {
    // host:pass:word with a default port, because the second field is not a number.
    return { host, port: 22, user: 'root', password: parts.slice(1).join(':') };
  }
  if (parts.length === 3) return { host, port, user: 'root', password: parts[2] };
  if (!isSshUser(parts[2].trim())) return { error: 'user' };
  return { host, port, user: parts[2].trim(), password: parts.slice(3).join(':') };
}

export function isPrivateKey(text) {
  return /^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/.test(String(text ?? '').trim());
}

/** Panel admin password: 12-72 printable ASCII per the panel; the alphabet avoids look-alikes. */
export function generateStrongPassword(length = 20) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  let out = '';
  for (let i = 0; i < length; i += 1) out += alphabet[randomInt(alphabet.length)];
  return out;
}

export function escapeHtml(value) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
