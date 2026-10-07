// Right-click anywhere in Chrome → "🔮 Issue to Nexus" (one click, Nat 2026-10-07).
// Opens oracle-nexus://issue?url=…&title=…&text=… — Nexus shows the issue draft (title = page title,
// body = link + selection); Nat checks it and presses Create. Nothing is posted from here.
// One top-level item on purpose: Chrome folds two or more of an extension's items under one parent.
// %20, never "+": the apps read the query with URLComponents, which keeps "+" as a literal plus (issue #14 title)
const query = (o) => Object.entries(o).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
const ORACLES = ['Neo', 'Pulse', 'Nexus'];           // the 🔮 button's ⇧-click menu and fb.js messages accept these
const DEFAULT = 'Nexus';
const CONTEXTS = ['page', 'link', 'selection', 'image'];

chrome.runtime.onInstalled.addListener(() => {
  // Content scripts reach only pages loaded AFTER an install or ⟳ — and Facebook is a single-page app, so a tab
  // opened before never gets fb.js (the "no icon" root cause, 2026-10-07). Put it into every open Facebook tab now.
  chrome.tabs.query({ url: 'https://www.facebook.com/*' }, (tabs) => {
    for (const t of tabs) chrome.scripting.executeScript({ target: { tabId: t.id }, files: ['fb.js'] }).catch(() => {});
  });
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: DEFAULT, title: `🔮 Issue to ${DEFAULT}`, contexts: CONTEXTS });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const oracle = String(info.menuItemId);
  if (!ORACLES.includes(oracle) || !tab) return;
  const q = query({
    url: info.linkUrl || info.srcUrl || info.pageUrl || tab.url || '',
    title: info.linkUrl ? '' : (tab.title || ''),
    text: info.selectionText || '',
  });
  // An external-scheme navigation hands the link to macOS and leaves the page where it is.
  chrome.tabs.update(tab.id, { url: `oracle-${oracle.toLowerCase()}://issue?${q}` });
});

// The Facebook content script (fb.js) asks for the same hand-off from its 🔮 Issue button.
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg?.kind === 'thread') {   // content script → bridge (a whole thread is too big for a URL)
    fetch(`http://${BRIDGE}/thread`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(msg.thread) })
      .then(r => r.json()).then(r => reply(r)).catch(e => reply({ ok: false, error: `bridge not running: bun ${'~'}/…/oracle-app-kit/browser/bridge/server.ts (${e})` }));
    return true;
  }
  if (msg?.kind !== 'issue' || !sender.tab || !ORACLES.includes(msg.oracle)) return;
  const q = query({ url: msg.url || '', title: msg.title || '', text: msg.text || '', ...(msg.thread ? { thread: msg.thread } : {}) });
  chrome.tabs.update(sender.tab.id, { url: `oracle-${msg.oracle.toLowerCase()}://issue?${q}` });
});

// ── bridge: ~/oracle-app-kit/browser/bridge/server.ts on 127.0.0.1:4747 ─────────────────────────────────────────
// FORWARD: a whole thread is too big for a URL, so the content script hands it here, we POST it to the bridge, and
//          the app opens a draft that reads it from ~/.oracle-fb/threads/<id>.md.
// BACK:    the bridge pushes {type:'reply'} over a WebSocket; we open/focus the post and have the page type the text
//          into that comment's reply box. Nothing is ever submitted — a human presses Enter.
const BRIDGE = '127.0.0.1:4747';
let bridge = null;
function connectBridge() {
  if (bridge && bridge.readyState <= 1) return;
  try { bridge = new WebSocket(`ws://${BRIDGE}/ws`); } catch { return; }
  bridge.onmessage = (e) => { try { const m = JSON.parse(e.data); if (m.type === 'reply') handleReply(m); } catch {} };
  bridge.onclose = () => { bridge = null; };
  bridge.onerror = () => {};
}
connectBridge();
chrome.alarms.create('bridge', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === 'bridge') connectBridge(); });
chrome.runtime.onStartup.addListener(connectBridge);
chrome.runtime.onInstalled.addListener(connectBridge);

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const postKey = (u) => { try { const x = new URL(u); return x.pathname + (x.searchParams.get('fbid') ? `?fbid=${x.searchParams.get('fbid')}` : ''); } catch { return u; } };
async function handleReply(m) {
  const answer = (r) => { try { bridge?.send(JSON.stringify({ type: 'result', rid: m.rid, ...r })); } catch {} };
  try {
    const tabs = (await chrome.tabs.query({ url: 'https://www.facebook.com/*' })).filter(t => postKey(t.url) === postKey(m.url));
    let tab = tabs[0];
    if (tab) { await chrome.tabs.update(tab.id, { active: true }); await chrome.windows.update(tab.windowId, { focused: true }); }
    else tab = await chrome.tabs.create({ url: m.url, active: true });
    let res = null;
    for (let i = 0; i < 40 && !res; i++) {
      try { res = await chrome.tabs.sendMessage(tab.id, { kind: 'fillReply', comment: m.comment, who: m.who, text: m.text }); }
      catch { await sleep(500); }
    }
    answer(res || { ok: false, note: 'the page never answered (content script not loaded — reload the Facebook tab)' });
  } catch (e) { answer({ ok: false, note: String(e) }); }
}
