'use strict';
// Transport tests: run against a real local HTTP server with `node tests/transport.test.js`.
// FiveM: not needed, since transport.js only wires FiveM when its globals exist.

const assert = require('assert');
const http = require('http');
const zlib = require('zlib');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createTransport, serialize, scanCfgForExposedToken, isLoopback } = require('../server/transport.js');

const BOOT_A = '01J9ZZZZZZZZZZZZZZZZZZZZZA';
const BOOT_B = '01J9ZZZZZZZZZZZZZZZZZZZZZB';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function tmpDir() { return fs.mkdtempSync(path.join(os.tmpdir(), 'atlas-spool-')); }

/** Fake daemon: records batches; `mode(batch)` returns {status, body}. */
function daemon(host) {
  const d = { batches: [], seen: [], hwm: {}, mode: null, inFlight: 0, maxInFlight: 0 };
  d.server = http.createServer((req, res) => {
    d.inFlight++;
    d.maxInFlight = Math.max(d.maxInFlight, d.inFlight);
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body = Buffer.concat(chunks);
      if (req.headers['content-encoding'] === 'gzip') body = zlib.gunzipSync(body);
      const lines = body.toString('utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
      const batch = { headers: req.headers, lines, at: Date.now() };
      d.seen.push(batch);
      const reply = d.mode ? d.mode(batch) : null;
      setTimeout(() => {
        d.inFlight--;
        if (reply) { res.writeHead(reply.status); res.end(reply.body || ''); return; }
        d.batches.push(batch);
        const boot = lines[0].boot;
        d.hwm[boot] = Math.max(d.hwm[boot] || 0, ...lines.map((l) => l.seq));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ acked_seq: d.hwm[boot] }));
      }, 5);
    });
  });
  return new Promise((r) => d.server.listen(0, host ? '0.0.0.0' : '127.0.0.1', () => {
    d.url = `http://${host || '127.0.0.1'}:${d.server.address().port}`;
    r(d);
  }));
}

let seq = 0;
function ev(type, extra) {
  seq++;
  return Object.assign({ type: type || 'money.change', ts: Date.now(), seq, trust: 'server', data: { amount: seq } }, extra || {});
}

function mk(d, opts) {
  return createTransport(Object.assign({
    endpoint: d.url, token: 'atl_test', pumpMs: 10, batchAgeMs: 30, backoffMinMs: 20, backoffMaxMs: 80,
    authBackoffMs: 50, log: () => {},
  }, opts));
}

async function until(fn, ms) {
  const end = Date.now() + (ms || 5000);
  while (Date.now() < end) { if (fn()) return; await sleep(10); }
  throw new Error('timeout waiting for condition');
}

function allSeqs(d, boot) {
  return d.batches.flatMap((b) => b.lines).filter((l) => !boot || l.boot === boot).map((l) => l.seq);
}

function strictlyIncreasing(a) { for (let i = 1; i < a.length; i++) if (a[i] <= a[i - 1]) return false; return true; }

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('serialize: fixed key order, v/boot stamped, empty tables as objects', () => {
  const r = serialize({ type: 'medical.respawn', ts: 1790000000123, seq: 7, trust: 'server', src: 3,
    actor: { account: 'license2:x', char: 'ABC' }, pos: [1.5, 2, 3], data: [] }, BOOT_A);
  assert.ok(r.line.startsWith('{"v":1,"type":"medical.respawn","ts":1790000000123,"seq":7,"boot":"' + BOOT_A + '"'));
  const o = JSON.parse(r.line);
  assert.deepStrictEqual(o.data, {});
  assert.strictEqual(o.src, 3);
  const j = JSON.parse(serialize({ type: 'job.change', ts: 1, seq: 1, data: { from: [], to: { job: 'police', grade: 1 } } }, BOOT_A).line);
  assert.deepStrictEqual(j.data.from, {});
  const c = JSON.parse(serialize({ type: 'item.craft', ts: 1, seq: 2, data: { in: [], out: [['a', 1]] } }, BOOT_A).line);
  assert.deepStrictEqual(c.data.in, []); // Arrays: real arrays stay arrays
  assert.strictEqual(JSON.parse(serialize({ type: 'x', ts: 1n, seq: 3n, data: { big: 5n } }, BOOT_A).line).data.big, 5);
});

