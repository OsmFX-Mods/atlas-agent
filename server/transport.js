'use strict';
// Transport: sends event batches to the Atlas ingest API; runs on FXServer's default Node runtime (16.x).
// Structure: createTransport is a plain factory so plain Node can test it; the FiveM wiring is at the bottom.

const http = require('http');
const https = require('https');
const zlib = require('zlib');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { URL } = require('url');

// Defaults: batches close at 1 s, 1000 events or 4 MB; memory holds 50k events before spilling to a 200 MB disk spool.
// Replay: spooled events are replayed at 5k events/s ahead of newer ones.
const DEFAULTS = {
  batchEvents: 1000,
  batchBytes: 4 * 1024 * 1024,
  batchAgeMs: 1000,
  memEvents: 50000,
  spillChunk: 10000,
  spoolBytes: 200 * 1024 * 1024,
  replayRate: 5000,              // replayRate: events per second
  replayFlagAgeMs: 14 * 86400000, // replayFlagAgeMs: batches with older events get the X-Atlas-Replay header
  backoffMinMs: 1000,
  backoffMaxMs: 30000,
  authBackoffMs: 30000,
  requestTimeoutMs: 15000,
  pumpMs: 100,
};

// Object keys: Lua cannot tell an empty table from an empty array, so msgpack may deliver [] where {} is meant.
const OBJECT_KEYS = new Set(['data', 'actor', 'from', 'to', 'drops', 'identifiers', 'victim', 'veh']);

function replacer(key, value) {
  if (typeof value === 'bigint') return Number(value);
  if (Array.isArray(value) && value.length === 0 && OBJECT_KEYS.has(key)) return {};
  return value;
}

// Spool prefix: written in a fixed key order so replay can parse lines without JSON.parse.
const PREFIX_RE = /^\{"v":1,"type":"([^"]*)","ts":(\d+),"seq":(\d+),"boot":"([0-9A-Z]{26})"/;
const SEG_RE = /^([0-9A-Z]{26})-(\d{12})-(\d{12})-(\d+)\.ndjson\.gz$/;

function num(v) {
  if (typeof v === 'bigint') return Number(v);
  return typeof v === 'number' ? v : Number(v);
}

function serialize(ev, boot) {
  const ts = Math.floor(num(ev.ts));
  const seq = num(ev.seq);
  let s = '{"v":1,"type":' + JSON.stringify(String(ev.type)) + ',"ts":' + ts + ',"seq":' + seq +
    ',"boot":"' + boot + '","trust":' + JSON.stringify(ev.trust || 'server');
  if (ev.src !== undefined && ev.src !== null) s += ',"src":' + num(ev.src);
  if (ev.actor && typeof ev.actor === 'object' && !Array.isArray(ev.actor)) s += ',"actor":' + JSON.stringify(ev.actor, replacer);
  if (Array.isArray(ev.pos) && ev.pos.length === 3) s += ',"pos":' + JSON.stringify(ev.pos, replacer);
  if (ev.res) s += ',"res":' + JSON.stringify(String(ev.res));
  let data = ev.data;
  if (!data || (Array.isArray(data) && data.length === 0)) data = {};
  s += ',"data":' + JSON.stringify(data, replacer) + '}';
  return { seq, ts, type: String(ev.type), line: s };
}

function isLoopback(host) {
  const h = host.replace(/^\[|\]$/g, '').toLowerCase();
  return h === 'localhost' || h === '::1' || /^(::ffff:)?127(\.\d{1,3}){3}$/.test(h);
}

function pad12(n) { return String(n).padStart(12, '0'); }

