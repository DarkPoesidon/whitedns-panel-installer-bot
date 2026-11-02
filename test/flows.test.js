import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Telegram } from 'telegraf';
import { createApp } from '../src/app.js';
import { throttled } from '../src/flows/common.js';
import { createStore } from '../src/db.js';
import { createVault } from '../src/vault.js';
import { SshError } from '../src/ssh.js';

const CHAT = 111;
const FACTS = {
  arch: 'amd64', os: 'ubuntu 24.04', os_supported: '1', systemd: '1', disk_mb: '9000', listen_ip: '1.2.3.4',
  public_ip: '1.2.3.4', port53: '', port80: '', port443: '', installed: '0', zone: '', panel_active: '0', old_soar: '0', job_active: '0',
};
const PLAN = {
  ok: true, zone: 'soar.x.io', nsHost: 'ns-soar.x.io', panelDomain: 'panel.x.io', renamed: false, moves: [],
  changes: [{ type: 'A', name: 'ns-soar.x.io', content: '1.2.3.4', action: 'create' }],
};
const OK_RESULT = { status: 'ok', panel_url: 'https://panel.x.io/secretpath/', https: 'true', version: '0.14.0', admin_changed: '1', warnings: [], backup: '/root/b' };

function harness({ facts = FACTS, plan = PLAN, job = OK_RESULT, connectError, adminIds = new Set() } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wdns-flow-'));
  const dbFile = path.join(dir, 'data.db');
  const store = createStore(dbFile);
  const vault = createVault();
  const calls = { apply: [], job: [], connect: [], deleteRecords: [] };
  const sent = [];
  let nextId = 1000;

  const session = { fingerprint: 'FP', close() {} };
  const deps = {
    connectSsh: async (opts) => {
      calls.connect.push(opts);
      if (connectError) throw connectError;
      return session;
    },
    probe: async () => facts,
    runJob: async (args) => {
      calls.job.push(args);
      args.onEvent({ stage: 'deps', status: 'start' });
      return { ...job, session };
    },
    cleanupAgentDir: async () => {},
    cf: {
      verifyToken: async (auth) => (auth.includes('bad') ? { ok: false, error: 'bad token' } : { ok: true, resolvedAuth: auth }),
      listZones: async () => ({ ok: true, zones: [{ id: 'zone1', name: 'x.io' }] }),
      planForZone: async () => plan,
      applyPlan: async (...args) => { calls.apply.push(args); },
      deleteOwnedRecords: async (...args) => { calls.deleteRecords.push(args); return { deleted: 3, kept: [] }; },
      listDnsRecords: async () => ({ ok: true, records: [{ id: 'r1', type: 'A', name: 'a.x.io', content: '1.1.1.1', proxied: false }] }),
      createDnsRecord: async () => ({ ok: true }),
      updateDnsRecord: async () => ({ ok: true }),
      deleteDnsRecord: async () => ({ ok: true }),
    },
  };
  const requestFile = path.join(dir, 'update-request');
  const statusFile = path.join(dir, 'update-status');
  const reportedFile = path.join(dir, 'update-reported');
  const app = createApp({ token: '1:test', store, vault, deps, adminIds, requestFile, statusFile, reportedFile, pollMs: 1 });
  app.bot.botInfo = { id: 1, is_bot: true, first_name: 'b', username: 'b_bot' };
  // handleUpdate builds a new Telegram client per update, so the stub goes on the prototype.
  Telegram.prototype.callApi = async (method, payload) => {
    sent.push({ method, payload });
    return { message_id: (nextId += 1), ok: true };
  };

  let update = 0;
  const chat = { id: CHAT, type: 'private' };
  const from = { id: CHAT, is_bot: false, first_name: 'u' };
  const handle = async (body) => {
    update += 1;
    await app.bot.handleUpdate({ update_id: update, ...body });
    await app.tasks.idle();
  };
  return {
    app, store, vault, deps, calls, sent, dbFile, requestFile, statusFile,
    text: (text) => handle({ message: { message_id: (nextId += 1), date: 0, chat, from, text, ...(text.startsWith('/') ? { entities: [{ type: 'bot_command', offset: 0, length: text.split(' ')[0].length }] } : {}) } }),
    press: (data) => handle({ callback_query: { id: 'q', from, chat_instance: 'x', data, message: { message_id: 500, date: 0, chat, from, text: 'x' } } }),
    group: (text) => handle({ message: { message_id: 1, date: 0, chat: { id: -5, type: 'group', title: 'g' }, from, text, entities: [{ type: 'bot_command', offset: 0, length: text.length }] } }),
    last: () => [...sent].reverse().find((m) => m.method === 'sendMessage' || m.method === 'editMessageText')?.payload,
    allText: () => sent.map((m) => m.payload?.text ?? '').join('\n'),
    buttons: () => [...sent].reverse().find((m) => m.payload?.reply_markup?.inline_keyboard)?.payload.reply_markup.inline_keyboard.flat(),
  };
}

