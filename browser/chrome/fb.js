// Facebook: a "🔮 Issue" button in every post's action bar (next to Like · Comment · Share).
// Click → pick the oracle → its Mac app opens the issue draft with the post's link, author and text.
// Anchors are Facebook's own data-ad-rendering-role attributes (profile_name, story_message, like_button),
// measured 2026-10-07 — the class names are obfuscated and change, these do not (yet).
(() => {
  if (window.__oracleIssueButtons) return;      // injected twice (manifest + reload-time inject): run once
  window.__oracleIssueButtons = true;
  const ORACLES = ['Neo', 'Pulse', 'Nexus'];
  const MARK = 'data-oracle-issue';
  const POSTLINK = /\/posts\/|\/permalink|story_fbid|\/videos\/|\/reel\/\d|\/photo\/?\?fbid=|\/photo\.php/;

  // Every post has Like; friends-only posts have no Share (Nat's screenshot 2026-10-07), so Like is the anchor.
  const LIKE = '[data-ad-rendering-role="like_button"]';

  // the post that owns this Like: the highest ancestor holding exactly one Like and an author
  function postOf(like) {
    let n = like, best = null;
    for (let i = 0; i < 30 && n && n !== document.body; i++) {
      if (n.querySelectorAll(LIKE).length > 1) break;
      if (n.querySelector('[data-ad-rendering-role="profile_name"]')) best = n;
      n = n.parentElement;
    }
    return best;
  }

  const tick = (ms) => new Promise(r => setTimeout(r, ms));

  function clean(href) {
    try {
      const u = new URL(href, location.origin);
      [...u.searchParams.keys()].filter(k => k.startsWith('__')).forEach(k => u.searchParams.delete(k));
      u.hash = '';
      return u.toString();
    } catch { return href; }
  }

  async function permalink(post) {
    // The post's own link is its header timestamp — the first link after the author. Other post links inside
    // the post can belong to a SHARED post (measured: a re-share on a permalink page linked the original first).
    const author = post.querySelector('[data-ad-rendering-role="profile_name"]');
    const ts = author && [...post.querySelectorAll('a[role="link"]')].find(a =>
      !author.contains(a) && (author.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING) &&
      ((a.getAttribute('href') || '').startsWith('?') || POSTLINK.test(a.href)));
    if (ts && !POSTLINK.test(ts.href)) {
      // it holds only "?__cft__…" until focused — focusin (not hover) makes Facebook write the real
      // /posts/pfbid… href (measured 2026-10-07)
      ts.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
      await tick(150);
    }
    let h = ts && POSTLINK.test(ts.href) ? ts.href : '';
    ts?.dispatchEvent(new FocusEvent('focusout', { bubbles: true }));   // drop the focus ring + date tooltip it raised
    // a single-post page: the page itself is the post (never borrow it for another post on the page)
    if (!h && document.querySelectorAll(LIKE).length === 1 && POSTLINK.test(location.href)) h = location.href;
    return h ? clean(h) : '';
  }

  async function details(post) {
    const message = post.querySelector('[data-ad-rendering-role="story_message"]');
    const more = [...(message?.querySelectorAll('[role="button"]') || [])].find(b => /^(see more|ดูเพิ่มเติม)$/i.test(b.innerText.trim()));
    if (more) { more.click(); await tick(300); }   // the full text, not the "… See more" cut
    const author = (post.querySelector('[data-ad-rendering-role="profile_name"]')?.innerText || '').split('\n')[0].trim();
    const text = (post.querySelector('[data-ad-rendering-role="story_message"]')?.innerText || '').trim();
    const first = text.split('\n').find(l => l.trim()) || 'Facebook post';
    return { url: await permalink(post), title: (author ? author + ': ' : '') + first.slice(0, 90),
             text: text.slice(0, 2000) + (author ? `\n\nby ${author} on Facebook` : '') };
  }

  function menu(anchor, post) {
    document.querySelectorAll('.oracle-issue-menu').forEach(m => m.remove());
    const m = document.createElement('div');
    m.className = 'oracle-issue-menu';
    Object.assign(m.style, { position: 'absolute', zIndex: 9999, background: '#242526', color: '#e4e6eb', border: '1px solid #3a3b3c',
      borderRadius: '10px', padding: '6px', boxShadow: '0 8px 24px rgba(0,0,0,.4)', font: '14px system-ui, sans-serif', minWidth: '170px' });
    const head = document.createElement('div');
    head.textContent = 'New issue in'; Object.assign(head.style, { opacity: .6, fontSize: '12px', padding: '4px 10px' });
    m.append(head);
    for (const o of ORACLES) {
      const b = document.createElement('div');
      b.textContent = `${o} Oracle`;
      Object.assign(b.style, { padding: '8px 10px', borderRadius: '6px', cursor: 'pointer' });
      b.onmouseenter = () => (b.style.background = '#3a3b3c'); b.onmouseleave = () => (b.style.background = '');
      b.onclick = async (e) => {
        e.stopPropagation(); m.remove();
        const d = await details(post);
        if (window.chrome?.runtime?.sendMessage) chrome.runtime.sendMessage({ kind: 'issue', oracle: o, ...d });
        else console.log('[oracle] would send', o, d);
      };
      m.append(b);
    }
    const r = anchor.getBoundingClientRect();
    m.style.left = `${r.left + scrollX}px`; m.style.top = `${r.bottom + scrollY + 4}px`;
    document.body.append(m);
    setTimeout(() => document.addEventListener('click', () => m.remove(), { once: true }), 0);
  }

  function addButtons() {
    for (const like of document.querySelectorAll(LIKE)) {
      const wrap = (like.closest('[role="button"]') || like).parentElement;
      const bar = wrap?.parentElement;
      if (!bar || bar.hasAttribute(MARK)) continue;
      const post = postOf(like);
      if (!post) continue;
      bar.setAttribute(MARK, '1');
      const btn = document.createElement('div');
      btn.setAttribute('role', 'button'); btn.tabIndex = 0; btn.title = 'New issue in an oracle app';
      btn.textContent = '🔮 Issue';
      Object.assign(btn.style, { display: 'flex', alignItems: 'center', justifyContent: 'center', flex: '1 1 0',
        cursor: 'pointer', borderRadius: '6px', color: '#b0b3b8', font: '600 15px system-ui, sans-serif', padding: '6px 0' });
      btn.onmouseenter = () => (btn.style.background = 'rgba(255,255,255,.06)'); btn.onmouseleave = () => (btn.style.background = '');
      btn.onclick = (e) => { e.stopPropagation(); e.preventDefault(); menu(btn, post); };
      bar.lastElementChild.after(btn);   // at the end: after Share, or after Comment when there is no Share
    }
  }

  let t;
  new MutationObserver(() => { clearTimeout(t); t = setTimeout(addButtons, 400); })
    .observe(document.body, { childList: true, subtree: true });
  addButtons();
})();