test('serialize: optional fields appear only when valid', () => {
  const o = (ev) => JSON.parse(serialize(ev, BOOT_A).line);
  const base = { type: 't', ts: 5, seq: 1 };
  assert.strictEqual(o(base).trust, 'server');
  assert.strictEqual('src' in o(base), false);
  assert.strictEqual(o(Object.assign({ src: 0 }, base)).src, 0);
  assert.strictEqual('pos' in o(Object.assign({ pos: [1, 2] }, base)), false);
  assert.deepStrictEqual(o(Object.assign({ pos: [1, 2, 3] }, base)).pos, [1, 2, 3]);
  assert.strictEqual('actor' in o(Object.assign({ actor: [] }, base)), false);
  assert.strictEqual(o(Object.assign({ res: 'my-res' }, base)).res, 'my-res');
  assert.strictEqual(o(Object.assign({}, base, { ts: 5.9 })).ts, 5);
});

test('sends in seq order, one batch in flight, frees on ack, no gzip on loopback', async () => {
  const d = await daemon();
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  for (let i = 0; i < 25; i++) t.push(Array.from({ length: 100 }, () => ev()));
  await until(() => t.stats().mem === 0 && t.stats().inflight === 0);
  const seqs = allSeqs(d, BOOT_A);
  assert.strictEqual(seqs.length, 2500);
  assert.ok(strictlyIncreasing(seqs));
  assert.strictEqual(d.maxInFlight, 1);
  assert.ok(d.batches.every((b) => b.lines.length <= 1000));
  assert.strictEqual(d.batches[0].headers['content-encoding'], undefined);
  assert.strictEqual(d.batches[0].headers.authorization, 'Bearer atl_test');
  assert.strictEqual(d.batches[0].headers['content-type'], 'application/x-ndjson');
  t.stop(); d.server.close();
});

test('retries the same batch after 503 and network errors', async () => {
  const d = await daemon();
  let fails = 3;
  d.mode = () => (fails-- > 0 ? { status: 503 } : null);
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  const first = seq + 1;
  t.push([ev(), ev(), ev()]);
  await until(() => d.batches.length === 1);
  assert.strictEqual(d.batches[0].lines[0].seq, first);
  await until(() => t.stats().mem + t.stats().inflight === 0);
  t.stop(); d.server.close();
});

test('401 backs off, keeps the batch and retries it unchanged', async () => {
  const d = await daemon();
  let fails = 2;
  d.mode = () => (fails-- > 0 ? { status: 401 } : null);
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev(), ev()]);
  await until(() => d.batches.length === 1, 3000);
  assert.strictEqual(d.seen.length, 3);
  // Backoff: each retry waits at least the auth backoff (50 ms in this test), not the pump interval
  assert.ok(d.seen[1].at - d.seen[0].at >= 40);
  assert.ok(d.seen[2].at - d.seen[1].at >= 40);
  for (const b of d.seen) assert.deepStrictEqual(b.lines.map((l) => l.seq), d.seen[0].lines.map((l) => l.seq));
  t.stop(); d.server.close();
});

test('413 splits batches; 400 drops and counts', async () => {
  const d = await daemon();
  d.mode = (b) => (b.lines.length > 100 ? { status: 413 } : null);
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push(Array.from({ length: 800 }, () => ev()));
  await until(() => allSeqs(d, BOOT_A).length >= 800);
  assert.ok(strictlyIncreasing(allSeqs(d, BOOT_A)));
  d.mode = () => ({ status: 400, body: 'bad' });
  t.push([ev(), ev()]);
  await until(() => (t.stats().drops.malformed || 0) === 2);
  t.stop(); d.server.close();
});

