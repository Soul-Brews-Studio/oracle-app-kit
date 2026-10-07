// oracle-fb bridge — 127.0.0.1 only. Two halves of "Facebook ↔ oracle":
//   FORWARD  extension → POST /thread   a whole post + comments, kept as ~/.oracle-fb/threads/<id>.md|json
//   BACK     agent → fbreply → POST /reply → WebSocket → extension types it into that comment's reply box.
//            It stops at the box: a human presses Enter. Nothing here ever posts.
// Who may talk: the extension (Origin chrome-extension://<id>) on /thread and /ws; the CLI (x-fb-token header,
// token in ~/.oracle-fb/token) on /reply, /threads. A web page has neither, so it cannot reach either half.
import { mkdirSync, readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Database } from 'bun:sqlite';
import { appendFileSync } from 'node:fs';
import { nodesOf, type N } from './nodes.ts';

const PORT = Number(process.env.ORACLE_FB_PORT || 4747);
const HOME = join(homedir(), '.oracle-fb'), DIR = join(HOME, 'threads');
const EXT_ID = process.env.ORACLE_FB_EXT || 'hadknpihalkpmhfdppedhdoaeaddcgig';
mkdirSync(DIR, { recursive: true });
import('node:fs').then(fs => fs.chmodSync(HOME, 0o700));   // the stream holds other people's posts and messages: this Mac's user only
const TOKEN = existsSync(join(HOME, 'token')) ? readFileSync(join(HOME, 'token'), 'utf8').trim() : '';
if (!TOKEN) { console.error(`✗ no token\n  (umask 077; openssl rand -hex 24 > ${HOME}/token)`); process.exit(1); }

const fromExtension = (req: Request) => req.headers.get('origin') === `chrome-extension://${EXT_ID}`;
const fromCli = (req: Request) => req.headers.get('x-fb-token') === TOKEN;
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const safeId = (s: string) => /^[a-z0-9]{4,16}$/.test(s) ? s : '';

const exts = new Set<any>();                // every connected extension (Chrome, Ego …); a reply goes to the newest
const waiting = new Map<string, (r: any) => void>();
const uaOf = (e: any) => String(e.data.ua);
const browserName = (e: any) => (uaOf(e).match(/Chrome\/[\d.]+/) || ['browser'])[0].replace(/(\d+)\..*/, '$1');   // Chrome/153
// every browser the bridge has met: connected now, or when it was last seen (kept across restarts)
const SEEN = join(HOME, 'seen.json');
const seen: Record<string, { version: string; since: number; lastSeen: number; connected: boolean }> = existsSync(SEEN) ? JSON.parse(readFileSync(SEEN, 'utf8')) : {};
for (const k in seen) seen[k].connected = false;   // a fresh bridge has nobody yet
const saveSeen = () => writeFileSync(SEEN, JSON.stringify(seen, null, 1));
const BOOT = Date.now();

// ── the surrogate stream: append-only JSONL per Bangkok day (the record) + SQLite FTS (the index, rebuildable) ──
const STREAM = join(HOME, 'stream'); mkdirSync(STREAM, { recursive: true });
const db = new Database(join(HOME, 'stream.db'));
db.exec(`PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS ev (id INTEGER PRIMARY KEY, ts INTEGER, day TEXT, browser TEXT, tab INTEGER, kind TEXT, key TEXT,
    author TEXT, link TEXT, url TEXT, text TEXT, post TEXT, media INTEGER);
  CREATE UNIQUE INDEX IF NOT EXISTS ev_once ON ev(day, kind, key) WHERE kind IN ('seen', 'comment-seen');   -- seen once a day
  CREATE INDEX IF NOT EXISTS ev_day ON ev(day, ts);
  CREATE VIRTUAL TABLE IF NOT EXISTS ev_fts USING fts5(author, text, content='ev', content_rowid='id', tokenize='trigram');`);   // trigram: Thai substrings work
