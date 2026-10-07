// The live view: what the surrogate recorded, as text, newest on top. Polls the bridge every second (127.0.0.1 only).
const B = 'http://127.0.0.1:4747';
const $ = (id) => document.getElementById(id);
let last = 0, shown = 0;
const clock = (ms) => new Date(ms).toLocaleTimeString('en-GB');
function card(e, fresh) {
  const d = document.createElement('div'); d.className = 'ev' + (fresh ? ' fresh' : '');
  const h = document.createElement('div'); h.className = 'h';
  const t = document.createElement('span'); t.className = 't'; t.textContent = clock(e.ts);
  const k = document.createElement('span'); k.className = 'k ' + e.kind; k.textContent = e.kind;
  const a = document.createElement('span'); a.className = 'a';
  a.textContent = e.kind === 'nav' ? (e.text || e.key) : (e.author || (e.post ? 'on ' + e.post.slice(0, 60) : ''));
  h.append(t, k, a); if (e.media) h.append(Object.assign(document.createElement('span'), { className: 't', textContent: `${e.media} media` }));
  if (e.status) {   // new / same / updated: what the bridge made of this capture
    const s = document.createElement('span'); s.className = 'st ' + e.status;
    s.textContent = e.status === 'updated' ? `UPDATED v${e.v} · ${(e.changes || []).join(', ')}` : e.status === 'same' ? `same v${e.v}` : 'NEW';
    s.title = e.node || ''; h.append(s);
  }
  d.append(h);
  if (e.text && e.kind !== 'nav') d.append(Object.assign(document.createElement('div'), { className: 'x', textContent: e.text }));
  const href = e.link || (/^https?:/.test(e.key) ? e.key : '') || e.url;
  if (href) { const l = document.createElement('a'); l.href = href; l.target = '_blank'; l.textContent = href; d.append(l); }
  return d;
}
async function tick() {
  try {
    const first = !last;
    // POST, so Chrome attaches our Origin (the bridge only answers the extension or the token holder)
    const rows = await fetch(`${B}/stream`, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(first ? { limit: 60 } : { since: last, limit: 100 }) }).then(r => { if (!r.ok) throw new Error(r.status); return r.json(); });
    $('state').textContent = '● live'; $('state').style.color = '#66bb6a';
    const list = first ? rows.slice().reverse() : rows;   // first page arrives newest-first
    if (list.length && $('list').querySelector('.empty')) $('list').textContent = '';
    for (const e of list) { $('list').prepend(card(e, !first)); last = Math.max(last, e.id); shown++; }
    $('count').textContent = `${shown} shown`;
  } catch { $('state').textContent = '○ bridge not running — bun …/oracle-app-kit/browser/bridge/server.ts'; $('state').style.color = '#ef5350'; }
}
// first the last 60 (one /stream call), then the bridge PUSHES each new event down one long POST /live response
async function live() {
  await tick();
  try {
    const res = await fetch(`${B}/live`, { method: 'POST' });
    if (!res.ok) throw new Error(res.status);
    $('state').textContent = '● live (pushed by the bridge)';
    const reader = res.body.getReader(), dec = new TextDecoder(); let buf = '';
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      buf += dec.decode(value, { stream: true });
      let i; while ((i = buf.indexOf('\n\n')) >= 0) {
        const msg = buf.slice(0, i); buf = buf.slice(i + 2);
        if (!msg.startsWith('data: ')) continue;
        if ($('list').querySelector('.empty')) $('list').textContent = '';
        $('list').prepend(card(JSON.parse(msg.slice(6)), true)); shown++; $('count').textContent = `${shown} shown`;
      }
    }
  } catch {}
  $('state').textContent = '○ stream dropped — retrying'; $('state').style.color = '#ef5350';
  setTimeout(live, 2000);   // the bridge restarted or went away: reconnect
}
live();
