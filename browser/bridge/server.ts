// oracle-fb bridge — 127.0.0.1 only. Two halves of "Facebook ↔ oracle":
//   FORWARD  extension → POST /thread   a whole post + comments, kept as ~/.oracle-fb/threads/<id>.md|json
//   BACK     agent → fbreply → POST /reply → WebSocket → extension types it into that comment's reply box.
//            It stops at the box: a human presses Enter. Nothing here ever posts.
// Who may talk: the extension (Origin chrome-extension://<id>) on /thread and /ws; the CLI (x-fb-token header,
// token in ~/.oracle-fb/token) on /reply, /threads. A web page has neither, so it cannot reach either half.
import { mkdirSync, readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const PORT = Number(process.env.ORACLE_FB_PORT || 4747);
const HOME = join(homedir(), '.oracle-fb'), DIR = join(HOME, 'threads');
const EXT_ID = process.env.ORACLE_FB_EXT || 'hadknpihalkpmhfdppedhdoaeaddcgig';
mkdirSync(DIR, { recursive: true });
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
      const footer = `\n\n---\nReply path — types into that comment's box in Chrome; a human presses Enter:\n    ${cmd} ${id} c1 "your reply"\n    ${cmd} --list\n`;
      writeFileSync(join(DIR, `${id}.md`), String(t.md || '') + footer);
      writeFileSync(join(DIR, `${id}.json`), JSON.stringify({ id, url: t.url, title: t.title, at: new Date().toISOString(), tab: t.tab || null, ua: t.ua || '', comments: t.comments || [] }, null, 1));
      console.log(`thread ${id}  ${(t.comments || []).length} comments  ${t.url}`);
      return json({ ok: true, id, file: join(DIR, `${id}.md`) });
    }
    if (u.pathname === '/threads') {
      if (!fromCli(req)) return json({ error: 'token' }, 403);
      return json(readdirSync(DIR).filter(f => f.endsWith('.json')).map(f => JSON.parse(readFileSync(join(DIR, f), 'utf8'))));
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
