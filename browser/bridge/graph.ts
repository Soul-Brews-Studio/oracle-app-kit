#!/usr/bin/env bun
// graph — the Facebook graph the surrogate has seen: nodes (user/post/comment/photo/video/album/group/url) + relations.
//   graph --stats                 how many of each node type / relation
//   graph <node-id | facebook url | words>    the node, what it points to (→) and what points to it (←)
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
const token = readFileSync(`${homedir()}/.oracle-fb/token`, 'utf8').trim();
const arg = Bun.argv.slice(2).join(' ');
const get = (qs: string) => fetch(`http://127.0.0.1:${process.env.ORACLE_FB_PORT || 4747}/graph?${qs}`, { headers: { 'x-fb-token': token } }).then(r => r.json()).catch(() => null);
if (!arg || arg === '--stats') {
  const r = await get('stats=1');
  if (!r) { console.error(`✗ bridge not running\n  bun ${import.meta.dir}/server.ts`); process.exit(1); }
  console.log('nodes'); for (const x of r.nodes) console.log(`  ${String(x.n).padStart(6)}  ${x.type}`);
  console.log('relations'); for (const x of r.edges) console.log(`  ${String(x.n).padStart(6)}  ${x.rel}`);
  process.exit(0);
}
const r = await get(`id=${encodeURIComponent(arg)}`);
if (!r) { console.error(`✗ bridge not running\n  bun ${import.meta.dir}/server.ts`); process.exit(1); }
if (r.error) { console.log(`✗ ${r.error}`); for (const t of r.try || []) console.log(`  try: ${t.id}   ${t.label?.slice(0, 60) || ''}`); process.exit(1); }
const lab = (x: any) => `${x.id}${x.label ? `  “${x.label.slice(0, 70)}”` : ''}`;
console.log(`${lab(r.node)}\n  type ${r.node.type} · seen ${r.node.seen}× · ${r.node.url || ''}`);
for (const e of r.out) console.log(`  ──${e.rel}──►  ${lab(e)}${e.n > 1 ? `  ×${e.n}` : ''}`);
for (const e of r.in) console.log(`  ◄──${e.rel}──  ${lab(e)}${e.n > 1 ? `  ×${e.n}` : ''}`);