// Queue order: in-flight batch, then spool segments oldest first, then memory.
// Spill: memory over the limit moves the oldest events to disk; a full spool drops position.sample first, then segments.
function createTransport(options) {
  const o = Object.assign({}, DEFAULTS, options);
  const log = o.log || ((m) => console.log('[atlas] ' + m));
  const now = o.now || (() => Date.now());

  let url = null;
  try { url = new URL(o.endpoint.replace(/\/+$/, '') + '/ingest/v1/events'); } catch (e) { url = null; }
  const secure = url && url.protocol === 'https:';
  const insecureRemote = !!url && !secure && !isLoopback(url.hostname); // insecureRemote: the token would travel unencrypted
  const gzip = url ? !isLoopback(url.hostname) : false;
  const agent = url ? new (secure ? https : http).Agent({ keepAlive: true, maxSockets: 1 }) : null;

  const st = {
    boot: null,
    refused: null,
    mem: [], memHead: 0,       // mem: array with a head index for O(1) dequeue
    spool: [],                 // spool: segments, oldest first
    inflight: null,
    nextAttemptAt: 0,
    backoff: o.backoffMinMs,
    replayNextAt: 0,
    capRunning: false,
    stopped: false,
    spoolLoaded: false,        // spoolLoaded: the pump waits until old spool segments are indexed
    limitEvents: o.batchEvents,
    limitBytes: o.batchBytes,
    drops: {},
    ackedSeq: 0, ackedBoot: null, lastAckAt: 0,
    lastError: null,
    sentEvents: 0, sentBatches: 0,
    serNs: 0, serCount: 0,
    lastLog: {},
    lastLuaDrops: {},
  };

  function drop(reason, n) { st.drops[reason] = (st.drops[reason] || 0) + (n || 1); }

  function logOnce(key, msg, everyMs) {
    const t = now();
    if (!st.lastLog[key] || t - st.lastLog[key] >= (everyMs || 30000)) {
      st.lastLog[key] = t;
      log(msg);
    }
  }

  function memLen() { return st.mem.length - st.memHead; }

  function memCompact() {
    if (st.memHead > 4096 && st.memHead * 2 > st.mem.length) {
      st.mem = st.mem.slice(st.memHead);
      st.memHead = 0;
    }
  }

  function memTake(maxEvents, maxBytes) {
    const items = [];
    let bytes = 0;
    while (st.memHead < st.mem.length && items.length < maxEvents) {
      const e = st.mem[st.memHead];
      if (items.length > 0 && bytes + e.line.length + 1 > maxBytes) break;
      items.push(e);
      bytes += e.line.length + 1;
      st.mem[st.memHead++] = undefined;
    }
    memCompact();
    return items;
  }

  function memUnshift(items) {
    if (items.length === 0) return;
    if (st.memHead >= items.length) {
      for (let i = items.length - 1; i >= 0; i--) st.mem[--st.memHead] = items[i];
    } else {
      st.mem = items.concat(st.mem.slice(st.memHead));
      st.memHead = 0;
    }
  }

  function queueDepth() {
    let n = memLen() + (st.inflight ? st.inflight.items.length : 0);
    for (const s of st.spool) n += s.lines ? s.lines.length - s.pos : s.count;
    return n;
  }

  function spoolBytes() {
    let b = 0;
    for (const s of st.spool) b += s.bytes;
    return b;
  }

  // Intake: events from Lua are serialised and queued.
  function push(events) {
    if (st.refused || !st.boot || !Array.isArray(events)) return;
    const t0 = process.hrtime.bigint();
    const at = now();
    for (let i = 0; i < events.length; i++) {
      const ev = events[i];
      if (!ev || typeof ev !== 'object') continue;
      if (ev.type === 'agent.heartbeat' && ev.data && typeof ev.data === 'object') {
        // Heartbeat: adds the transport queue depth and drop counters
        ev.data.queue = (num(ev.data.queue) || 0) + queueDepth();
        const d = Array.isArray(ev.data.drops) ? {} : Object.assign({}, ev.data.drops || {});
        for (const k of Object.keys(st.drops)) d['js_' + k] = st.drops[k];
        ev.data.drops = d;
      }
      let rec;
      try {
        rec = serialize(ev, st.boot);
      } catch (e) {
        drop('serialize');
        continue;
      }
      rec.at = at;
      st.mem.push(rec);
    }
    st.serNs += Number(process.hrtime.bigint() - t0);
    st.serCount += events.length;
    while (memLen() > o.memEvents) spill(o.spillChunk);
    if (st.stopped) persistSync();
  }

  // Spool: spilled events are written as gzip NDJSON segments under spool/ (async fs).
  function segName(s) { return `${s.boot}-${pad12(s.first)}-${pad12(s.last)}-${s.count}.ndjson.gz`; }

  function spill(n) {
    const items = memTake(n, Infinity);
    if (items.length === 0) return;
    const seg = {
      boot: st.boot, first: items[0].seq, last: items[items.length - 1].seq, count: items.length,
      lines: items, pos: 0, written: false, writing: true, done: false, file: null,
      bytes: Math.ceil(items.reduce((a, e) => a + e.line.length + 1, 0) / 6), // bytes: estimate until the segment is written
      stripped: false,
    };
    st.spool.push(seg);
    writeSegment(seg, seg.lines).then(() => {
      if (seg.done) { unlink(seg); return; }
      // Memory: only the segment being replayed keeps its lines
      if (st.spool[0] !== seg) seg.lines = null;
      enforceCap();
    }).catch((e) => {
      seg.writing = false;
      st.lastError = 'spool write failed: ' + e.message;
      logOnce('spoolw', 'spool write failed: ' + e.message);
      // Bound: only the segment being replayed may stay in memory, so later unwritable segments are dropped
      if (st.spool[0] !== seg && !seg.done) {
        drop('spool_write_failed', seg.count);
        finishSegment(seg);
      }
    });
  }

  async function writeSegment(seg, lines) {
    if (!o.spoolDir) throw new Error('no spool dir');
    await fsp.mkdir(o.spoolDir, { recursive: true });
    const body = lines.map((e) => e.line).join('\n') + '\n';
    const gz = await new Promise((res, rej) => zlib.gzip(body, (err, b) => (err ? rej(err) : res(b))));
    const name = segName(seg);
    const file = path.join(o.spoolDir, name);
    const tmp = file + '.tmp';
    await fsp.writeFile(tmp, gz);
    await fsp.rename(tmp, file);
    if (seg.file && seg.file !== file) await fsp.unlink(seg.file).catch(() => {});
    seg.file = file;
    seg.bytes = gz.length;
    seg.written = true;
    seg.writing = false;
  }

  function unlink(seg) {
    if (seg.file) fsp.unlink(seg.file).catch(() => {});
  }

  function parseLines(text) {
    const out = [];
    const parts = text.split('\n');
    for (const line of parts) {
      if (!line) continue;
      const m = PREFIX_RE.exec(line);
      if (!m) { drop('spool_bad_line'); continue; }
      out.push({ type: m[1], ts: Number(m[2]), seq: Number(m[3]), line });
    }
    return out;
  }

  function loadSegment(seg) {
    seg.loading = true;
    fsp.readFile(seg.file)
      .then((buf) => new Promise((res, rej) => zlib.gunzip(buf, (e, b) => (e ? rej(e) : res(b)))))
      .then((b) => { seg.lines = parseLines(b.toString('utf8')); seg.count = seg.lines.length; seg.loading = false; })
      .catch((e) => {
        seg.loading = false;
        drop('spool_corrupt', seg.count);
        logOnce('spoolr', `spool segment ${seg.file} unreadable, dropped ${seg.count} events: ${e.message}`);
        finishSegment(seg);
      });
  }

  function finishSegment(seg) {
    seg.done = true;
    seg.lines = null;
    const i = st.spool.indexOf(seg);
    if (i >= 0) st.spool.splice(i, 1);
    if (seg.written) unlink(seg);
  }

  // Cap: strips position.sample from the oldest segments first, then deletes whole oldest segments; one async pass at a time.
  async function enforceCap() {
    if (st.capRunning) return;
    st.capRunning = true;
    try {
      for (const seg of st.spool.slice()) {
        if (spoolBytes() <= o.spoolBytes) return;
        if (seg.stripped || seg.done || seg.writing || !seg.written || seg.pos > 0 || (st.inflight && st.inflight.seg === seg)) continue;
        let lines = seg.lines;
        if (!lines) {
          const buf = await fsp.readFile(seg.file);
          lines = parseLines((await new Promise((res, rej) => zlib.gunzip(buf, (e, b) => (e ? rej(e) : res(b))))).toString('utf8'));
        }
        if (seg.done || seg.pos > 0 || (st.inflight && st.inflight.seg === seg)) continue;
        const kept = lines.filter((e) => e.type !== 'position.sample');
        seg.stripped = true;
        const removed = lines.length - kept.length;
        if (removed === 0) continue;
        drop('spool_cap_position', removed);
        if (kept.length === 0) { finishSegment(seg); continue; }
        seg.count = kept.length;
        seg.capping = true; // capping: keeps replay off this segment while its lines are swapped for the stripped ones
        try {
          await writeSegment(seg, kept);
          if (seg.lines) seg.lines = kept;
        } finally {
          seg.capping = false;
        }
      }
      // Delete: still over the cap, so whole segments go, oldest first
      while (spoolBytes() > o.spoolBytes && st.spool.length > 1) {
        const seg = st.spool.find((s) => !(st.inflight && st.inflight.seg === s) && s.written && !s.writing);
        if (!seg) break;
        drop('spool_cap_segment', seg.lines ? seg.lines.length - seg.pos : seg.count);
        logOnce('spoolcap', `spool over ${Math.round(o.spoolBytes / 1048576)} MB: dropped oldest segment (${seg.count} events)`);
        finishSegment(seg);
      }
    } catch (e) {
      logOnce('capErr', 'spool cap enforcement failed: ' + e.message);
    } finally {
      st.capRunning = false;
    }
  }

  async function loadSpoolDir() {
    try {
      await indexSpoolDir();
    } finally {
      st.spoolLoaded = true;
    }
  }

  async function indexSpoolDir() {
    if (!o.spoolDir) return;
    let names = [];
    try { names = await fsp.readdir(o.spoolDir); } catch (e) { return; }
    const segs = [];
    for (const name of names) {
      const full = path.join(o.spoolDir, name);
      if (name.endsWith('.tmp')) { fsp.unlink(full).catch(() => {}); continue; }
      const m = SEG_RE.exec(name);
      if (!m) continue;
      let size = 0;
      try { size = (await fsp.stat(full)).size; } catch (e) { continue; }
      segs.push({ boot: m[1], first: Number(m[2]), last: Number(m[3]), count: Number(m[4]), file: full, bytes: size,
        lines: null, pos: 0, written: true, writing: false, done: false, stripped: false });
    }
    segs.sort((a, b) => (a.boot < b.boot ? -1 : a.boot > b.boot ? 1 : a.first - b.first));
    // Order: indexed segments predate this start, so they go to the front
    st.spool = segs.concat(st.spool);
    if (segs.length) log(`spool: ${segs.length} segment(s), ${segs.reduce((a, s) => a + s.count, 0)} events to replay`);
  }

  /** Persist: writes everything not yet acked synchronously, on resource stop. */
  function persistSync() {
    if (!o.spoolDir) return;
    try {
      fs.mkdirSync(o.spoolDir, { recursive: true });
      const write = (boot, items) => {
        if (!items.length) return;
        const seg = { boot, first: items[0].seq, last: items[items.length - 1].seq, count: items.length };
        const body = items.map((e) => e.line).join('\n') + '\n';
        fs.writeFileSync(path.join(o.spoolDir, segName(seg)), zlib.gzipSync(body));
      };
      if (st.inflight && !st.inflight.seg) write(st.inflight.boot, st.inflight.items);
      for (const seg of st.spool) {
        if (!seg.written && seg.lines) { write(seg.boot, seg.lines.slice(seg.pos)); seg.written = true; }
      }
      write(st.boot, st.mem.slice(st.memHead));
      st.mem = []; st.memHead = 0;
      if (st.inflight && !st.inflight.seg) st.inflight = null;
    } catch (e) {
      log('could not persist queue on stop: ' + e.message);
    }
  }

  // Send: one batch in flight in seq order, gzip unless the endpoint is loopback, keep-alive.
  function nextBatch(t) {
    if (st.spool.length) {
      const seg = st.spool[0];
      if (seg.capping || (seg.writing && !seg.lines)) return null;
      if (!seg.lines) { if (!seg.loading) loadSegment(seg); return null; }
      if (seg.pos >= seg.lines.length) { finishSegment(seg); return null; }
      if (t < st.replayNextAt) return null;
      const items = [];
      let bytes = 0;
      for (let i = seg.pos; i < seg.lines.length && items.length < st.limitEvents; i++) {
        const e = seg.lines[i];
        if (items.length > 0 && bytes + e.line.length + 1 > st.limitBytes) break;
        items.push(e);
        bytes += e.line.length + 1;
      }
      st.replayNextAt = t + Math.ceil((items.length / o.replayRate) * 1000);
      return { seg, boot: seg.boot, items };
    }
    const n = memLen();
    if (n === 0) return null;
    const oldest = st.mem[st.memHead];
    if (n < st.limitEvents && t - oldest.at < o.batchAgeMs) return null;
    return { seg: null, boot: st.boot, items: memTake(st.limitEvents, st.limitBytes) };
  }

  /** Requeue: returns an unsent batch to where it came from, keeping order. */
  function requeue(b) {
    if (!b.seg) memUnshift(b.items);
  }

  function pump() {
    if (st.refused || !url || !st.boot || st.stopped || !st.spoolLoaded) return;
    const t = now();
    if (st.inflight) {
      if (!st.inflight.sending && t >= st.nextAttemptAt) send(st.inflight);
      return;
    }
    if (t < st.nextAttemptAt) return;
    const b = nextBatch(t);
    if (!b || b.items.length === 0) return;
    st.inflight = b;
    send(b);
  }

  function retryLater(b, ms, err) {
    b.sending = false;
    st.lastError = err;
    st.nextAttemptAt = now() + ms;
  }

  function backoff(b, err) {
    retryLater(b, st.backoff, err);
    logOnce('neterr', `daemon unreachable (${err}); retrying, ${queueDepth()} events queued`);
    st.backoff = Math.min(st.backoff * 2, o.backoffMaxMs);
  }

  function send(b) {
    b.sending = true;
    const body = Buffer.from(b.items.map((e) => e.line).join('\n') + '\n', 'utf8');
    const t = now();
    const replay = b.items.some((e) => t - e.ts > o.replayFlagAgeMs);
    // Settle: each attempt settles once, even if an error follows an end or a timeout
    let settled = false;
    const once = (fn) => (...args) => { if (!settled) { settled = true; fn(...args); } };
    const fail = once((err) => backoff(b, err));
    const done = once((status, text) => onResponse(b, status, text));
    const post = (payload) => {
      const headers = {
        'Authorization': 'Bearer ' + o.token,
        'Content-Type': 'application/x-ndjson',
        'Content-Length': payload.length,
      };
      if (gzip) headers['Content-Encoding'] = 'gzip';
      if (replay) headers['X-Atlas-Replay'] = '1';
      const req = (secure ? https : http).request({
        protocol: url.protocol, hostname: url.hostname, port: url.port || (secure ? 443 : 80),
        path: url.pathname + url.search, method: 'POST', headers, agent, timeout: o.requestTimeoutMs,
      }, (res) => {
        const chunks = [];
        res.on('data', (c) => { if (chunks.length < 64) chunks.push(c); });
        res.on('end', () => done(res.statusCode, Buffer.concat(chunks).toString('utf8')));
        res.on('error', (e) => fail(e.message));
      });
      req.on('timeout', () => req.destroy(new Error('timeout')));
      req.on('error', (e) => fail(e.code || e.message));
      req.end(payload);
    };
    if (gzip) {
      zlib.gzip(body, (err, gz) => (err ? fail('gzip: ' + err.message) : post(gz)));
    } else {
      post(body);
    }
  }

  function onResponse(b, status, text) {
    if (status === 200) {
      let acked = NaN;
      try { acked = num(JSON.parse(text).acked_seq); } catch (e) { /* bad body: handled below */ }
      if (!Number.isFinite(acked)) return backoff(b, 'bad ack body');
      ack(b, acked);
      return;
    }
    if (status === 401 || status === 403) {
      logOnce('auth', `^1daemon rejected the token (HTTP ${status}). Check atlas:token (re-copy it from the Atlas setup page).^7`, 60000);
      return retryLater(b, o.authBackoffMs, 'unauthorized');
    }
    if (status === 413) {
      if (b.items.length <= 1) {
        drop('too_large', b.items.length);
        return ack(b, Infinity);
      }
      // Shrink: halves the batch limits until a send succeeds
      st.limitEvents = Math.max(1, Math.floor(b.items.length / 2));
      st.limitBytes = Math.max(1024, Math.floor(b.items.reduce((a, e) => a + e.line.length + 1, 0) / 2));
      requeue(b);
      st.inflight = null;
      st.replayNextAt = 0;
      return;
    }
    if (status === 400) {
      drop('malformed', b.items.length);
      logOnce('400', `daemon rejected a batch as malformed (${b.items.length} events dropped): ${text.slice(0, 200)}`);
      return ack(b, Infinity);
    }
    backoff(b, 'HTTP ' + status);
  }

  function ack(b, acked) {
    const freed = b.items.filter((e) => e.seq <= acked).length;
    if (freed === 0 && acked !== Infinity) {
      // Stall: the daemon acknowledged nothing of this batch, so back off instead of spinning
      b.stalls = (b.stalls || 0) + 1;
      if (b.stalls < 5) return backoff(b, 'ack below batch');
      drop('ack_stall', b.items.length);
      acked = Infinity;
    }
    const all = acked === Infinity ? b.items.length : freed;
    st.sentEvents += all;
    st.sentBatches += 1;
    st.backoff = o.backoffMinMs;
    st.nextAttemptAt = 0;
    st.lastError = null;
    st.lastAckAt = now();
    if (acked !== Infinity) { st.ackedSeq = acked; st.ackedBoot = b.boot; }
    // Recover: limits shrunk by a 413 grow back after a success
    st.limitEvents = Math.min(o.batchEvents, st.limitEvents * 2);
    st.limitBytes = Math.min(o.batchBytes, st.limitBytes * 2);
    if (b.seg) {
      b.seg.pos += all;
      if (b.seg.pos >= b.seg.lines.length) finishSegment(b.seg);
    } else if (all < b.items.length) {
      memUnshift(b.items.slice(all));
    }
    st.inflight = null;
  }

  // Lifecycle: start, stop and the pump timer.
  let timer = null;
  function start(boot) {
    st.boot = boot;
    if (insecureRemote) log('WARNING: atlas:endpoint uses http to a remote host, so the token is sent unencrypted. Use https.');
    if (!timer && o.autoPump !== false) timer = setInterval(pump, o.pumpMs);
  }

  function refuse(reason) {
    st.refused = reason;
    st.mem = []; st.memHead = 0;
  }

  function stop() {
    st.stopped = true;
    if (timer) clearInterval(timer);
    timer = null;
    persistSync();
    if (agent) agent.destroy();
  }

  function stats() {
    return {
      state: st.refused ? 'refused' : !url ? 'bad_endpoint' : st.inflight ? (st.inflight.sending ? 'sending' : 'backoff') : 'idle',
      endpoint: url ? url.origin : String(o.endpoint),
      gzip,
      insecureRemote,
      mem: memLen(),
      inflight: st.inflight ? st.inflight.items.length : 0,
      spoolFiles: st.spool.length,
      spoolEvents: st.spool.reduce((a, s) => a + (s.lines ? s.lines.length - s.pos : s.count), 0),
      spoolBytes: spoolBytes(),
      ackedSeq: st.ackedSeq,
      ackedBoot: st.ackedBoot,
      lastAckAgoMs: st.lastAckAt ? now() - st.lastAckAt : null,
      lastError: st.lastError,
      drops: Object.assign({}, st.drops),
      serializeUsAvg: st.serCount ? Math.round(st.serNs / st.serCount / 10) / 100 : 0,
      sentEvents: st.sentEvents,
      sentBatches: st.sentBatches,
    };
  }

  return { push, pump, start, stop, refuse, stats, loadSpoolDir, _state: st, _options: o, _enforceCap: enforceCap };
}

