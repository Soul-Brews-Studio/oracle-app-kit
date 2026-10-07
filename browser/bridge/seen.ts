#!/usr/bin/env bun
// seen — what Nat saw and did on Facebook, from the surrogate stream (recorded only in tabs with REC on)
//   seen                      today: counts + the latest 20 things
//   seen <words>              search everything (Thai works; 3+ characters)
//   seen --full               the whole text of each item, not 90 characters
//   seen --follow             live: print each new item (text only) as it is recorded — Ctrl-C to stop
//   seen --day 2026-10-07     one day        seen --kind react     one kind        seen --stats     counts per day/kind
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
const PORT = process.env.ORACLE_FB_PORT || '4747';
const token = readFileSync(`${homedir()}/.oracle-fb/token`, 'utf8').trim();
const args = Bun.argv.slice(2), opt = (k: string) => { const i = args.indexOf(k); if (i < 0) return ''; const v = args[i + 1] || ''; args.splice(i, 2); return v; };
const day = opt('--day'), kind = opt('--kind'), stats = args.includes('--stats') ? (args.splice(args.indexOf('--stats'), 1), true) : false;
const full = args.includes('--full') ? (args.splice(args.indexOf('--full'), 1), true) : false;
const follow = args.includes('--follow') ? (args.splice(args.indexOf('--follow'), 1), true) : false;
const q = args.join(' ');
const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Bangkok' });
const qs = new URLSearchParams({ ...(q ? { q } : {}), ...(day || (!q && !kind) ? { day: day || today } : {}), ...(kind ? { kind } : {}), ...(stats ? { stats: '1' } : {}), limit: '30' });
const r = await fetch(`http://127.0.0.1:${PORT}/stream?${qs}`, { headers: { 'x-fb-token': token } }).then(x => x.json()).catch(() => null);
if (!r) { console.error(`✗ bridge not running\n  bun ${import.meta.dir}/server.ts`); process.exit(1); }
if (stats) { for (const x of r as any[]) console.log(`${x.day}  ${String(x.n).padStart(5)}  ${x.kind}`); process.exit(0); }
const t = (ms: number) => new Date(ms).toLocaleTimeString('en-GB', { timeZone: 'Asia/Bangkok' });
const show = (e: any) => {
  const body = full ? e.text.trim() : e.text.replace(/\s+/g, ' ').slice(0, 90);
  const head = e.kind === 'seen' ? `${e.author || '?'}${e.media ? `  [${e.media} media]` : ''}`
    : e.kind === 'comment-seen' ? `↳ ${e.author || '?'}`
    : e.kind === 'nav' ? `→ ${e.text || e.key}` : `${e.text || ''} ${e.post || ''}`.trim();
  const tail = e.link || e.key || e.url;
  console.log(full && body && e.kind !== 'nav'
    ? `${t(e.ts)}  ${e.kind.padEnd(13)} ${head}\n${body.split('\n').map(l => '    │ ' + l).join('\n')}\n    └ ${tail}\n`
    : `${t(e.ts)}  ${e.kind.padEnd(13)} ${head}${body && e.kind !== 'nav' ? ': ' + body : ''}\n${''.padEnd(24)}${tail}`);
};
if (follow) {   // text only, as it happens: the bridge pushes each event (no polling)
  console.log(`live from the bridge (REC must be on in a Facebook tab) — Ctrl-C to stop`);
  const res = await fetch(`http://127.0.0.1:${PORT}/live`, { headers: { 'x-fb-token': token } });
  const reader = res.body!.getReader(), dec = new TextDecoder();
  let buf = '';
  while (true) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    let i; while ((i = buf.indexOf('\n\n')) >= 0) { const msg = buf.slice(0, i); buf = buf.slice(i + 2); if (msg.startsWith('data: ')) show(JSON.parse(msg.slice(6))); }
  }
  console.error('✗ the bridge closed the stream'); process.exit(1);
}
const rows = r as any[];
if (!rows.length) { console.log(q ? `nothing seen matching "${q}"` : `nothing recorded${day ? ` on ${day}` : ' today'} — turn on REC in a Facebook tab (bottom-left badge)`); process.exit(0); }
for (const e of rows) show(e);