test('heartbeat gets transport queue depth and drops', async () => {
  const d = await daemon();
  const t = mk(d, { batchAgeMs: 200 });
  t.start(BOOT_A); await t.loadSpoolDir();
  t._state.drops.malformed = 4;
  // Queue: the heartbeat reports Lua's own depth (2) plus the five events already waiting in transport
  const heartbeat = ev('agent.heartbeat', { data: { version: '0.1.0', queue: 2, drops: [], adapters: [] } });
  t.push([ev(), ev(), ev(), ev(), ev(), heartbeat]);
  await until(() => d.batches.length === 1);
  const hb = d.batches[0].lines[5];
  assert.strictEqual(hb.type, 'agent.heartbeat');
  assert.strictEqual(hb.data.drops.js_malformed, 4);
  assert.strictEqual(hb.data.queue, 7);
  assert.deepStrictEqual(hb.data.adapters, []);
  t.stop(); d.server.close();
});

test('outage: spills to disk, replays spool before memory, deletes files', async () => {
  const d = await daemon();
  const dir = tmpDir();
  let down = true;
  d.mode = () => (down ? { status: 503 } : null);
  const t = mk(d, { spoolDir: dir, memEvents: 300, spillChunk: 100, replayRate: 100000 });
  t.start(BOOT_A); await t.loadSpoolDir();
  for (let i = 0; i < 10; i++) { t.push(Array.from({ length: 100 }, () => ev())); await sleep(5); }
  // Spill: how many segments spill depends on how many events the failing in-flight batch holds.
  await until(() => fs.readdirSync(dir).filter((f) => f.endsWith('.gz')).length >= 1, 8000);
  assert.ok(t.stats().mem <= 300);
  down = false;
  await until(() => t.stats().mem === 0 && t.stats().spoolFiles === 0 && t.stats().inflight === 0, 8000);
  // Ack timing: the daemon records a batch before the client processes its ack, so wait for all rows to land.
  await until(() => allSeqs(d, BOOT_A).length >= 1000, 3000);
  const seqs = allSeqs(d, BOOT_A);
  assert.strictEqual(seqs.length, 1000);
  assert.ok(strictlyIncreasing(seqs), 'strict seq order across spool and memory');
  await sleep(50);
  assert.strictEqual(fs.readdirSync(dir).length, 0);
  t.stop(); d.server.close();
});

test('stop persists the queue; next start replays the old boot first', async () => {
  const d = await daemon();
  const dir = tmpDir();
  d.mode = () => ({ status: 503 });
  const t1 = mk(d, { spoolDir: dir });
  t1.start(BOOT_A); await t1.loadSpoolDir();
  t1.push(Array.from({ length: 50 }, () => ev()));
  await sleep(100);
  t1.stop();
  assert.ok(fs.readdirSync(dir).length >= 1);

  d.mode = null;
  seq = 0; // Boot: a new boot restarts seq at 1
  const t2 = mk(d, { spoolDir: dir, replayRate: 100000 });
  t2.start(BOOT_B);
  t2.push([ev(), ev()]);
  await t2.loadSpoolDir();
  await until(() => t2.stats().spoolFiles === 0 && t2.stats().mem === 0 && t2.stats().inflight === 0);
  const boots = d.batches.map((b) => b.lines[0].boot);
  assert.strictEqual(boots[0], BOOT_A);
  assert.strictEqual(boots[boots.length - 1], BOOT_B);
  assert.strictEqual(allSeqs(d, BOOT_A).length, 50);
  assert.deepStrictEqual(allSeqs(d, BOOT_B), [1, 2]);
  t2.stop(); d.server.close();
});

