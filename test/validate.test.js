import test from 'node:test';
import assert from 'node:assert/strict';
import { isPublicIPv4, isSshHost, parsePort, parseServerLine, isPrivateKey, generateStrongPassword, escapeHtml } from '../src/validate.js';
import { createVault } from '../src/vault.js';

test('isPublicIPv4 rejects private, CGNAT, reserved and malformed', () => {
  for (const ip of ['10.0.0.1', '172.16.0.1', '192.168.1.1', '127.0.0.1', '100.64.0.1', '169.254.1.1', '203.0.113.5', '256.1.1.1', '01.2.3.4', '']) {
    assert.equal(isPublicIPv4(ip), false, ip);
  }
  assert.equal(isPublicIPv4('8.8.8.8'), true);
});

test('isSshHost accepts IPv4, IPv6 and hostnames, rejects shell text', () => {
  for (const host of ['1.2.3.4', '2001:db8::1', 'vps.example.com']) assert.equal(isSshHost(host), true, host);
  for (const host of ['', 'a b', '$(id).x', 'foo;rm', 'localhost']) assert.equal(isSshHost(host), false, host);
});

test('parsePort enforces the valid range', () => {
  assert.equal(parsePort('22'), 22);
  assert.equal(parsePort('65535'), 65535);
  for (const bad of ['0', '65536', 'abc', '22x', '']) assert.equal(parsePort(bad), null, bad);
});

test('parseServerLine handles every documented form', () => {
  assert.deepEqual(parseServerLine('1.2.3.4:pw'), { host: '1.2.3.4', port: 22, user: 'root', password: 'pw' });
  assert.deepEqual(parseServerLine('1.2.3.4:2222:pw'), { host: '1.2.3.4', port: 2222, user: 'root', password: 'pw' });
  assert.deepEqual(parseServerLine('1.2.3.4:2222:ubuntu:pw'), { host: '1.2.3.4', port: 2222, user: 'ubuntu', password: 'pw' });
});

test('parseServerLine keeps colons in passwords', () => {
  assert.equal(parseServerLine('1.2.3.4:2222:ubuntu:a:b:c').password, 'a:b:c');
  assert.equal(parseServerLine('1.2.3.4:pa:ss').password, 'pa:ss');
});

test('parseServerLine leaves plain hosts to the wizard and flags bad input', () => {
  assert.equal(parseServerLine('1.2.3.4'), null);
  assert.equal(parseServerLine('2001:db8::1'), null);
  assert.deepEqual(parseServerLine('not a host:pw'), { error: 'host' });
  assert.deepEqual(parseServerLine('1.2.3.4:22:bad user:pw'), { error: 'user' });
});

test('isPrivateKey recognises pasted keys', () => {
  assert.equal(isPrivateKey('-----BEGIN OPENSSH PRIVATE KEY-----\nabc'), true);
  assert.equal(isPrivateKey('-----BEGIN RSA PRIVATE KEY-----\nabc'), true);
  assert.equal(isPrivateKey('hunter2'), false);
});

test('generateStrongPassword meets the panel limits and varies', () => {
  const a = generateStrongPassword();
  assert.ok(a.length >= 12 && a.length <= 72);
  assert.match(a, /^[A-Za-z2-9]+$/);
  assert.notEqual(a, generateStrongPassword());
});

test('escapeHtml neutralises Telegram HTML', () => {
  assert.equal(escapeHtml('<b>&'), '&lt;b&gt;&amp;');
  assert.equal(escapeHtml(undefined), '');
});

test('vault expires secrets and clears on demand', () => {
  let clock = 1000;
  const vault = createVault({ ttlMs: 100, now: () => clock });
  vault.set(1, { password: 'x' });
  assert.equal(vault.get(1, 'password'), 'x');
  clock += 101;
  assert.equal(vault.get(1, 'password'), undefined);
  vault.set(1, { password: 'y' });
  vault.clear(1);
  assert.equal(vault.get(1, 'password'), undefined);
});