// ── the graph: Facebook is nodes + edges. Ids come from the URLs (parsed HERE, so a rebuild from the JSONL gives the
//    same graph). Node ids: user:<name|num>  post:<pfbid|num>  comment:<num>  photo:<fbid>  video:<num>  album:<num>
//    group:<id|name>  url:<external href>  me:nat
db.exec(`CREATE TABLE IF NOT EXISTS node (id TEXT PRIMARY KEY, type TEXT, label TEXT, url TEXT, first_seen INTEGER, last_seen INTEGER, seen INTEGER DEFAULT 0);
  CREATE TABLE IF NOT EXISTS edge (src TEXT, rel TEXT, dst TEXT, first_seen INTEGER, last_seen INTEGER, n INTEGER DEFAULT 1, PRIMARY KEY (src, rel, dst));
  CREATE INDEX IF NOT EXISTS edge_dst ON edge(dst, rel);`);
const upNode = db.prepare(`INSERT INTO node (id, type, label, url, first_seen, last_seen, seen) VALUES ($id, $type, $label, $url, $ts, $ts, $seen)
  ON CONFLICT(id) DO UPDATE SET label = CASE WHEN excluded.label <> '' THEN excluded.label ELSE node.label END,
    url = CASE WHEN node.url = '' THEN excluded.url ELSE node.url END, last_seen = max(node.last_seen, excluded.last_seen), seen = node.seen + excluded.seen`);
const upEdge = db.prepare(`INSERT INTO edge (src, rel, dst, first_seen, last_seen) VALUES ($s, $r, $d, $ts, $ts)
  ON CONFLICT(src, rel, dst) DO UPDATE SET last_seen = max(edge.last_seen, excluded.last_seen), n = edge.n + 1`);
const ME = 'me:nat';
const mainNode = (href: string) => { const ns = nodesOf(href); return ns.find(n => n.type === 'post') || ns.find(n => n.type === 'video') || ns.find(n => n.type === 'photo') || ns[0]; };
const getNode = db.prepare('SELECT id, seen, first_seen, last_seen FROM node WHERE id = ?');
function graph(e: any) {
  const ts = Number(e.ts) || Date.now();
  const node = (n: N | undefined, label = '', seen = 0) => { if (n) upNode.run({ $id: n.id, $type: n.type, $label: label, $url: n.url, $ts: ts, $seen: seen }); return n?.id; };
  const edge = (s?: string, r?: string, d?: string) => { if (s && d && s !== d) upEdge.run({ $s: s, $r: r!, $d: d, $ts: ts }); };
  const first = (href: string, type: string) => nodesOf(href).find(n => n.type === type);
  const main = (href: string) => { const ns = nodesOf(href); return ns.find(n => n.type === 'post') || ns.find(n => n.type === 'video') || ns.find(n => n.type === 'photo') || ns[0]; };
  node({ id: ME, type: 'me', url: '' }, 'Nat Weerawan');
  if (e.kind === 'seen') {
    const P = node(main(e.link), String(e.text || '').replace(/\s+/g, ' ').slice(0, 120), 1);
    const A = node(first(e.authorUrl, 'user') || first(e.authorUrl, 'group'), e.author);
    edge(A, 'authored', P); edge(ME, 'saw', P);
    edge(P, 'in_group', node(first(e.group, 'group')));
    for (const m of e.mediaUrls || []) { const M = node(main(m)); edge(P, 'has_media', M); edge(M, 'in_album', node(first(m, 'album'))); }
    for (const s of e.shared || []) edge(P, 'shares', node(main(s)));
    for (const x of e.external || []) edge(P, 'links_to', node(nodesOf(x)[0]));
  } else if (e.kind === 'comment-seen') {
    const ns = nodesOf(e.link), q = (() => { try { return new URL(e.link).searchParams; } catch { return new URLSearchParams(); } })();
    const C = node(ns.find(n => n.id === `comment:${q.get('reply_comment_id') || q.get('comment_id')}`), String(e.text || '').replace(/\s+/g, ' ').slice(0, 120), 1);
    if (q.get('reply_comment_id') && q.get('comment_id')) edge(C, 'reply_to', node(ns.find(n => n.id === `comment:${q.get('comment_id')}`)));
    edge(C, 'comment_on', node(ns.find(n => n.type === 'post') || ns.find(n => n.type === 'video') || ns.find(n => n.type === 'photo')));
    edge(node(first(e.authorUrl, 'user'), e.author), 'wrote', C); edge(ME, 'saw', C);
    for (const x of e.external || []) edge(C, 'links_to', node(nodesOf(x)[0]));
  } else if (['react', 'share', 'open-comments', 'open-media', 'oracle'].includes(e.kind)) {
    edge(ME, { react: 'reacted', share: 'shared', 'open-comments': 'opened_comments', 'open-media': 'opened', oracle: 'sent_to_oracle' }[e.kind as string],
      node(main(e.link || e.post || '')));
  }
}
const insEv = db.prepare(`INSERT OR IGNORE INTO ev (ts, day, browser, tab, kind, key, author, link, url, text, post, media)
  VALUES ($ts, $day, $browser, $tab, $kind, $key, $author, $link, $url, $text, $post, $media)`);