test('spool cap strips position.sample from a segment and keeps everything else', async () => {
  const d = await daemon();
  const dir = tmpDir();
  d.mode = () => ({ status: 503 });
  // Pump: off, since a segment being sent is exempt from the cap and would make the outcome timing-dependent
  const t = mk(d, { spoolDir: dir, memEvents: 200, spillChunk: 200, spoolBytes: 1, autoPump: false });
  t.start(BOOT_A); await t.loadSpoolDir();
  const batch = [];
  for (let i = 0; i < 400; i++) batch.push(ev(i % 2 ? 'position.sample' : 'money.change', { data: { pad: 'x'.repeat(50) } }));
  t.push(batch);
  await until(() => (t.stats().drops.spool_cap_position || 0) > 0, 5000);
  await until(() => !t._state.capRunning, 5000);
  assert.strictEqual(t.stats().drops.spool_cap_position, 100);
  assert.strictEqual(t.stats().drops.spool_cap_segment, undefined);
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.gz'));
  assert.strictEqual(files.length, 1);
  const text = zlib.gunzipSync(fs.readFileSync(path.join(dir, files[0]))).toString('utf8');
  const lines = text.split('\n').filter(Boolean).map((l) => JSON.parse(l));
  assert.strictEqual(lines.length, 100);
  assert.ok(lines.every((l) => l.type === 'money.change'));
  t.stop(); d.server.close();
});

test('spool cap deletes the oldest whole segments once positions are gone', async () => {
  const d = await daemon();
  const dir = tmpDir();
  d.mode = () => ({ status: 503 });
  const t = mk(d, { spoolDir: dir, memEvents: 100, spillChunk: 100, spoolBytes: 1, autoPump: false });
  t.start(BOOT_A); await t.loadSpoolDir();
  for (let i = 0; i < 6; i++) { t.push(Array.from({ length: 100 }, () => ev('money.change')));  await sleep(30); }
  await until(() => (t.stats().drops.spool_cap_segment || 0) > 0, 5000);
  await until(() => !t._state.capRunning, 5000);
  assert.ok(t.stats().spoolFiles >= 1);
  assert.ok(fs.readdirSync(dir).filter((f) => f.endsWith('.gz')).length <= t.stats().spoolFiles);
  t.stop(); d.server.close();
});

test('spool segments that cannot be written are dropped instead of piling up in memory', async () => {
  const d = await daemon();
  const dir = tmpDir();
  const blocker = path.join(dir, 'file');
  fs.writeFileSync(blocker, 'x');
  d.mode = () => ({ status: 503 });
  // Spool dir: lies under a regular file, so every write fails
  const t = mk(d, { spoolDir: path.join(blocker, 'spool'), memEvents: 100, spillChunk: 100, autoPump: false });
  t.start(BOOT_A);
  t.push(Array.from({ length: 1000 }, () => ev('money.change')));
  await until(() => (t.stats().drops.spool_write_failed || 0) >= 800, 5000);
  assert.strictEqual(t.stats().drops.spool_write_failed, 800);
  assert.strictEqual(t._state.spool.length, 1);
  assert.strictEqual(t._state.spool[0].lines.length, 100);
  t.stop(); d.server.close();
});

test('replay never starts on a segment while the cap is rewriting it', async () => {
  const d = await daemon();
  const dir = tmpDir();
  const t = mk(d, { spoolDir: dir, memEvents: 1499, spillChunk: 1500, autoPump: false });
  t.start(BOOT_A); await t.loadSpoolDir();
  d.mode = () => ({ status: 503 });
  const batch = [];
  for (let i = 0; i < 1500; i++) batch.push(ev(i % 2 ? 'position.sample' : 'money.change'));
  t.push(batch);
  await until(() => t._state.spool.length === 1 && t._state.spool[0].written, 5000);
  d.mode = null;
  d.batches.length = 0;
  // Race: replay starts in the same tick the cap begins rewriting the head segment
  t._options.spoolBytes = 1;
  const capping = t._enforceCap();
  t.pump();
  await capping;
  await until(() => { t.pump(); return t._state.spool.length === 0; }, 5000);
  const types = d.batches.flatMap((b) => b.lines.map((l) => l.type));
  assert.strictEqual(types.length, 750);
  assert.ok(types.every((x) => x === 'money.change'));
  assert.strictEqual(new Set(d.batches.flatMap((b) => b.lines.map((l) => l.seq))).size, 750);
  t.stop(); d.server.close();
});

