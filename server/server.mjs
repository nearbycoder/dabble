#!/usr/bin/env node
// Dabble sync relay.
//
// An optional, zero-dependency HTTP server that lets Dabble devices sync when
// they aren't on the same network. It never sees your to-dos: every row is
// encrypted on the device with a key derived from the sync group key. The
// server only stores, per row, an opaque key (so it can keep just the latest
// version of each field), the field's hybrid-logical-clock timestamp, and the
// ciphertext.
//
//   PORT=8787 DATA_DIR=./data REGISTRATION=open node server.mjs

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';

const VERSION = '1.0.0';
const MAX_PUSH_BYTES = 32 * 1024 * 1024;
const MAX_ROW_BYTES = 256 * 1024;
const MAX_WAIT_SECONDS = 30;

export function createServer({ dataDir = './data', registration = 'open', log = () => {} } = {}) {
  fs.mkdirSync(dataDir, { recursive: true });
  const db = new DatabaseSync(path.join(dataDir, 'dabble.sqlite'));
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS rows (grp TEXT NOT NULL, key TEXT NOT NULL, hlc TEXT NOT NULL, data TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (grp, key));
    CREATE INDEX IF NOT EXISTS rows_seq ON rows (grp, seq);
  `);

  const q = {
    group: db.prepare('SELECT id, token_hash, seq FROM groups WHERE id = ?'),
    createGroup: db.prepare('INSERT INTO groups (id, token_hash, seq, created) VALUES (?, ?, 0, ?)'),
    bumpSeq: db.prepare('UPDATE groups SET seq = seq + 1 WHERE id = ? RETURNING seq'),
    current: db.prepare('SELECT hlc FROM rows WHERE grp = ? AND key = ?'),
    upsert: db.prepare(`INSERT INTO rows (grp, key, hlc, data, seq) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (grp, key) DO UPDATE SET hlc = excluded.hlc, data = excluded.data, seq = excluded.seq`),
    pull: db.prepare('SELECT seq, data FROM rows WHERE grp = ? AND seq > ? ORDER BY seq LIMIT ?'),
  };

  /** group id -> callbacks waiting for new rows (long polling). */
  const waiters = new Map();
  function notify(group) {
    const set = waiters.get(group);
    if (!set) return;
    waiters.delete(group);
    for (const fn of set) fn();
  }

  const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
  const isHex = (s, len) => typeof s === 'string' && s.length === len && /^[0-9a-f]+$/.test(s);

  function send(res, status, body) {
    const payload = body === undefined ? '' : JSON.stringify(body);
    res.writeHead(status, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload),
      'Cache-Control': 'no-store',
    });
    res.end(payload);
  }

  function readBody(req, limit) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      req.on('data', (c) => {
        size += c.length;
        if (size > limit) {
          reject(Object.assign(new Error('payload too large'), { status: 413 }));
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on('end', () => resolve(Buffer.concat(chunks)));
      req.on('error', reject);
    });
  }

  /** Authenticates a request. Unknown groups are registered on first use with their token. */
  function authorize(req, groupId) {
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!isHex(token, 64)) return { error: [401, 'missing or malformed token'] };
    const hash = sha256(token);
    const group = q.group.get(groupId);
    if (!group) {
      if (registration !== 'open') return { error: [403, 'registration closed'] };
      q.createGroup.run(groupId, hash, Date.now());
      log(`registered group ${groupId.slice(0, 8)}…`);
      return { ok: true };
    }
    const a = Buffer.from(group.token_hash), b = Buffer.from(hash);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return { error: [403, 'invalid token'] };
    return { ok: true };
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/v1/health') {
      return send(res, 200, { ok: true, service: 'dabble-sync', version: VERSION, registration });
    }
    if (req.method === 'GET' && url.pathname === '/') {
      return send(res, 200, { service: 'dabble-sync', version: VERSION, docs: 'https://github.com/nearbycoder/dabble/tree/main/server' });
    }
    if (parts[0] !== 'v1' || parts[1] !== 'groups' || !isHex(parts[2], 32) || parts.length !== 4) {
      return send(res, 404, { error: 'not found' });
    }
    const group = parts[2];
    const auth = authorize(req, group);
    if (auth.error) return send(res, auth.error[0], { error: auth.error[1] });

    // POST /v1/groups/:group/push  { rows: [{ k, h, d }] }
    if (req.method === 'POST' && parts[3] === 'push') {
      let body;
      try {
        body = JSON.parse((await readBody(req, MAX_PUSH_BYTES)).toString('utf8'));
      } catch (e) {
        return send(res, e.status || 400, { error: e.message });
      }
      const rows = Array.isArray(body?.rows) ? body.rows : null;
      if (!rows) return send(res, 400, { error: 'rows must be an array' });
      for (const r of rows) {
        if (!isHex(r?.k, 32) || typeof r.h !== 'string' || r.h.length > 80 || typeof r.d !== 'string' || r.d.length > MAX_ROW_BYTES) {
          return send(res, 400, { error: 'malformed row' });
        }
      }
      let accepted = 0;
      db.exec('BEGIN IMMEDIATE');
      try {
        for (const r of rows) {
          const cur = q.current.get(group, r.k);
          // Last writer wins per field; equal timestamps are duplicates.
          if (cur && cur.hlc >= r.h) continue;
          const { seq } = q.bumpSeq.get(group);
          q.upsert.run(group, r.k, r.h, r.d, seq);
          accepted++;
        }
        db.exec('COMMIT');
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
      const { seq } = q.group.get(group);
      if (accepted > 0) notify(group);
      return send(res, 200, { accepted, cursor: seq });
    }

    // GET /v1/groups/:group/pull?since=0&limit=500&wait=25
    if (req.method === 'GET' && parts[3] === 'pull') {
      const since = Math.max(0, parseInt(url.searchParams.get('since') || '0', 10) || 0);
      const limit = Math.min(2000, Math.max(1, parseInt(url.searchParams.get('limit') || '500', 10) || 500));
      const wait = Math.min(MAX_WAIT_SECONDS, Math.max(0, parseInt(url.searchParams.get('wait') || '0', 10) || 0));
      const respond = () => {
        // A cursor ahead of the server (e.g. the server was reset) restarts from the beginning.
        const from = since > q.group.get(group).seq ? 0 : since;
        const found = q.pull.all(group, from, limit + 1);
        const more = found.length > limit;
        const page = found.slice(0, limit);
        const cursor = page.length ? page[page.length - 1].seq : from;
        send(res, 200, { rows: page.map((r) => r.data), cursor, more });
      };
      if (wait === 0 || q.group.get(group).seq !== since) return respond();
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        waiters.get(group)?.delete(finish);
        if (!res.writableEnded && !res.destroyed) respond();
      };
      const timer = setTimeout(finish, wait * 1000);
      if (!waiters.has(group)) waiters.set(group, new Set());
      waiters.get(group).add(finish);
      req.on('close', () => {
        done = true;
        clearTimeout(timer);
        waiters.get(group)?.delete(finish);
      });
      return;
    }

    return send(res, 404, { error: 'not found' });
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      log(`error: ${e.stack || e}`);
      if (!res.headersSent) send(res, 500, { error: 'internal error' });
    });
  });
  server.keepAliveTimeout = 65_000;
  server.requestTimeout = 0;
  server.on('close', () => db.close());
  return server;
}

if (process.argv[1] && import.meta.url === `file://${fs.realpathSync(process.argv[1])}`) {
  const port = parseInt(process.env.PORT || '8787', 10);
  const host = process.env.HOST || '0.0.0.0';
  const registration = process.env.REGISTRATION || 'open';
  const server = createServer({
    dataDir: process.env.DATA_DIR || './data',
    registration,
    log: (m) => console.log(`[${new Date().toISOString()}] ${m}`),
  });
  server.listen(port, host, () => console.log(`dabble-sync ${VERSION} listening on http://${host}:${port} (registration ${registration})`));
  const shutdown = () => server.close(() => process.exit(0));
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
