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
chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg?.kind !== 'issue' || !sender.tab || !ORACLES.includes(msg.oracle)) return;
  const q = query({ url: msg.url || '', title: msg.title || '', text: msg.text || '' });
  chrome.tabs.update(sender.tab.id, { url: `oracle-${msg.oracle.toLowerCase()}://issue?${q}` });
});
