import { MAX_ZONE_LENGTH } from './validate.js';

const CF_API_BASE = 'https://api.cloudflare.com/client/v4';
export const RECORD_COMMENT = 'WhiteDNS Manager';

const TUNNEL_LABELS = ['soar', 's', 't1', 't2'];
const NS_LABELS = ['ns-soar', 'ns-wd', 'ns-wd2'];
const PANEL_LABELS = ['panel', 'wd-panel', 'wd-panel2'];

/**
 * Returns appropriate Cloudflare headers for either:
 * - Scoped API Token (Bearer <TOKEN>)
 * - Global API Key (X-Auth-Email + X-Auth-Key)
 */
export function getAuthHeaders(authInput) {
  const trimmed = (authInput || '').trim();
  if (trimmed.includes(':') && trimmed.includes('@')) {
    const parts = trimmed.split(':');
    return {
      'X-Auth-Email': parts[0].trim(),
      'X-Auth-Key': parts.slice(1).join(':').trim(),
      'Content-Type': 'application/json',
    };
  }
  return { Authorization: `Bearer ${trimmed}`, 'Content-Type': 'application/json' };
}

const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

/** One API call with a timeout, retrying rate limits and transient server errors. */
export async function cfRequest(authInput, path, { method = 'GET', body, fetchImpl = fetch, retryDelayMs = 1000 } = {}) {
  let lastError;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    if (attempt) await sleep(retryDelayMs * 2 ** (attempt - 1));
    let res;
    try {
      res = await fetchImpl(`${CF_API_BASE}${path}`, {
        method,
        headers: getAuthHeaders(authInput),
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(15000),
      });
    } catch (err) {
      lastError = new Error(`خطای شبکه در اتصال به کلودفلر: ${err.message}`);
      continue;
    }
    if (res.status === 429 || res.status >= 500) {
      lastError = new Error(`کلودفلر موقتاً پاسخ نداد (HTTP ${res.status}).`);
      continue;
    }
    let data;
    try {
      data = await res.json();
    } catch {
      throw new Error(`پاسخ نامعتبر از کلودفلر (HTTP ${res.status}).`);
    }
    if (!res.ok || !data.success) {
      const message = data.errors?.[0]?.message || `HTTP ${res.status}`;
      if (res.status === 401 || res.status === 403) {
        throw new Error(`توکن کلودفلر دسترسی لازم را ندارد (Zone:Read و DNS:Edit): ${message}`);
      }
      throw new Error(message);
    }
    return data;
  }
  throw lastError;
}

/**
 * Validates Cloudflare credentials (supports both API Token and Global Key)
 * Automatically falls back to pure Bearer Token if email:token was provided.
 */
export async function verifyToken(authInput, options = {}) {
  const isGlobal = authInput.includes(':') && authInput.includes('@');
  try {
    await cfRequest(authInput, isGlobal ? '/user' : '/user/tokens/verify', options);
    return { ok: true, resolvedAuth: authInput };
  } catch (err) {
    if (!isGlobal) return { ok: false, error: err.message };
  }
  const rawKey = authInput.split(':').slice(1).join(':').trim();
  try {
    await cfRequest(rawKey, '/user/tokens/verify', options);
    return { ok: true, resolvedAuth: rawKey };
  } catch {
    return { ok: false, error: 'کلید یا توکن نامعتبر است. لطفاً دقت فرمایید.' };
  }
}