async function reachConfirm(h, { password = 'S3cretPassw0rd' } = {}) {
  await h.text('/start');
  await h.press('terms_accept');
  await h.text('me@gmail.com');
  await h.text('cf-token-value-123');
  await h.press('zone:0');
  await h.text(`1.2.3.4:22:root:${password}`);
}

test('full install: DNS changes only after confirmation, then a real result', async () => {
  const h = harness();
  await reachConfirm(h);
  assert.equal(h.calls.apply.length, 0, 'nothing written before the confirm button');
  assert.equal(h.calls.job.length, 0);
  assert.match(h.last().text, /خلاصهٔ پیکربندی/);

  await h.press('deploy');
  assert.equal(h.calls.apply.length, 1);
  const job = h.calls.job[0];
  assert.equal(job.op, 'install');
  assert.equal(job.params.ZONE, 'soar.x.io');
  assert.equal(job.params.VERSION, '0.14.0');
  assert.match(job.params.BUNDLE_SHA256, /^[a-f0-9]{64}$/);
  assert.ok(job.secret.length >= 12);
  assert.match(h.last().text, /secretpath/);
  assert.ok(h.last().text.includes(job.secret), 'the generated password is shown once');
  assert.equal(h.store.listDeployments(CHAT).length, 1);
});

test('secrets never reach the database and are wiped after success', async () => {
  const password = 'UniqueRootPasswordXYZ';
  const h = harness();
  await reachConfirm(h, { password });
  await h.press('deploy');
  const adminPass = h.calls.job[0].secret;
  assert.equal(h.vault.get(CHAT, 'password'), undefined);
  assert.equal(h.vault.get(CHAT, 'cfAuth'), undefined);
  h.store.close();
  for (const name of fs.readdirSync(path.dirname(h.dbFile))) {
    const raw = fs.readFileSync(path.join(path.dirname(h.dbFile), name)).toString('latin1');
    for (const secret of [password, 'cf-token-value-123', adminPass]) {
      assert.equal(raw.includes(secret), false, `secret found in ${name}`);
    }
  }
});

test('messages carrying secrets are deleted', async () => {
  const h = harness();
  await reachConfirm(h);
  const deletions = h.sent.filter((m) => m.method === 'deleteMessage').length;
  assert.ok(deletions >= 2, `expected token and password deletions, got ${deletions}`);
});

test('an unsupported server is refused before Cloudflare is touched', async () => {
  const h = harness({ facts: { ...FACTS, os_supported: '0', os: 'centos 9' } });
  await reachConfirm(h);
  assert.match(h.last().text, /نصب روی این سرور ممکن نیست/);
  assert.equal(h.calls.apply.length, 0);
});

test('port 53 held by another service stops the flow and names it', async () => {
  const h = harness({ facts: { ...FACTS, port53: 'named' } });
  await reachConfirm(h);
  assert.match(h.last().text, /named/);
  assert.equal(h.buttons().some((b) => b.callback_data === 'deploy'), false);
});

