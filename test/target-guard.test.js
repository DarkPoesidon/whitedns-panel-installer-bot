import test from 'node:test';
import assert from 'node:assert/strict';
import { createAttemptLimiter, resolvePublicTarget } from '../src/flows/common.js';

const refused = (err) => err.code === 'PRIVATE_TARGET';

test('loopback, private and link-local targets are refused', async () => {
  for (const host of ['127.0.0.1', '10.0.0.5', '192.168.1.1', '169.254.169.254', '::1', 'fe80::1', 'fd00::1', '::ffff:127.0.0.1']) {
    await assert.rejects(resolvePublicTarget(host, { allowPrivate: false }), refused, host);
  }
});

test('public addresses pass unchanged', async () => {
  assert.equal(await resolvePublicTarget('8.8.8.8', { allowPrivate: false }), '8.8.8.8');
  assert.equal(await resolvePublicTarget('2606:4700:4700::1111', { allowPrivate: false }), '2606:4700:4700::1111');
});

test('a name resolving to a private address is refused', async () => {
  const lookup = async () => [{ address: '10.1.1.1', family: 4 }];
  await assert.rejects(resolvePublicTarget('evil.example.com', { lookup, allowPrivate: false }), refused);
});

test('a name with any private answer is refused, defeating mixed records', async () => {
  const lookup = async () => [{ address: '8.8.8.8', family: 4 }, { address: '127.0.0.1', family: 4 }];
  await assert.rejects(resolvePublicTarget('mixed.example.com', { lookup, allowPrivate: false }), refused);
});

test('a public name connects to the checked address, not the name', async () => {
  const lookup = async () => [{ address: '8.8.8.8', family: 4 }];
  assert.equal(await resolvePublicTarget('vps.example.com', { lookup, allowPrivate: false }), '8.8.8.8');
});

test('the opt-in allows private deployments', async () => {
  assert.equal(await resolvePublicTarget('192.168.1.5', { allowPrivate: true }), '192.168.1.5');
});

test('connection attempts are capped per chat and recover after the window', () => {
  const checkAttemptLimit = createAttemptLimiter();
  const chat = 987654;
  const start = 1_000_000;
  for (let i = 0; i < 10; i += 1) checkAttemptLimit(chat, start);
  assert.throws(() => checkAttemptLimit(chat, start + 1000), (err) => err.code === 'RATE_LIMITED');
  checkAttemptLimit(chat + 1, start + 1000);
  checkAttemptLimit(chat, start + 16 * 60 * 1000);
});
