#!/usr/bin/env bun
// fbreply <thread> <comment> <text…>   — type a reply into that Facebook comment's box (a human presses Enter)
// fbreply --list                        — threads the extension has forwarded
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
const PORT = process.env.ORACLE_FB_PORT || '4747';
const token = readFileSync(`${homedir()}/.oracle-fb/token`, 'utf8').trim();
const call = (path: string, body?: unknown) => fetch(`http://127.0.0.1:${PORT}${path}`, {
  method: body ? 'POST' : 'GET', headers: { 'x-fb-token': token, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined,
}).then(async r => ({ status: r.status, body: await r.json() as any })).catch(() => null);

let args = Bun.argv.slice(2), to = '', tab: number | undefined;
const ti = args.indexOf('--to'); if (ti >= 0) { to = args[ti + 1] || ''; args.splice(ti, 2); }   // --to Chrome/153 : which browser types it
const tj = args.indexOf('--tab'); if (tj >= 0) { tab = Number(args[tj + 1]); args.splice(tj, 2); }   // --tab 123 : type into that exact tab
const [a, b, ...rest] = args;
if (a === '--tabs') {
  const r = await call('/tabs');
  if (!r) { console.error(`✗ bridge not running\n  bun ${import.meta.dir}/server.ts`); process.exit(1); }
  if (!r.body.length) console.log('no Facebook tabs open (or no browser connected: curl -s 127.0.0.1:4747/health)');
  for (const t of r.body) console.log(t.note ? `${t.browser}  ✗ ${t.note}` : `${t.browser}  tab ${t.id}${t.active ? '  *active*' : ''}  ${t.title.slice(0, 50)}\n          ${t.url}`);
  process.exit(0);
}
if (a === '--list') {
  const r = await call('/threads');
  if (!r) { console.error(`✗ bridge not running\n  bun ${import.meta.dir}/server.ts`); process.exit(1); }
  for (const t of r.body) console.log(`${t.id}  ${t.comments.length} comments  ${t.title}\n        ${t.url}`);
  process.exit(0);
}
if (!a || !b || !rest.length) { console.error('usage: fbreply [--to Chrome/153] [--tab 123] <thread> <c1|comment_id> <text…>\n       fbreply --list\n       fbreply --tabs'); process.exit(2); }
const r = await call('/reply', { thread: a, comment: b, text: rest.join(' '), to, tab });
if (!r) { console.error(`✗ bridge not running\n  bun ${import.meta.dir}/server.ts`); process.exit(1); }
if (r.status !== 200) { console.error(`✗ ${r.body.error}${r.body.fix ? `\n  ${r.body.fix}` : ''}${r.body.have ? `\n  comments: ${r.body.have.join(' ')}` : ''}`); process.exit(1); }
console.log(r.body.ok ? `✓ typed into ${b}'s reply box (${r.body.via || 'browser'}${r.body.tab ? ` tab ${r.body.tab}` : ''}) — ${r.body.note || 'press Enter to post'}` : `✗ ${r.body.note}`);
process.exit(r.body.ok ? 0 : 1);
