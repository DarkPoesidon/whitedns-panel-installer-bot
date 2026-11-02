import test from 'node:test';
import assert from 'node:assert/strict';
import { planSoarRecords, applyPlan, deleteOwnedRecords, listZones, cfRequest, RECORD_COMMENT } from '../src/cloudflare.js';

const IP = '45.33.32.156';
const lookupFrom = (records) => async (name) => records.filter((r) => r.name === name);
const A = (name, content, extra = {}) => ({ id: `id-${name}`, type: 'A', name, content, proxied: false, ...extra });
const NS = (name, content, extra = {}) => ({ id: `id-${name}`, type: 'NS', name, content, ...extra });

test('empty zone gets the standard names', async () => {
  const plan = await planSoarRecords({ domain: 'example.com', ip: IP, lookup: lookupFrom([]) });
  assert.equal(plan.ok, true);
  assert.equal(plan.zone, 'soar.example.com');
  assert.equal(plan.nsHost, 'ns-soar.example.com');
  assert.equal(plan.panelDomain, 'panel.example.com');
  assert.deepEqual(plan.changes.map((c) => c.action), ['create', 'create', 'create']);
  assert.equal(plan.renamed, false);
});

test('existing correct records are kept untouched', async () => {
  const plan = await planSoarRecords({
    domain: 'example.com',
    ip: IP,
    lookup: lookupFrom([A('ns-soar.example.com', IP), NS('soar.example.com', 'ns-soar.example.com'), A('panel.example.com', IP)]),
  });
  assert.deepEqual(plan.changes.map((c) => c.action), ['keep', 'keep', 'keep']);
  assert.equal(plan.moves.length, 0);
});

test('a website on panel.* is never overwritten', async () => {
  const plan = await planSoarRecords({ domain: 'example.com', ip: IP, lookup: lookupFrom([A('panel.example.com', '9.9.9.9')]) });
  assert.equal(plan.panelDomain, 'wd-panel.example.com');
  assert.equal(plan.renamed, true);
  assert.ok(plan.changes.every((c) => c.name !== 'panel.example.com'));
});

test('a CNAME or proxied record on panel.* is treated as occupied', async () => {
  const cname = await planSoarRecords({ domain: 'example.com', ip: IP, lookup: lookupFrom([{ id: 'c', type: 'CNAME', name: 'panel.example.com', content: 'x.example.net' }]) });
  assert.equal(cname.panelDomain, 'wd-panel.example.com');
});

test('another tunnel on soar.* moves ours to a free label', async () => {
  const plan = await planSoarRecords({ domain: 'example.com', ip: IP, lookup: lookupFrom([NS('soar.example.com', 'ns.other.net')]) });
  assert.equal(plan.zone, 's.example.com');
});

test('moving to a new server repoints our own records and lists the move', async () => {
  const plan = await planSoarRecords({
    domain: 'example.com',
    ip: IP,
    lookup: lookupFrom([
      A('ns-soar.example.com', '1.1.1.1'),
      NS('soar.example.com', 'ns-soar.example.com'),
      A('panel.example.com', '1.1.1.1', { comment: RECORD_COMMENT }),
    ]),
  });
  assert.equal(plan.zone, 'soar.example.com');
  assert.equal(plan.panelDomain, 'panel.example.com');
  assert.deepEqual(plan.moves.map((m) => m.name), ['ns-soar.example.com', 'panel.example.com']);
});

test('unrelated ns-soar record with another IP is not hijacked', async () => {
  const plan = await planSoarRecords({ domain: 'example.com', ip: IP, lookup: lookupFrom([A('ns-soar.example.com', '1.1.1.1')]) });
  assert.equal(plan.nsHost, 'ns-wd.example.com');
});

test('long domains use a shorter tunnel label within the panel limit', async () => {
  const domain = 'twenty-chars-long.io';
  const plan = await planSoarRecords({ domain, ip: IP, lookup: lookupFrom([]) });
  assert.equal(plan.zone, `s.${domain}`);
  assert.ok(plan.zone.length <= 24);
});

test('a domain that cannot fit is refused before any write', async () => {
  const plan = await planSoarRecords({ domain: 'this-domain-is-far-too-long.example', ip: IP, lookup: lookupFrom([]) });
  assert.deepEqual(plan, { ok: false, error: 'DOMAIN_TOO_LONG' });
});

