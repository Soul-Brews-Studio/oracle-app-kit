// The toolbar popup: what the bridge told this extension (pushed on every connect/disconnect), plus a Reconnect.
const $ = (id) => document.getElementById(id);
const clock = (ms) => new Date(ms).toTimeString().slice(0, 8);
const mine = () => (navigator.userAgent.match(/Chrome\/(\d+)/) || [])[1];
function paint(r) {
  $('dot').className = 'dot' + (r.connected ? ' on' : '');
  $('title').textContent = r.connected ? 'Bridge connected' : 'Bridge NOT connected';
  $('ver').textContent = r.version || '';
  const body = $('body'); body.className = ''; body.textContent = '';
  const line = (n, s, cls) => { const d = document.createElement('div'); d.className = 'row'; const a = document.createElement('span'); a.className = 'n ' + (cls || ''); a.textContent = n; const b = document.createElement('span'); b.className = 's'; b.textContent = s; d.append(a, b); body.append(d); return d; };
  if (!r.connected) {
    const p = document.createElement('div'); p.className = 'muted'; p.textContent = `Nothing is answering on ${r.bridge}. Start it (in a herdr pane):`; body.append(p);
    const c = document.createElement('code'); c.textContent = 'bun /opt/Code/github.com/Soul-Brews-Studio/oracle-app-kit/browser/bridge/server.ts'; body.append(c);
    return;
  }
  const i = r.info;
  if (!i) { body.textContent = 'connected — waiting for the bridge to say who else is here…'; body.className = 'muted'; return; }
  line(`127.0.0.1:${i.port}`, `up ${i.up}s · ${i.threads} thread${i.threads === 1 ? '' : 's'}`);
  for (const b of i.browsers) {
    const row = line(`${b.browser.replace('Chrome/', 'Chrome ')}`, b.connected ? `✓ since ${clock(b.since)} · ${b.version || 'older build'}` : `✗ last seen ${clock(b.lastSeen)}`, b.connected ? 'ok' : 'no');
    if (b.browser.endsWith('/' + mine())) { const m = document.createElement('span'); m.className = 'me'; m.textContent = 'this browser'; row.children[0].append(' ', m); }
  }
}
const ask = (kind) => chrome.runtime.sendMessage({ kind }, (r) => r ? paint(r) : ($('body').textContent = 'the extension did not answer'));
$('retry').onclick = () => { $('body').className = 'muted'; $('body').textContent = 'reconnecting…'; ask('popup-reconnect'); };
ask('popup-status');

$('live').onclick = () => chrome.tabs.create({ url: chrome.runtime.getURL('stream.html') });   // the text-only live view
