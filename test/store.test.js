import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createStore } from '../src/db.js';

const tempDb = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wdns-')), 'data.db');

test('old databases lose their plain text secrets but keep deployments', () => {
  const file = tempDb();
  const old = new DatabaseSync(file);
  old.exec(`
    CREATE TABLE sessions (chat_id INTEGER PRIMARY KEY, step TEXT, cf_token TEXT, vps_pass TEXT, admin_pass TEXT);
    INSERT INTO sessions VALUES (1, 'X', 'CFTOKENSECRET', 'ROOTPASSSECRET', 'ADMINSECRET');
    CREATE TABLE deployments (id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, domain TEXT, vps_ip TEXT, panel_url TEXT, status TEXT, created_at INTEGER);
    INSERT INTO deployments (chat_id, domain, vps_ip) VALUES (1, 'x.io', '1.2.3.4');
  `);
  old.close();

  const store = createStore(file);
  assert.equal(store.listDeployments(1)[0].domain, 'x.io');
  assert.equal(store.listDeployments(1)[0].ssh_port, 22);

  // Checked while the store is open: a running bot must not keep them on disk until shutdown.
  for (const name of fs.readdirSync(path.dirname(file))) {
    const raw = fs.readFileSync(path.join(path.dirname(file), name)).toString('latin1');
    for (const secret of ['CFTOKENSECRET', 'ROOTPASSSECRET', 'ADMINSECRET']) {
      assert.equal(raw.includes(secret), false, `${secret} still in ${name}`);
    }
  }
  store.close();
});

test('saveSession refuses to persist secrets', () => {
  const store = createStore(tempDb());
  for (const key of ['password', 'privateKey', 'cfAuth', 'adminPass']) {
    assert.throws(() => store.saveSession(1, { [key]: 'x' }), /refusing/);
  }
  store.close();
});

test('session round trip, merge and reset', () => {
  const store = createStore(tempDb());
  assert.equal(store.getSession(1).step, 'IDLE');
  store.saveSession(1, { step: 'A', domain: 'x.io' });
  store.saveSession(1, { step: 'B' });
  assert.deepEqual(store.getSession(1), { domain: 'x.io', step: 'B' });
  store.resetSession(1);
  assert.deepEqual(store.getSession(1), { step: 'IDLE' });
  store.close();
});

test('deployment upsert keeps one row per server and is scoped per chat', () => {
  const store = createStore(tempDb());
  const id = store.upsertDeployment({ chatId: 1, domain: 'x.io', vpsIp: '1.1.1.1', panelUrl: 'https://a/' });
  assert.equal(store.upsertDeployment({ chatId: 1, domain: 'x.io', vpsIp: '1.1.1.1' }), id);
  assert.equal(store.listDeployments(1).length, 1);
  assert.equal(store.listDeployments(1)[0].panel_url, 'https://a/');
  assert.equal(store.getDeployment(2, id), undefined);
  store.deleteDeployment(2, id);
  assert.equal(store.listDeployments(1).length, 1);
  store.close();
});

test('orphaned jobs are reported exactly once', () => {
  const store = createStore(tempDb());
  store.beginJob(1, 'h', 'install');
  const done = store.beginJob(2, 'h2', 'repair');
  store.finishJob(done);
  assert.deepEqual(store.takeOrphanedJobs().map((j) => j.chat_id), [1]);
  assert.equal(store.takeOrphanedJobs().length, 0);
  store.close();
});

test('known hosts pin and update', () => {
  const store = createStore(tempDb());
  assert.equal(store.getKnownHost('h', 22), null);
  store.setKnownHost('h', 22, 'a');
  store.setKnownHost('h', 22, 'b');
  assert.equal(store.getKnownHost('h', 22), 'b');
  store.close();
});