// Cfg scan: best-effort check of the server.cfg files FXServer started with (following exec lines) for setr or sets of the token.
// Runtime: the client hash report in core.lua is the definitive check.
async function scanCfgForExposedToken(argv, cwd) {
  // Command line: `+setr atlas:token ...` replicates the token just like a cfg line
  for (let i = 0; i < argv.length - 1; i++) {
    const m = /^\+(setr|sets)$/i.exec(argv[i]);
    if (m && argv[i + 1].replace(/^"|"$/g, '').toLowerCase() === 'atlas:token') {
      return { file: 'the command line', command: m[1].toLowerCase() };
    }
  }
  const start = [];
  for (let i = 0; i < argv.length - 1; i++) if (argv[i] === '+exec') start.push(argv[i + 1]);
  if (start.length === 0) start.push('server.cfg');
  const seen = new Set();
  const queue = start.map((f) => ({ f, depth: 0 }));
  while (queue.length) {
    const { f, depth } = queue.shift();
    const full = path.resolve(cwd, f.replace(/^"|"$/g, ''));
    if (seen.has(full) || depth > 4) continue;
    seen.add(full);
    let text;
    try { text = await fsp.readFile(full, 'utf8'); } catch (e) { continue; }
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.replace(/(^|\s)(#|\/\/).*$/, '').trim();
      const m = /^(setr|sets)\s+"?atlas:token"?(\s|$)/i.exec(line);
      if (m) return { file: full, command: m[1].toLowerCase() };
      const ex = /^exec\s+"?([^"\s]+)"?/i.exec(line);
      if (ex) queue.push({ f: ex[1], depth: depth + 1 });
    }
  }
  return null;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { createTransport, serialize, scanCfgForExposedToken, isLoopback, DEFAULTS };
}