test('isLoopback only treats localhost, ::1 and 127.x as loopback', () => {
  for (const h of ['localhost', 'LOCALHOST', '::1', '[::1]', '127.0.0.1', '127.1.2.3']) assert.strictEqual(isLoopback(h), true, h);
  for (const h of ['atlas.osmfxmods.com', '10.0.0.5', '192.168.1.2', '128.0.0.1', '127.evil.com', '127.0.0.1.evil.com', '127.0.0']) assert.strictEqual(isLoopback(h), false, h);
});

test('gzip is requested for remote endpoints and skipped for loopback ones', () => {
  assert.strictEqual(createTransport({ endpoint: 'https://atlas.example.com', token: 't', autoPump: false }).stats().gzip, true);
  assert.strictEqual(createTransport({ endpoint: 'http://127.0.0.1:7271', token: 't', autoPump: false }).stats().gzip, false);
  assert.strictEqual(createTransport({ endpoint: 'http://localhost:7271/', token: 't', autoPump: false }).stats().gzip, false);
});

test('gzips the body on the wire for a non-loopback address', async () => {
  const ext = Object.values(os.networkInterfaces()).flat().find((i) => i && i.family === 'IPv4' && !i.internal);
  if (!ext) { console.log('     skipped: no non-loopback IPv4 interface'); return; }
  const d = await daemon(ext.address);
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev(), ev(), ev()]);
  await until(() => d.batches.length === 1);
  assert.strictEqual(d.batches[0].headers['content-encoding'], 'gzip');
  assert.strictEqual(d.batches[0].lines.length, 3);
  t.stop(); d.server.close();
});

test('marks batches holding events older than 14 days with X-Atlas-Replay', async () => {
  const d = await daemon();
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev('money.change', { ts: Date.now() - 15 * 86400000 })]);
  await until(() => d.batches.length === 1);
  assert.strictEqual(d.batches[0].headers['x-atlas-replay'], '1');
  t.push([ev()]);
  await until(() => d.batches.length === 2);
  assert.strictEqual(d.batches[1].headers['x-atlas-replay'], undefined);
  t.stop(); d.server.close();
});

test('resends only the unacknowledged tail after a partial ack', async () => {
  const d = await daemon();
  let first = true;
  d.mode = (b) => {
    if (!first) return null;
    first = false;
    return { status: 200, body: JSON.stringify({ acked_seq: b.lines[3].seq }) };
  };
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push(Array.from({ length: 10 }, () => ev()));
  await until(() => t.stats().mem === 0 && t.stats().inflight === 0 && d.seen.length >= 2);
  const firstSeqs = d.seen[0].lines.map((l) => l.seq);
  assert.strictEqual(firstSeqs.length, 10);
  assert.deepStrictEqual(d.seen[1].lines.map((l) => l.seq), firstSeqs.slice(4));
  t.stop(); d.server.close();
});

test('treats an ack that covers nothing as a stall, then drops the batch after five tries', async () => {
  const d = await daemon();
  d.mode = () => ({ status: 200, body: JSON.stringify({ acked_seq: 0 }) });
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev(), ev()]);
  await until(() => (t.stats().drops.ack_stall || 0) === 2, 5000);
  assert.strictEqual(d.seen.length, 5);
  t.stop(); d.server.close();
});

test('retries when the 200 body is not a valid ack', async () => {
  const d = await daemon();
  let bad = 2;
  d.mode = () => (bad-- > 0 ? { status: 200, body: 'not json' } : null);
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev()]);
  await until(() => d.batches.length === 1);
  assert.strictEqual(d.seen.length, 3);
  t.stop(); d.server.close();
});

test('drops a single event the daemon calls too large', async () => {
  const d = await daemon();
  d.mode = () => ({ status: 413 });
  const t = mk(d);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev()]);
  await until(() => (t.stats().drops.too_large || 0) === 1);
  assert.strictEqual(t.stats().mem + t.stats().inflight, 0);
  t.stop(); d.server.close();
});

test('refuse discards the queue and stops all sending', async () => {
  const d = await daemon();
  const t = mk(d, { batchAgeMs: 500 });
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev(), ev()]);
  t.refuse('token exposed');
  t.push([ev()]);
  await sleep(150);
  assert.strictEqual(d.seen.length, 0);
  assert.strictEqual(t.stats().state, 'refused');
  assert.strictEqual(t.stats().mem, 0);
  t.stop(); d.server.close();
});

