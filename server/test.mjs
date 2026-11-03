import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createServer } from './server.mjs';

const group = 'a'.repeat(32);
const token = 'b'.repeat(64);
const auth = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

async function withServer(fn, options = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dabble-sync-'));
  const server = createServer({ dataDir, ...options });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(base);
  } finally {
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}

const push = (base, rows, headers = auth) =>
  fetch(`${base}/v1/groups/${group}/push`, { method: 'POST', headers, body: JSON.stringify({ rows }) });

test('health', () => withServer(async (base) => {
  const res = await fetch(`${base}/v1/health`);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).ok, true);
}));

test('push keeps the latest row per key and pull pages by cursor', () => withServer(async (base) => {
  const k1 = '1'.repeat(32), k2 = '2'.repeat(32);
  let res = await push(base, [{ k: k1, h: '000000000000001-0000000000-a', d: 'one' }, { k: k2, h: '000000000000001-0000000001-a', d: 'two' }]);
  assert.deepEqual(await res.json(), { accepted: 2, cursor: 2 });
  res = await push(base, [{ k: k1, h: '000000000000000-0000000000-a', d: 'stale' }]);
  assert.equal((await res.json()).accepted, 0);
  res = await push(base, [{ k: k1, h: '000000000000002-0000000000-b', d: 'one-v2' }]);
  assert.deepEqual(await res.json(), { accepted: 1, cursor: 3 });

  res = await fetch(`${base}/v1/groups/${group}/pull?since=0`, { headers: auth });
  const body = await res.json();
  assert.deepEqual(body.rows, ['two', 'one-v2']);
  assert.equal(body.cursor, 3);
  assert.equal(body.more, false);

  res = await fetch(`${base}/v1/groups/${group}/pull?since=1&limit=1`, { headers: auth });
  const page = await res.json();
  assert.deepEqual(page.rows, ['two']);
  assert.equal(page.more, true);
}));

test('rejects a wrong token once the group exists', () => withServer(async (base) => {
  await push(base, []);
  const res = await push(base, [], { ...auth, Authorization: `Bearer ${'c'.repeat(64)}` });
  assert.equal(res.status, 403);
}));

test('closed registration refuses new groups', () => withServer(async (base) => {
  const res = await push(base, []);
  assert.equal(res.status, 403);
}, { registration: 'closed' }));

test('long poll returns as soon as another device pushes', () => withServer(async (base) => {
  await push(base, []);
  const started = Date.now();
  const waiting = fetch(`${base}/v1/groups/${group}/pull?since=0&wait=10`, { headers: auth }).then((r) => r.json());
  await new Promise((r) => setTimeout(r, 150));
  await push(base, [{ k: '3'.repeat(32), h: '000000000000005-0000000000-c', d: 'live' }]);
  const body = await waiting;
  assert.deepEqual(body.rows, ['live']);
  assert.ok(Date.now() - started < 5000);
}));

test('rejects malformed rows', () => withServer(async (base) => {
  const res = await push(base, [{ k: 'nothex', h: 'x', d: 'y' }]);
  assert.equal(res.status, 400);
}));