/** Every active zone; accounts with more than one page of domains are common for resellers. */
export async function listZones(authInput, options = {}) {
  try {
    const zones = [];
    for (let page = 1; ; page += 1) {
      const data = await cfRequest(authInput, `/zones?status=active&per_page=50&page=${page}`, options);
      zones.push(...(data.result || []).map((z) => ({ id: z.id, name: z.name })));
      if (page >= (data.result_info?.total_pages ?? 1)) break;
    }
    return { ok: true, zones };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function recordsNamed(authInput, zoneId, name, options) {
  const data = await cfRequest(authInput, `/zones/${zoneId}/dns_records?name=${encodeURIComponent(name)}&per_page=100`, options);
  return data.result || [];
}

const isOurs = (record) => record.comment === RECORD_COMMENT;

/**
 * Pure planning step. `lookup(name)` returns the records at a name; nothing is written.
 * Occupied names are never overwritten: the first free label is used instead.
 * A record this bot made, or the standard pair of an earlier version, may move after confirmation.
 */
export async function planSoarRecords({ domain, ip, lookup, existingZone = '' }) {
  const clean = domain.toLowerCase().trim();
  const fqdn = (label) => `${label}.${clean}`;

  const nsUsable = (records) => {
    const blocking = records.filter((r) => r.type !== 'A' || r.proxied);
    return blocking.length === 0 && records.length <= 1;
  };

  let ns = null;
  for (const label of NS_LABELS) {
    const records = await lookup(fqdn(label));
    if (!nsUsable(records)) continue;
    const current = records[0];
    if (current && current.content !== ip && !isOurs(current) && !(await delegatesTo(lookup, clean, fqdn(label)))) continue;
    ns = { name: fqdn(label), current };
    break;
  }
  if (!ns) return { ok: false, error: 'NO_FREE_NS_NAME' };

  const tunnelCandidates = existingZone && existingZone.endsWith(`.${clean}`)
    ? [existingZone.slice(0, -clean.length - 1)]
    : TUNNEL_LABELS;
  let tunnel = null;
  let sawLongName = false;
  for (const label of tunnelCandidates) {
    if (fqdn(label).length > MAX_ZONE_LENGTH) {
      sawLongName = true;
      continue;
    }
    const records = await lookup(fqdn(label));
    const usable = records.every((r) => r.type === 'NS' && r.content.toLowerCase() === ns.name);
    if (!usable && !existingZone) continue;
    if (!usable) return { ok: false, error: 'EXISTING_ZONE_CONFLICT', zone: fqdn(label) };
    tunnel = { name: fqdn(label), current: records[0] };
    break;
  }
  if (!tunnel) return { ok: false, error: sawLongName ? 'DOMAIN_TOO_LONG' : 'NO_FREE_TUNNEL_NAME' };

  let panel = null;
  for (const label of PANEL_LABELS) {
    const records = await lookup(fqdn(label));
    const current = records[0];
    const free = records.length === 0 || (records.length === 1 && current.type === 'A' && (current.content === ip || isOurs(current)));
    if (!free) continue;
    panel = { name: fqdn(label), current };
    break;
  }
  if (!panel) return { ok: false, error: 'NO_FREE_PANEL_NAME' };

  const changes = [
    { type: 'A', name: ns.name, content: ip, current: ns.current },
    { type: 'NS', name: tunnel.name, content: ns.name, current: tunnel.current },
    { type: 'A', name: panel.name, content: ip, current: panel.current },
  ].map((change) => ({
    ...change,
    action: !change.current
      ? 'create'
      : change.current.content.toLowerCase() === change.content && !change.current.proxied ? 'keep' : 'update',
  }));

  return {
    ok: true,
    zone: tunnel.name,
    nsHost: ns.name,
    panelDomain: panel.name,
    changes,
    // Moves that repoint a live name; the confirm card must list these.
    moves: changes.filter((c) => c.action === 'update'),
    renamed: tunnel.name !== fqdn('soar') || ns.name !== fqdn('ns-soar') || panel.name !== fqdn('panel'),
  };
}

async function delegatesTo(lookup, domain, nsName) {
  for (const label of TUNNEL_LABELS) {
    const records = await lookup(`${label}.${domain}`);
    if (records.some((r) => r.type === 'NS' && r.content.toLowerCase() === nsName)) return true;
  }
  return false;
}

export function planForZone(authInput, zoneId, domain, ip, existingZone, options = {}) {
  const cache = new Map();
  const lookup = async (name) => {
    if (!cache.has(name)) cache.set(name, await recordsNamed(authInput, zoneId, name, options));
    return cache.get(name);
  };
  return planSoarRecords({ domain, ip, lookup, existingZone });
}

/** Idempotent, so a retry after a partial failure finishes the remaining records. */
export async function applyPlan(authInput, zoneId, plan, options = {}) {
  for (const change of plan.changes) {
    if (change.action === 'keep') continue;
    const body = { type: change.type, name: change.name, content: change.content, ttl: 1, proxied: false, comment: RECORD_COMMENT };
    if (change.type === 'NS') delete body.proxied;
    if (change.action === 'create') {
      await cfRequest(authInput, `/zones/${zoneId}/dns_records`, { ...options, method: 'POST', body });
    } else {
      await cfRequest(authInput, `/zones/${zoneId}/dns_records/${change.current.id}`, { ...options, method: 'PUT', body });
    }
  }
}

/**
 * Deletes only what this bot owns: records carrying our comment, or the given names when
 * they still hold the values of this deployment. A name reused by another service stays.
 */
export async function deleteOwnedRecords(authInput, zoneId, { names, ip, nsHost }, options = {}) {
  let deleted = 0;
  const kept = [];
  for (const name of names) {
    for (const record of await recordsNamed(authInput, zoneId, name, options)) {
      const matches = isOurs(record)
        || (record.type === 'A' && record.content === ip)
        || (record.type === 'NS' && record.content.toLowerCase() === nsHost);
      if (!matches) {
        kept.push(`${record.type} ${record.name}`);
        continue;
      }
      await cfRequest(authInput, `/zones/${zoneId}/dns_records/${record.id}`, { ...options, method: 'DELETE' });
      deleted += 1;
    }
  }
  return { deleted, kept };
}

const wrap = async (fn) => {
  try {
    return { ok: true, ...(await fn()) };
  } catch (err) {
    return { ok: false, error: err.message };
  }
};

/** Retrieves all DNS records for a given zone */
export function listDnsRecords(authInput, zoneId, page = 1, perPage = 100) {
  return wrap(async () => {
    const data = await cfRequest(authInput, `/zones/${zoneId}/dns_records?page=${page}&per_page=${perPage}&order=type`);
    return { records: data.result || [], info: data.result_info || {} };
  });
}

export function getDnsRecord(authInput, zoneId, recordId) {
  return wrap(async () => ({ record: (await cfRequest(authInput, `/zones/${zoneId}/dns_records/${recordId}`)).result }));
}

export function createDnsRecord(authInput, zoneId, { type, name, content, proxied = false, ttl = 1, comment = RECORD_COMMENT }) {
  const body = { type: type.toUpperCase(), name, content, proxied: !!proxied, ttl: Number(ttl) || 1, comment };
  return wrap(async () => ({ record: (await cfRequest(authInput, `/zones/${zoneId}/dns_records`, { method: 'POST', body })).result }));
}

export function updateDnsRecord(authInput, zoneId, recordId, updates) {
  return wrap(async () => ({ record: (await cfRequest(authInput, `/zones/${zoneId}/dns_records/${recordId}`, { method: 'PATCH', body: updates })).result }));
}

export function deleteDnsRecord(authInput, zoneId, recordId) {
  return wrap(async () => ({ result: (await cfRequest(authInput, `/zones/${zoneId}/dns_records/${recordId}`, { method: 'DELETE' })).result }));
}