test('refuse also stops replaying spool segments from an earlier run', async () => {
  const d = await daemon();
  const dir = tmpDir();
  d.mode = () => ({ status: 503 });
  const t1 = mk(d, { spoolDir: dir });
  t1.start(BOOT_A); await t1.loadSpoolDir();
  t1.push([ev(), ev()]);
  await sleep(60);
  t1.stop();
  assert.ok(fs.readdirSync(dir).length >= 1);
  d.mode = null;
  d.seen.length = 0;
  const t2 = mk(d, { spoolDir: dir, replayRate: 100000 });
  t2.start(BOOT_B); await t2.loadSpoolDir();
  t2.refuse('token exposed');
  await sleep(250);
  assert.strictEqual(d.seen.length, 0);
  t2.stop(); d.server.close();
});

test('ignores events pushed before start, malformed input and unserialisable events', async () => {
  const d = await daemon();
  const t = mk(d);
  t.push([ev()]);
  assert.strictEqual(t.stats().mem, 0);
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push('not an array'); t.push(null);
  const circular = { type: 'x', ts: 1, seq: 1, data: {} };
  circular.data.self = circular.data;
  t.push([null, 5, circular, ev()]);
  assert.strictEqual(t.stats().mem, 1);
  assert.strictEqual(t.stats().drops.serialize, 1);
  t.stop(); d.server.close();
});

test('never writes the token to the log', async () => {
  const d = await daemon();
  const lines = [];
  let mode = 0;
  d.mode = () => [{ status: 401 }, { status: 503 }, { status: 400, body: 'bad' }][mode++] || null;
  const t = mk(d, { log: (m) => lines.push(m), token: 'atl_live_SECRET_VALUE' });
  t.start(BOOT_A); await t.loadSpoolDir();
  t.push([ev()]);
  await until(() => (t.stats().drops.malformed || 0) === 1, 5000);
  assert.ok(lines.length >= 2);
  assert.ok(lines.every((l) => !l.includes('atl_live_SECRET_VALUE')));
  t.stop(); d.server.close();
});

test('warns when the token would travel over http to a remote host', () => {
  const lines = [];
  const mkT = (endpoint) => createTransport({ endpoint, token: 't', autoPump: false, log: (m) => lines.push(m) });
  const remote = mkT('http://atlas.example.com:7271');
  assert.strictEqual(remote.stats().insecureRemote, true);
  remote.start(BOOT_A);
  assert.strictEqual(lines.length, 1);
  assert.ok(lines[0].includes('unencrypted'));
  for (const ok of ['https://atlas.example.com', 'http://127.0.0.1:7271', 'http://localhost:7271']) {
    const t = mkT(ok);
    assert.strictEqual(t.stats().insecureRemote, false, ok);
    t.start(BOOT_A);
  }
  assert.strictEqual(lines.length, 1);
});

test('reports a bad endpoint without sending anything', () => {
  const t = createTransport({ endpoint: 'not a url', token: 't', autoPump: false, log: () => {} });
  t.start(BOOT_A);
  t.push([ev()]);
  t.pump();
  assert.strictEqual(t.stats().state, 'bad_endpoint');
});

test('drops an unreadable spool segment and keeps sending newer events', async () => {
  const d = await daemon();
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, `${BOOT_A}-${'1'.padStart(12, '0')}-${'5'.padStart(12, '0')}-5.ndjson.gz`), 'not gzip');
  fs.writeFileSync(path.join(dir, 'leftover.tmp'), 'partial');
  const t = mk(d, { spoolDir: dir, replayRate: 100000 });
  t.start(BOOT_B); await t.loadSpoolDir();
  assert.strictEqual(t.stats().spoolFiles, 1);
  t.push([ev()]);
  await until(() => d.batches.length === 1 && t.stats().spoolFiles === 0);
  assert.strictEqual(t.stats().drops.spool_corrupt, 5);
  assert.strictEqual(d.batches[0].lines[0].boot, BOOT_B);
  assert.strictEqual(fs.existsSync(path.join(dir, 'leftover.tmp')), false);
  t.stop(); d.server.close();
});

