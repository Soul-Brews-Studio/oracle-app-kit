// Right-click anywhere in Chrome → "Send to oracle" ▸ <Name> Oracle ▸ New issue / Send to inbox / Message.
// Each item opens oracle-<name>://<action>?url=…&title=…&text=… — the oracle app (OracleAppDelegate) turns it
// into the editable issue draft, an inbox note, or the message box. Nothing is posted or sent without Nat.
const ORACLES = ['Neo', 'Pulse', 'Nexus'];           // one per installed oracle app (co.laris.oracle.<name>)
const ACTIONS = [['issue', 'New issue'], ['inbox', 'Send to inbox'], ['message', 'Message']];
const CONTEXTS = ['page', 'link', 'selection', 'image'];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'root', title: 'Send to oracle', contexts: CONTEXTS });
    for (const o of ORACLES) {
      chrome.contextMenus.create({ id: o, parentId: 'root', title: `${o} Oracle`, contexts: CONTEXTS });
      for (const [a, label] of ACTIONS) {
        chrome.contextMenus.create({ id: `${o}:${a}`, parentId: o, title: label, contexts: CONTEXTS });
      }
    }
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const [oracle, action] = String(info.menuItemId).split(':');
  if (!action || !tab) return;
  const q = new URLSearchParams({
    url: info.linkUrl || info.srcUrl || info.pageUrl || tab.url || '',
    title: info.linkUrl ? '' : (tab.title || ''),
    text: info.selectionText || '',
  });
  // An external-scheme navigation hands the link to macOS and leaves the page where it is.
  chrome.tabs.update(tab.id, { url: `oracle-${oracle.toLowerCase()}://${action}?${q}` });
});