// FiveM wiring: runs only when FXServer globals exist.
if (typeof GetCurrentResourceName === 'function' && typeof on === 'function') {
  const RES = GetCurrentResourceName();
  const log = (m) => console.log('^5[atlas]^7 ' + m);
  const token = GetConvar('atlas:token', '');
  const endpoint = GetConvar('atlas:endpoint', 'http://127.0.0.1:7271');
  const spoolMb = Number(GetConvar('atlas:spool_mb', '200')) || 200;
  const transport = createTransport({
    endpoint,
    token,
    spoolDir: path.join(GetResourcePath(RES), 'spool'),
    spoolBytes: spoolMb * 1024 * 1024,
    log,
  });
  let initialised = false;

  const fromSelf = () => {
    const inv = GetInvokingResource();
    return !inv || inv === RES;
  };

  const refuse = (reason) => {
    transport.refuse(reason);
    emit('atlas:internal:refused', reason);
  };

  if (!token) {
    refuse('atlas:token is not set');
  }

  scanCfgForExposedToken(process.argv || [], process.cwd()).then((hit) => {
    if (hit) {
      refuse(`atlas:token is set with \`${hit.command}\` in ${hit.file}. ` +
        (hit.command === 'setr' ? 'setr replicates it to every client' : 'sets publishes it in /info.json') +
        '. Use `set atlas:token ...`, rotate the token in the Atlas dashboard, then restart ' + RES + '.');
    }
  }).catch(() => {});

  on('atlas:internal:init', (info) => {
    if (!fromSelf() || initialised || !info || !info.boot) return;
    initialised = true;
    // Order: boot is set first so batches arriving meanwhile are queued; sending starts once older spool segments are indexed
    transport.start(String(info.boot));
    transport.loadSpoolDir().catch((e) => log('spool index failed: ' + e.message));
    log(`transport ready (agent ${info.version}, boot ${info.boot}, endpoint ${endpoint})`);
  });

  on('atlas:internal:batch', (events) => {
    if (!fromSelf()) return;
    try { transport.push(events); } catch (e) { log('batch intake failed: ' + e.message); }
  });

  on('atlas:internal:refuse', (reason) => {
    if (fromSelf()) transport.refuse(String(reason));
  });

  on('atlas:internal:hello', () => {
    if (fromSelf()) emit('atlas:internal:ready');
  });

  on('onResourceStop', (res) => {
    if (res === RES) transport.stop();
  });

  setInterval(() => emit('atlas:internal:stats', transport.stats()), 2000);

  // Hello: announces this runtime in case core.lua loaded first
  emit('atlas:internal:ready');
}
