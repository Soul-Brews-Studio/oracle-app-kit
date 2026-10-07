// Right-click anywhere in Chrome → "New issue in" ▸ <Name> Oracle.
// Opens oracle-<name>://issue?url=…&title=…&text=… — the oracle app shows the issue draft (title = page title,
// body = link + selection); Nat checks it and presses Create. Nothing is posted from here.
const ORACLES = ['Neo', 'Pulse', 'Nexus'];           // one per installed oracle app (co.laris.oracle.<name>)
const CONTEXTS = ['page', 'link', 'selection', 'image'];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'root', title: 'New issue in', contexts: CONTEXTS });
    for (const o of ORACLES) {
      chrome.contextMenus.create({ id: o, parentId: 'root', title: `${o} Oracle`, contexts: CONTEXTS });
    }
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const oracle = String(info.menuItemId);
  if (!ORACLES.includes(oracle) || !tab) return;
  const q = new URLSearchParams({
    url: info.linkUrl || info.srcUrl || info.pageUrl || tab.url || '',
    title: info.linkUrl ? '' : (tab.title || ''),
    text: info.selectionText || '',
  });
  // An external-scheme navigation hands the link to macOS and leaves the page where it is.
  chrome.tabs.update(tab.id, { url: `oracle-${oracle.toLowerCase()}://issue?${q}` });
});