test('a private SSH target is refused before any login attempt', async () => {
  const h = harness();
  await h.text('/start');
  await h.press('terms_accept');
  await h.text('cf-token-value-with-more-than-thirty-five-characters');
  await h.press('zone:0');
  await h.text('127.0.0.1:22:root:guess');
  assert.match(h.last().text, /عمومی نیست/);
  assert.equal(h.calls.connect.length, 0);
});

test('an eleventh SSH attempt in the window is refused', async () => {
  const h = harness();
  await reachConfirm(h);
  for (let i = 0; i < 9; i += 1) await h.press('retry:prepare');
  assert.equal(h.calls.connect.length, 10);
  await h.press('retry:prepare');
  assert.equal(h.calls.connect.length, 10);
  assert.match(h.last().text, /تلاش‌های اتصال زیاد/);
});

test('a domain too long for the panel is refused with an explanation', async () => {
  const h = harness({ plan: { ok: false, error: 'DOMAIN_TOO_LONG' } });
  await reachConfirm(h);
  assert.match(h.last().text, /۲۴ کاراکتر/);
});

test('reinstall keeps the admin password unless a reset is requested', async () => {
  const facts = { ...FACTS, installed: '1', zone: 'soar.x.io' };
  const keep = harness({ facts, job: { ...OK_RESULT, admin_changed: '0' } });
  await reachConfirm(keep);
  await keep.press('deploy');
  assert.equal(keep.calls.job[0].secret, null);
  assert.equal(keep.calls.job[0].params.RESET_ADMIN, '0');
  assert.match(keep.last().text, /رمز ادمین تغییر نکرد/);

  const reset = harness({ facts });
  await reachConfirm(reset);
  await reset.press('deploy:reset');
  assert.ok(reset.calls.job[0].secret);
  assert.equal(reset.calls.job[0].params.RESET_ADMIN, '1');
});

test('a panel from another domain asks before replacing it', async () => {
  const h = harness({ facts: { ...FACTS, installed: '1', zone: 'soar.other.net' } });
  await reachConfirm(h);
  assert.match(h.last().text, /دامنهٔ دیگری/);
  assert.equal(h.buttons().some((b) => b.callback_data === 'deploy'), false);
  await h.press('zone_replace');
  await h.press('deploy');
  assert.equal(h.calls.job[0].params.ON_ZONE_MISMATCH, 'replace');
  assert.ok(h.calls.job[0].secret, 'a fresh database needs a password');
});

test('a running standalone soar server requires its migration warning', async () => {
  const h = harness({ facts: { ...FACTS, old_soar: '1' } });
  await reachConfirm(h);
  assert.match(h.last().text, /soar-server/);
  await h.press('deploy');
  assert.equal(h.calls.job[0].params.ALLOW_MIGRATE, '1');
});

test('wrong SSH password gives a specific error and keeps retry', async () => {
  const h = harness({ connectError: new SshError('AUTH_FAILED', 'denied') });
  await reachConfirm(h);
  assert.match(h.last().text, /اشتباه است/);
  assert.equal(h.buttons().some((b) => b.callback_data === 'back:ssh_ip'), true);
});

test('a changed host key blocks the login until accepted', async () => {
  const error = Object.assign(new SshError('HOST_KEY_CHANGED'), { fingerprint: 'NEWFP' });
  const h = harness({ connectError: error });
  await reachConfirm(h);
  assert.match(h.last().text, /تغییر کرده/);
  assert.match(h.last().text, /NEWFP/);
  await h.press('hostkey:accept');
  assert.equal(h.store.getKnownHost('1.2.3.4', 22), 'NEWFP');
});

test('rollback is reported as such', async () => {
  const h = harness({ job: { status: 'rolled_back', code: 'PANEL_UNHEALTHY', detail: 'x', warnings: [] } });
  await reachConfirm(h);
  await h.press('deploy');
  assert.match(h.last().text, /به حالت قبل/);
  assert.equal(h.store.listDeployments(CHAT).length, 0);
  assert.equal(h.buttons().some((b) => b.callback_data === 'retry:prepare'), true);
});