const insFts = db.prepare('INSERT INTO ev_fts (rowid, author, text) VALUES (?, ?, ?)');
const bkkDay = (ms: number) => new Date(ms).toLocaleDateString('en-CA', { timeZone: 'Asia/Bangkok' });   // 2026-10-07
function storeEvents(list: any[]) {
  let kept = 0;
  const tx = db.transaction((rows: any[]) => {
    for (const e of rows) {
      const day = bkkDay(Number(e.ts) || Date.now());
      appendFileSync(join(STREAM, `${day}.jsonl`), JSON.stringify(e) + '\n');
      const r = insEv.run({ $ts: Number(e.ts) || Date.now(), $day: day, $browser: String(e.browser || ''), $tab: e.tab ?? null, $kind: String(e.kind || ''),
        $key: String(e.key || ''), $author: String(e.author || ''), $link: String(e.link || ''), $url: String(e.url || ''),
        $text: String(e.text || ''), $post: String(e.post || ''), $media: Number(e.media || 0) });
      if (r.changes) { kept++; insFts.run(Number(r.lastInsertRowid), String(e.author || ''), String(e.text || '')); }
      graph(e);   // every event, deduped or not: edges count repeats
    }
  });
  tx(list);
  return kept;
}
const stamp = () => new Date().toTimeString().slice(0, 8);   // log lines carry the time, so a flapping browser is visible
const statusPayload = () => ({ type: 'status', up: Math.round((Date.now() - BOOT) / 1000), port: PORT, extension: EXT_ID,
  threads: readdirSync(DIR).filter(f => f.endsWith('.json')).length,
  browsers: Object.entries(seen).map(([browser, v]) => ({ browser, ...v })) });
const broadcast = () => { const m = JSON.stringify(statusPayload()); for (const e of exts) try { e.send(m); } catch {} };   // every extension always knows who is connected
const newest = (list: any[]) => list.sort((a, b) => b.data.at - a.data.at)[0];
function ask(ext: any, msg: any, ms = 20_000) {   // one request over a socket, answered by {type:'result', rid}
  const rid = crypto.randomUUID();
  return new Promise<any>(res => { waiting.set(rid, res); setTimeout(() => res({ ok: false, note: 'timeout' }), ms); ext.send(JSON.stringify({ ...msg, rid })); });
}

