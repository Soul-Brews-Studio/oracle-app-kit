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
tick(); setInterval(tick, 1000);