test('an unverified install is not presented as a clean success', async () => {
  const h = harness({ job: { ...OK_RESULT, https: 'false', panel_bind: '127.0.0.1:2053', panel_url: 'http://127.0.0.1:2053/p/', warnings: ['TUNNEL_RECURSIVE_FAILED', 'CERT_FAILED'] } });
  await reachConfirm(h);
  await h.press('deploy');
  const { text } = h.last();
  assert.match(text, /همهٔ آزمایش‌ها موفق نبودند/);
  assert.match(text, /UDP\/53/);
  assert.match(text, /ssh -N -L 2053:127\.0\.0\.1:2053 root@1\.2\.3\.4/);
});

test('the server error behind a warning reaches the user, escaped', async () => {
  const h = harness({ job: { ...OK_RESULT, warnings: ['CERT_FAILED'], warning_detail_CERT_FAILED: 'acme: <rateLimited>' } });
  await reachConfirm(h);
  await h.press('deploy');
  assert.match(h.last().text, /acme: &lt;rateLimited&gt;/);
});

test('a stalled certificate order is explained and is not shown as a clean install', async () => {
  const h = harness({ job: { ...OK_RESULT, https: 'false', panel_bind: '127.0.0.1:2053', warnings: ['CERT_STALLED'], warning_detail_CERT_STALLED: 'context deadline exceeded' } });
  await reachConfirm(h);
  await h.press('deploy');
  const { text } = h.last();
  assert.match(text, /همهٔ آزمایش‌ها موفق نبودند/);
  assert.match(text, /Let's Encrypt/);
  assert.match(text, /context deadline exceeded/);
});

test('double click runs one install', async () => {
  const h = harness();
  await reachConfirm(h);
  h.app.tasks.tryLock('1.2.3.4');
  await h.press('deploy');
  assert.equal(h.calls.job.length, 0);
  assert.match(h.last().text, /در حال اجراست/);
});

test('deploy after the vault expired asks to start again', async () => {
  const h = harness();
  await reachConfirm(h);
  h.vault.clear(CHAT);
  await h.press('deploy');
  assert.equal(h.calls.job.length, 0);
  assert.match(h.last().text, /منقضی/);
});

test('zone buttons stay within the 64 byte callback limit', async () => {
  const h = harness();
  await h.text('/start');
  await h.press('terms_accept');
  await h.text('cf-token-value-with-more-than-thirty-five-characters');
  for (const b of h.buttons()) {
    if (b.callback_data) assert.ok(Buffer.byteLength(b.callback_data) <= 64, b.callback_data);
  }
});

test('repair flow on a registered server keeps its domain', async () => {
  const h = harness({ facts: { ...FACTS, installed: '1', zone: 'soar.x.io', panel_active: '0' }, job: { ...OK_RESULT, admin_changed: '0' } });
  const id = h.store.upsertDeployment({ chatId: CHAT, domain: 'x.io', vpsIp: '1.2.3.4', panelUrl: 'https://panel.x.io/p/', sshPort: 2222, sshUser: 'ubuntu', panelDomain: 'panel.x.io' });
  await h.text('/repair');
  await h.press(`maint:repair:${id}`);
  await h.text('rootpassword');
  assert.equal(h.calls.connect[0].port, 2222);
  assert.equal(h.calls.connect[0].user, 'ubuntu');
  assert.match(h.last().text, /آمادهٔ تعمیر/);
  await h.press('maint_go:repair');
  assert.equal(h.calls.job[0].op, 'repair');
  assert.equal(h.calls.job[0].params.PANEL_DOMAIN, 'panel.x.io');
  assert.equal(h.calls.job[0].secret, null);
  assert.equal(h.store.listDeployments(CHAT)[0].panel_url, OK_RESULT.panel_url);
});

test('repair on a server with no panel offers install instead', async () => {
  const h = harness();
  await h.text('/repair');
  await h.text('1.2.3.4:root-password');
  assert.match(h.last().text, /نصب نیست/);
  assert.equal(h.calls.job.length, 0);
});

test('a job still running is followed instead of restarted', async () => {
  const h = harness({ facts: { ...FACTS, installed: '1', job_active: '1' } });
  await h.text('/repair');
  await h.text('1.2.3.4:root-password');
  assert.match(h.last().text, /در حال اجراست/);
  assert.equal(h.buttons().some((b) => b.callback_data === 'maint_go:attach'), true);
});

test('following an install from the uninstall menu deletes nothing', async () => {
  const h = harness({ facts: { ...FACTS, installed: '1', job_active: '1' }, job: { ...OK_RESULT, op: 'install', attached: true } });
  const id = h.store.upsertDeployment({ chatId: CHAT, domain: 'x.io', vpsIp: '1.2.3.4', zone: 'soar.x.io', nsHost: 'ns-soar.x.io', panelDomain: 'panel.x.io', zoneId: 'zone1' });
  h.vault.set(CHAT, { cfAuth: 'tok' });
  await h.text('/uninstall');
  await h.press(`maint:uninstall:${id}`);
  await h.text('rootpassword');
  await h.press('maint_go:attach');
  assert.equal(h.calls.job[0].attachOnly, true);
  assert.equal(h.calls.deleteRecords.length, 0);
  assert.equal(h.store.listDeployments(CHAT).length, 1);
  assert.doesNotMatch(h.last().text, /حذف شد/);
});

test('install stops when another job runs, so no wrong password can be shown', async () => {
  const h = harness({ facts: { ...FACTS, job_active: '1' } });
  await reachConfirm(h);
  assert.match(h.last().text, /در حال اجراست/);
  assert.equal(h.buttons().some((b) => b.callback_data === 'deploy'), false);
  assert.equal(h.calls.apply.length, 0);
});

test('a job that was only followed never shows a freshly generated password', async () => {
  const h = harness({ job: { ...OK_RESULT, admin_changed: '1', attached: true } });
  await reachConfirm(h);
  await h.press('deploy');
  assert.equal(h.last().text.includes(h.calls.job[0].secret), false);
  assert.match(h.last().text, /رمز جدید بگیرید/);
});

test('repair does not treat a loopback URL as the panel domain', async () => {
  const h = harness({ facts: { ...FACTS, installed: '1', zone: 'soar.x.io' } });
  const id = h.store.upsertDeployment({ chatId: CHAT, domain: 'x.io', vpsIp: '1.2.3.4', panelUrl: 'http://127.0.0.1:2053/p/' });
  await h.text('/repair');
  await h.press(`maint:repair:${id}`);
  await h.text('rootpassword');
  await h.press('maint_go:repair');
  assert.equal(h.calls.job[0].params.PANEL_DOMAIN, '');
});

test('accounts with many domains can reach all of them in the DNS manager', async () => {
  const h = harness();
  const many = Array.from({ length: 45 }, (_, i) => ({ id: `z${i}`, name: `d${i}.io` }));
  h.deps.cf.listZones = async () => ({ ok: true, zones: many });
  await h.text('/dns');
  await h.text('cf-token-for-dns');
  await h.press('cf_zones:5');
  assert.ok(h.buttons().some((b) => b.text.includes('d44.io')));
  await h.press('cf_zone:44');
  assert.equal(h.store.getSession(CHAT).zoneId, 'z44');
});

test('a late progress edit cannot overwrite the result', async () => {
  const order = [];
  let release;
  const edits = throttled(() => new Promise((resolve) => { release = () => { order.push('progress'); resolve(); }; }), 0);
  edits.push('a');
  await new Promise((resolve) => { setTimeout(resolve, 5); });
  const finished = edits.finish().then(() => order.push('result'));
  release();
  await finished;
  assert.deepEqual(order, ['progress', 'result']);
});

test('uninstall asks keep or purge, then removes the record', async () => {
  const h = harness({ facts: { ...FACTS, installed: '1', zone: 'soar.x.io' }, job: { status: 'ok', op: 'uninstall', backup: '/root/u', warnings: [] } });
  const id = h.store.upsertDeployment({ chatId: CHAT, domain: 'x.io', vpsIp: '1.2.3.4', zone: 'soar.x.io', nsHost: 'ns-soar.x.io', panelDomain: 'panel.x.io', zoneId: 'zone1' });
  h.vault.set(CHAT, { cfAuth: 'tok' });
  await h.text('/uninstall');
  await h.press(`maint:uninstall:${id}`);
  await h.text('rootpassword');
  assert.equal(h.buttons().some((b) => b.callback_data === 'maint_go:keep'), true);
  assert.equal(h.calls.job.length, 0);
  await h.press('maint_go:purge');
  assert.equal(h.calls.job[0].params.UNINSTALL_MODE, 'purge');
  assert.equal(h.calls.deleteRecords.length, 1);
  assert.equal(h.store.listDeployments(CHAT).length, 0);
  assert.match(h.last().text, /\/root\/u/);
});

test('/update is refused for ordinary users and creates no request', async () => {
  const h = harness();
  await h.text('/update');
  assert.match(h.last().text, /فقط برای مدیر/);
  assert.equal(fs.existsSync(h.requestFile), false);
});

test('/update from the admin only drops a request file', async () => {
  const h = harness({ adminIds: new Set([CHAT]) });
  const pending = h.text('/update');
  await new Promise((resolve) => { setTimeout(resolve, 20); });
  assert.equal(fs.readFileSync(h.requestFile, 'utf8').trim(), String(CHAT));
  fs.writeFileSync(h.statusFile, `ok abc123 ${CHAT} 1`);
  await pending;
  assert.match(h.last().text, /abc123/);
});

test('an update result is reported once after the restart it causes', async () => {
  const h = harness({ adminIds: new Set([CHAT]) });
  fs.writeFileSync(h.statusFile, `failed abc123 ${CHAT} 1`);
  h.app.admin.reportFinishedUpdate(h.app.bot.telegram);
  h.app.admin.reportFinishedUpdate(h.app.bot.telegram);
  const reports = h.sent.filter((m) => m.method === 'sendMessage' && m.payload.text.includes('abc123'));
  assert.equal(reports.length, 1);
  assert.match(reports[0].payload.text, /شکست/);
});

test('groups are refused so passwords are not typed there', async () => {
  const h = harness();
  await h.group('/start');
  assert.match(h.last().text, /چت خصوصی/);
  assert.equal(h.store.getSession(-5).step, 'IDLE');
});

test('user text is escaped in HTML replies', async () => {
  const h = harness();
  await h.text('/start');
  await h.press('terms_accept');
  await h.text('a<b>@x.io');
  assert.equal(h.last().text.includes('a<b>@x.io'), false);
});

test('jobs left by a previous process are announced on startup', async () => {
  const h = harness();
  h.store.beginJob(CHAT, '1.2.3.4', 'install');
  await h.app.announceOrphans();
  assert.match(h.last().text, /ریستارت/);
});

test('/reset clears secrets', async () => {
  const h = harness();
  await reachConfirm(h);
  await h.text('/reset');
  assert.equal(h.vault.get(CHAT, 'password'), undefined);
  assert.equal(h.store.getSession(CHAT).step, 'IDLE');
});

test('DNS manager lists records and scopes buttons to short indexes', async () => {
  const h = harness();
  await h.text('/dns');
  await h.text('cf-token-for-dns');
  await h.press('cf_zone:0');
  assert.match(h.last().text, /a\.x\.io/);
  assert.equal(h.buttons().some((b) => b.callback_data === 'cf_del:0'), true);
  await h.press('cf_del:0');
  assert.match(h.last().text, /تأیید حذف/);
  await h.press('cf_del_ok:0');
  assert.match(h.last().text, /رکورد حذف شد/);
});
