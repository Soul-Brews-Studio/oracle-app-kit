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
  if (msg?.kind === 'events') {   // the surrogate stream: tag with browser + tab, hand to the bridge
    const browser = (navigator.userAgent.match(/Chrome\/\d+/) || ['browser'])[0];
    const events = msg.events.map(e => ({ ...e, browser, tab: sender.tab?.id ?? null }));
    fetch(`http://${BRIDGE}/events`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(events) })
      .then(r => r.json()).then(r => reply(r)).catch(() => { showBridge(false); reply({ ok: false }); });
    return true;
  }
  if (msg?.kind === 'getTabId') {   // the page asks for its own tab id (the Gemini proxy's pattern: content.js → sender.tab.id)
    reply({ tabId: sender.tab?.id ?? null, windowId: sender.tab?.windowId ?? null, browser: (navigator.userAgent.match(/Chrome\/\d+/) || ['browser'])[0], bridge: bridge?.readyState === 1 });
    return;
  }
  if (msg?.kind === 'popup-status' || msg?.kind === 'popup-reconnect') {   // the toolbar popup
    if (!bridge || bridge.readyState > 1) connectBridge();
    setTimeout(() => reply({ connected: bridge?.readyState === 1, info: bridgeInfo, version: chrome.runtime.getManifest().version_name, ua: navigator.userAgent, id: chrome.runtime.id, bridge: BRIDGE }),
      msg.kind === 'popup-reconnect' || (!bridge || bridge.readyState !== 1) ? 900 : 0);
    return true;
  }
  if (msg?.kind === 'bridge-status') {   // also lets the page (and tests) read what the toolbar badge says
    if (!bridge || bridge.readyState > 1) connectBridge();   // the page's ping doubles as a wake-up call
    chrome.action.getBadgeText({}).then(badge => reply({ on: bridge?.readyState === 1, badge }));
    return true;
  }
  if (msg?.kind === 'thread') {   // content script → bridge (a whole thread is too big for a URL)
    // the tab the click came from: a reply goes back to THAT tab (ids are per browser, so the user agent rides along)
    const thread = { ...msg.thread, tab: sender.tab ? { id: sender.tab.id, windowId: sender.tab.windowId } : null, ua: navigator.userAgent };
    fetch(`http://${BRIDGE}/thread`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(thread) })
      .then(r => r.json()).then(r => reply(r)).catch(e => { showBridge(false); reply({ ok: false, error: `bridge not running: bun ${'~'}/…/oracle-app-kit/browser/bridge/server.ts (${e})` }); });
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
// The toolbar icon says whether the bridge is reachable: green ON / red OFF, tooltip with the fix (Nat: "can extension
// icon show connected or not connected to the bridge?").
function showBridge(on, info) {
  chrome.action.setBadgeText({ text: on ? 'ON' : 'OFF' });
  chrome.action.setBadgeBackgroundColor({ color: on ? '#2e7d32' : '#c62828' });
  chrome.action.setTitle({ title: on
    ? `ARRA Oracles — bridge connected (127.0.0.1:4747)${info ? ` · ${info.browsers.filter(x => x.connected).length} browser(s)` : ''}`
    : 'ARRA Oracles — bridge NOT connected. Start it:\nbun /opt/Code/github.com/Soul-Brews-Studio/oracle-app-kit/browser/bridge/server.ts\n(click this icon to see why / retry)' });
}
showBridge(false);
let bridgeInfo = null;   // what the bridge last told us: who is connected (pushed on every change)
// Retry fast while the worker is awake (1.5 s, 3 s, 6 s … 10 s); the 30 s alarm and the Facebook tab's 5 s ping wake it
// again when it has gone to sleep — so a restarted bridge is found in seconds, not at the next alarm.
let retryMs = 1500, retryTimer = 0;
function retryBridge() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => { connectBridge(); if (!bridge || bridge.readyState !== 1) retryMs = Math.min(retryMs * 2, 10000); }, retryMs);
}
function connectBridge() {
  if (bridge && bridge.readyState <= 1) return;
  try { bridge = new WebSocket(`ws://${BRIDGE}/ws`); } catch { showBridge(false); return; }
  bridge.onopen = () => { retryMs = 1500; showBridge(true); try { bridge.send(JSON.stringify({ type: 'hello', version: chrome.runtime.getManifest().version_name, id: chrome.runtime.id })); } catch {} };
  bridge.onmessage = (e) => { try { const m = JSON.parse(e.data); if (m.type === 'reply') handleReply(m); else if (m.type === 'tabs') listTabs(m); else if (m.type === 'status') { bridgeInfo = m; showBridge(true, m); } } catch {} };
  bridge.onclose = () => { bridge = null; showBridge(false); retryBridge(); };
  bridge.onerror = () => showBridge(false);
}
connectBridge();
chrome.alarms.create('bridge', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === 'bridge') connectBridge(); });
chrome.runtime.onStartup.addListener(connectBridge);
chrome.runtime.onInstalled.addListener(connectBridge);

async function listTabs(m) {   // `fbreply --tabs`: every Facebook tab in this browser
  const tabs = await chrome.tabs.query({ url: 'https://www.facebook.com/*' });
  try { bridge?.send(JSON.stringify({ type: 'result', rid: m.rid, ok: true, tabs: tabs.map(t => ({ id: t.id, windowId: t.windowId, active: t.active, title: t.title || '', url: t.url })) })); } catch {}
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const postKey = (u) => { try { const x = new URL(u); return x.pathname + (x.searchParams.get('fbid') ? `?fbid=${x.searchParams.get('fbid')}` : ''); } catch { return u; } };
async function handleReply(m) {
  const answer = (r) => { try { bridge?.send(JSON.stringify({ type: 'result', rid: m.rid, ...r })); } catch {} };
  try {
    // the tab the thread was forwarded from, if it is still open on that post (a duplicate tab of the same post must not win)
    let tab = null;
    if (m.tab != null) { try { const t = await chrome.tabs.get(m.tab); if (t?.url && postKey(t.url) === postKey(m.url)) tab = t; } catch {} }
    if (!tab) tab = (await chrome.tabs.query({ url: 'https://www.facebook.com/*' })).filter(t => postKey(t.url) === postKey(m.url))[0];
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