Bun.serve({
  hostname: '127.0.0.1', port: PORT, idleTimeout: 120,   // a reply waits up to 60 s for the page; Bun's default 10 s would cut it off
  async fetch(req, server) {
    const u = new URL(req.url);
    if (u.pathname === '/ws') {
      if (!fromExtension(req)) return json({ error: 'extension only' }, 403);
      return server.upgrade(req, { data: { ua: req.headers.get('user-agent') || '', at: Date.now() } }) ? undefined : json({ error: 'upgrade failed' }, 400);
    }
    if (u.pathname === '/thread' && req.method === 'POST') {
      if (!fromExtension(req)) return json({ error: 'extension only' }, 403);
      const t = await req.json() as any, id = safeId(String(t.id || ''));
      if (!id) return json({ error: 'bad id' }, 400);
      const cmd = `bun ${import.meta.dir}/fbreply.ts`;
      const br = (String(t.ua || '').match(/Chrome\/\d+/) || [''])[0];
      const aim = t.tab?.id ? ` --to ${br} --tab ${t.tab.id}` : '';   // the exact tab the click came from (its own id)
      const footer = `\n\n---\nReply path — types into that comment's box in ${br || 'the browser'}${t.tab?.id ? ` tab ${t.tab.id}` : ''}; a human presses Enter:\n    ${cmd}${aim} ${id} c1 "your reply"\n    ${cmd} --tabs   (is tab ${t.tab?.id ?? '?'} still open?)\n`;
      writeFileSync(join(DIR, `${id}.md`), String(t.md || '') + footer);
      writeFileSync(join(DIR, `${id}.json`), JSON.stringify({ id, url: t.url, title: t.title, at: new Date().toISOString(), tab: t.tab || null, ua: t.ua || '', comments: t.comments || [] }, null, 1));
      console.log(`thread ${id}  ${(t.comments || []).length} comments  ${t.url}`);
      return json({ ok: true, id, file: join(DIR, `${id}.md`) });
    }
    if (u.pathname === '/threads') {
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      return json(readdirSync(DIR).filter(f => f.endsWith('.json')).map(f => JSON.parse(readFileSync(join(DIR, f), 'utf8'))));
    }
    if (u.pathname === '/events' && req.method === 'POST') {   // extension → stream
      if (!fromExtension(req)) return json({ error: 'extension only' }, 403);
      const list = await req.json() as any[];
      if (!Array.isArray(list) || list.length > 2000) return json({ error: 'bad batch' }, 400);
      const kept = storeEvents(list);
      console.log(`${stamp()} stream +${kept}/${list.length}  ${[...new Set(list.map(e => e.kind))].join(',')}`);
      // tell the page which node each seen post became, so its 🔮 chip can show "collected" (Nat: "check uuid collected or not")
      const ids: Record<string, any> = {};
      for (const e of list) if (e.kind === 'seen' && e.key) { const n = mainNode(e.link || ''); ids[e.key] = n ? (getNode.get(n.id) || { id: n.id }) : { id: '', note: 'no link on this post (sponsored?) — kept by text hash' }; }
      return json({ ok: true, kept, ids });
    }
    if (u.pathname === '/graph') {   // graph.ts: one node and its neighbours, or stats
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      if (u.searchParams.has('stats')) return json({
        nodes: db.query('SELECT type, count(*) n FROM node GROUP BY type ORDER BY n DESC').all(),
        edges: db.query('SELECT rel, count(*) n FROM edge GROUP BY rel ORDER BY n DESC').all() });
      let id = u.searchParams.get('id') || '';
      if (/^https?:/.test(id)) id = (nodesOf(id).find(n => ['comment', 'post', 'video', 'photo'].includes(n.type)) || nodesOf(id)[0])?.id || id;
      const n = db.query('SELECT * FROM node WHERE id = ?').get(id);
      if (!n) return json({ error: `no node ${id}`, try: db.query("SELECT id, type, label FROM node WHERE label LIKE ? OR id LIKE ? LIMIT 10").all(`%${u.searchParams.get('id')}%`, `%${u.searchParams.get('id')}%`) }, 404);
      const out = db.query('SELECT e.rel, e.n, x.* FROM edge e JOIN node x ON x.id = e.dst WHERE e.src = ? ORDER BY e.rel').all(id);
      const inn = db.query('SELECT e.rel, e.n, x.* FROM edge e JOIN node x ON x.id = e.src WHERE e.dst = ? ORDER BY e.rel').all(id);
      return json({ node: n, out, in: inn });
    }
    if (u.pathname === '/stream') {   // seen.ts: search / list / stats
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      const q = u.searchParams.get('q') || '', day = u.searchParams.get('day') || '', kind = u.searchParams.get('kind') || '';
      const limit = Math.min(Number(u.searchParams.get('limit') || 30), 500);
      const since = Number(u.searchParams.get('since') || 0);   // seen --follow: only what is newer than the last row shown
      if (u.searchParams.has('stats')) return json(db.query(`SELECT day, kind, count(*) n FROM ev GROUP BY day, kind ORDER BY day DESC, n DESC LIMIT 200`).all());
      const where = [day ? 'ev.day = $day' : '1', kind ? 'ev.kind = $kind' : '1', since ? 'ev.id > $since' : '1'].join(' AND ');
      const rows = q.length >= 3
        ? db.query(`SELECT ev.* FROM ev_fts JOIN ev ON ev.id = ev_fts.rowid WHERE ev_fts MATCH $q AND ${where} ORDER BY ev.ts DESC LIMIT $limit`).all({ $q: `"${q.replace(/"/g, '""')}"`, $day: day, $kind: kind, $limit: limit, $since: since })
        : db.query(`SELECT * FROM ev WHERE ${where} ORDER BY ${since ? 'id ASC' : 'ts DESC'} LIMIT $limit`).all({ $day: day, $kind: kind, $limit: limit, $since: since });
      return json(rows);
    }
    if (u.pathname === '/status') {   // fbreply --status
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      return json(statusPayload());
    }
    if (u.pathname === '/tabs') {   // every Facebook tab, in every connected browser
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      const rows = await Promise.all([...exts].map(async e => {
        const r = await ask(e, { type: 'tabs' }, 4000);   // an older extension never answers: say so instead of hanging
        return r.tabs ? r.tabs.map((t: any) => ({ browser: browserName(e), ...t })) : [{ browser: browserName(e), id: 0, title: '', url: '', note: 'no answer — reload that browser\'s extension (chrome://extensions/?id=' + EXT_ID + ')' }];
      }));
      return json(rows.flat());
    }
    if (u.pathname === '/reply' && req.method === 'POST') {
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      const { thread, comment, text, to, tab } = await req.json() as any;
      const id = safeId(String(thread || ''));
      const file = join(DIR, `${id}.json`);
      if (!id || !existsSync(file)) return json({ error: `unknown thread ${thread}`, fix: `fbreply --list` }, 404);
      const t = JSON.parse(readFileSync(file, 'utf8'));
      const c = t.comments.find((x: any) => x.key === comment || String(x.id) === String(comment));
      if (!c) return json({ error: `no comment ${comment} in ${id}`, have: t.comments.map((x: any) => x.key) }, 404);
      // which browser: --to, else the one the thread was forwarded from, else the newest. A tab id only means something in ITS browser.
      const want = to || (t.ua ? (String(t.ua).match(/Chrome\/\d+/) || [''])[0] : '');
      const pool = [...exts].filter(e => !want || uaOf(e).includes(String(want)));
      const ext = newest(pool.length ? pool : [...exts]);
      const tabId = tab ?? t.tab?.id ?? null;
      if (tab && !to && exts.size > 1) return json({ error: `tab ${tab} belongs to one browser; ${exts.size} are connected`, fix: `fbreply --tabs   then   fbreply --to Chrome/153 --tab ${tab} …` }, 400);
      if (!ext) return json({ error: 'extension not connected', fix: 'open chrome://extensions/?id=' + EXT_ID + ' and click reload; check the bridge log for "extension connected"' }, 503);
      const rid = crypto.randomUUID();
      const done = new Promise<any>(res => { waiting.set(rid, res); setTimeout(() => res({ ok: false, note: 'timeout 60s — is the Facebook tab open?' }), 60_000); });
      ext.send(JSON.stringify({ type: 'reply', rid, url: t.url, tab: tabId, comment: c.id, who: c.author, text: String(text || '') }));
      return json({ ...(await done), via: browserName(ext), tab: tabId });
    }
    if (u.pathname === '/health') return json({ ok: true, extensions: [...exts].map(browserName) });
    return json({ error: 'not found' }, 404);
  },
  websocket: {
    open(ws) {
      exts.add(ws); console.log(`${stamp()} extension connected ${browserName(ws)} (${exts.size})`);
      const b = browserName(ws), now = Date.now();
      seen[b] = { version: seen[b]?.version || '', since: now, lastSeen: now, connected: true }; saveSeen(); broadcast();
    },
    close(ws) {
      exts.delete(ws); console.log(`${stamp()} extension gone ${browserName(ws)} (${exts.size})`);
      const b = browserName(ws);
      if (seen[b] && ![...exts].some(e => browserName(e) === b)) { seen[b].connected = false; seen[b].lastSeen = Date.now(); saveSeen(); broadcast(); }
    },
    message(_ws, m) {
      try {
        const r = JSON.parse(String(m));
        if (r.type === 'result') { waiting.get(r.rid)?.(r); waiting.delete(r.rid); }
        else if (r.type === 'hello') { const b = browserName(_ws); if (seen[b]) { seen[b].version = String(r.version || ''); saveSeen(); broadcast(); } }
      } catch {}
    },
  },
});
setInterval(() => { for (const e of exts) try { e.send('{"type":"ping"}'); } catch {} }, 20_000);   // keeps the service worker's socket alive
console.log(`oracle-fb bridge on http://127.0.0.1:${PORT}   extension ${EXT_ID}   threads ${DIR}`);