test('reinstall reuses the zone already in the panel database', async () => {
  const plan = await planSoarRecords({ domain: 'example.com', ip: IP, existingZone: 't1.example.com', lookup: lookupFrom([NS('t1.example.com', 'ns-soar.example.com')]) });
  assert.equal(plan.zone, 't1.example.com');
});

test('plan for an existing zone with a foreign delegation stops', async () => {
  const plan = await planSoarRecords({ domain: 'example.com', ip: IP, existingZone: 't1.example.com', lookup: lookupFrom([NS('t1.example.com', 'ns.other.net')]) });
  assert.equal(plan.error, 'EXISTING_ZONE_CONFLICT');
});

function fakeFetch(handler = () => undefined) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, method: init.method, body: init.body && JSON.parse(init.body) });
    const { status = 200, json = { success: true, result: [] } } = handler(url, init, calls.length) ?? {};
    return { status, ok: status < 400, json: async () => json };
  };
  return { impl, calls };
}

test('applyPlan creates, updates and skips, and tags records', async () => {
  const { impl, calls } = fakeFetch();
  const plan = {
    changes: [
      { action: 'create', type: 'A', name: 'a.x.io', content: IP },
      { action: 'update', type: 'A', name: 'b.x.io', content: IP, current: { id: 'rec1' } },
      { action: 'keep', type: 'NS', name: 'c.x.io', content: 'a.x.io' },
      { action: 'create', type: 'NS', name: 'd.x.io', content: 'a.x.io' },
    ],
  };
  await applyPlan('tok', 'zone1', plan, { fetchImpl: impl });
  assert.deepEqual(calls.map((c) => c.method), ['POST', 'PUT', 'POST']);
  assert.ok(calls[1].url.endsWith('/dns_records/rec1'));
  assert.equal(calls[0].body.proxied, false);
  assert.equal(calls[0].body.comment, RECORD_COMMENT);
  assert.equal('proxied' in calls[2].body, false);
});

test('deleteOwnedRecords removes only records of this deployment', async () => {
  const records = {
    'panel.x.io': [A('panel.x.io', '9.9.9.9')],
    'ns-soar.x.io': [A('ns-soar.x.io', IP)],
    'soar.x.io': [NS('soar.x.io', 'ns-soar.x.io')],
  };
  const { impl, calls } = fakeFetch((url) => {
    const name = decodeURIComponent(new URL(url).searchParams.get('name') ?? '');
    return name ? { json: { success: true, result: records[name] ?? [] } } : undefined;
  });
  const result = await deleteOwnedRecords('tok', 'z', { names: Object.keys(records), ip: IP, nsHost: 'ns-soar.x.io' }, { fetchImpl: impl });
  assert.equal(result.deleted, 2);
  assert.deepEqual(result.kept, ['A panel.x.io']);
  assert.equal(calls.filter((c) => c.method === 'DELETE').length, 2);
});

test('listZones follows pagination', async () => {
  const { impl } = fakeFetch((url) => {
    const page = Number(new URL(url).searchParams.get('page'));
    return { json: { success: true, result: [{ id: `z${page}`, name: `d${page}.io` }], result_info: { total_pages: 3 } } };
  });
  const res = await listZones('tok', { fetchImpl: impl });
  assert.deepEqual(res.zones.map((z) => z.id), ['z1', 'z2', 'z3']);
});

test('cfRequest retries 429 and 5xx, then succeeds', async () => {
  const { impl, calls } = fakeFetch((_u, _i, n) => (n < 3 ? { status: n === 1 ? 429 : 503, json: {} } : undefined));
  await cfRequest('tok', '/x', { fetchImpl: impl, retryDelayMs: 1 });
  assert.equal(calls.length, 3);
});

test('cfRequest reports missing permission without retrying', async () => {
  const { impl, calls } = fakeFetch(() => ({ status: 403, json: { success: false, errors: [{ message: 'denied' }] } }));
  await assert.rejects(cfRequest('tok', '/x', { fetchImpl: impl, retryDelayMs: 1 }), /DNS:Edit/);
  assert.equal(calls.length, 1);
});