test('cfg scan finds setr/sets through exec includes', async () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'server.cfg'), 'ensure atlas-agent\nexec atlas.cfg\n# setr atlas:token "commented"\n');
  fs.writeFileSync(path.join(dir, 'atlas.cfg'), 'set atlas:endpoint "http://127.0.0.1:7271"\nsetr atlas:token "atl_live_x"\n');
  const hit = await scanCfgForExposedToken(['+exec', 'server.cfg'], dir);
  assert.strictEqual(hit.command, 'setr');
  fs.writeFileSync(path.join(dir, 'atlas.cfg'), 'set atlas:token "atl_live_x"\n');
  assert.strictEqual(await scanCfgForExposedToken(['+exec', 'server.cfg'], dir), null);
});

test('cfg scan covers sets, quoted names, case, inline comments and exec cycles', async () => {
  const dir = tmpDir();
  const scan = () => scanCfgForExposedToken(['+exec', 'server.cfg'], dir);
  const write = (name, text) => fs.writeFileSync(path.join(dir, name), text);
  write('server.cfg', 'sets atlas:token "x"\n');
  assert.strictEqual((await scan()).command, 'sets');
  write('server.cfg', 'SETR "atlas:token" "x"\n');
  assert.strictEqual((await scan()).command, 'setr');
  write('server.cfg', 'set atlas:token "x" # not setr\nset atlas:endpoint "http://x"  // setr atlas:token\n');
  assert.strictEqual(await scan(), null);
  write('server.cfg', 'exec "a.cfg"\n');
  write('a.cfg', 'exec server.cfg\nsetr atlas:token "x"\n');
  assert.strictEqual((await scan()).command, 'setr');
  write('a.cfg', 'exec server.cfg\nset atlas:token "x"\n');
  assert.strictEqual(await scan(), null);
  write('server.cfg', 'setr atlas:token_other "x"\nsetr atlas:tokenx "x"\n');
  assert.strictEqual(await scan(), null);
});

test('cfg scan finds a token set on the command line', async () => {
  const dir = tmpDir();
  assert.strictEqual((await scanCfgForExposedToken(['+setr', 'atlas:token', 'abc'], dir)).command, 'setr');
  assert.strictEqual((await scanCfgForExposedToken(['+SETS', '"atlas:token"', 'abc'], dir)).command, 'sets');
  assert.strictEqual((await scanCfgForExposedToken(['+set', 'atlas:token', 'abc'], dir)), null);
  assert.strictEqual((await scanCfgForExposedToken(['+setr', 'other', 'abc'], dir)), null);
  assert.strictEqual((await scanCfgForExposedToken(['+setr'], dir)), null);
});

test('cfg scan falls back to server.cfg, tolerates missing files and stops at depth 4', async () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'server.cfg'), 'exec missing.cfg\nsetr atlas:token "x"\n');
  assert.strictEqual((await scanCfgForExposedToken([], dir)).command, 'setr');
  fs.writeFileSync(path.join(dir, 'server.cfg'), 'exec l1.cfg\n');
  for (let i = 1; i <= 6; i++) {
    fs.writeFileSync(path.join(dir, `l${i}.cfg`), i < 6 ? `exec l${i + 1}.cfg\n` : 'setr atlas:token "x"\n');
  }
  assert.strictEqual(await scanCfgForExposedToken([], dir), null);
  fs.writeFileSync(path.join(dir, 'l4.cfg'), 'setr atlas:token "x"\n');
  assert.strictEqual((await scanCfgForExposedToken([], dir)).command, 'setr');
});

(async () => {
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
      console.log('ok   ' + t.name);
    } catch (e) {
      failed++;
      console.log('FAIL ' + t.name + '\n     ' + (e && e.stack || e));
    }
  }
  console.log(`${tests.length - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
