// Facebook: a "🔮 Issue" button in every post's action bar (next to Like · Comment · Share).
// Click → pick the oracle → its Mac app opens the issue draft with the post's link, author and text.
// Anchors are Facebook's own data-ad-rendering-role attributes (profile_name, story_message, like_button),
// measured 2026-10-07 — the class names are obfuscated and change, these do not (yet).
(() => {
  if (window.__oracleIssueButtons) return;      // injected twice (manifest + reload-time inject): run once
  window.__oracleIssueButtons = true;
  const ORACLES = ['Neo', 'Pulse', 'Nexus'];
  const DEFAULT = 'Nexus';   // Nat: "icon action send link to the issue of nexus" — one click; ⇧-click picks another
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

  // Facebook leaves header links as "?__cft__…" until they are focused; focusin (not hover) makes it write the
  // real href (measured 2026-10-07). Focus every such link in a range, read, then blur them again.
  async function resolve(anchors) {
    const lazy = anchors.filter(a => (a.getAttribute('href') || '').startsWith('?'));
    lazy.forEach(a => a.dispatchEvent(new FocusEvent('focusin', { bubbles: true })));
    if (lazy.length) await tick(180);
    lazy.forEach(a => a.dispatchEvent(new FocusEvent('focusout', { bubbles: true })));
  }

  // The post's own link is in its header — between the author and the message ("Sira Ekabut · 4 days ago" in a
  // group post: Nat's XPath, 2026-10-07). Links after the message belong to a SHARED post; they go in the body.
  async function links(post) {
    const author = post.querySelector('[data-ad-rendering-role="profile_name"]');
    const message = post.querySelector('[data-ad-rendering-role="story_message"]');
    const all = [...post.querySelectorAll('a[role="link"]')];
    const after = (x, a) => x && !x.contains(a) && (x.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING);
    const header = all.filter(a => after(author, a) && !(message && after(message, a)));
    const below = message ? all.filter(a => after(message, a)) : [];
    await resolve(header);
    let own = header.map(a => a.href).find(h => POSTLINK.test(h)) || '';
    // a single-post page: the page itself is the post (never borrow it for another post on the page)
    if (!own && document.querySelectorAll(LIKE).length === 1 && POSTLINK.test(location.href)) own = location.href;
    await resolve(below);
    const shared = [...new Set(below.map(a => a.href).filter(h => POSTLINK.test(h)).map(clean))].filter(h => h !== clean(own));
    return { own: own ? clean(own) : '', shared: shared.slice(0, 3) };
  }

  // Photo and video pages have no story_message: the caption is the first span/div[dir=auto] that is not a name,
  // a button, a link, a heading, a count ("22K views") or inside a comment (role=article) — measured 2026-10-07 on
  // Nat's photo URL (side panel) and the Sira Ekabut video (post container).
  const SEE = /\s*…?\s*(see more|see less|ดูเพิ่มเติม|ดูน้อยลง)$/i;
  function captionIn(root, author) {
    if (!root) return '';
    const isName = e => { const a = e.querySelector('a');
      return a && a.innerText.trim() === e.innerText.trim() && !/^https?:\/\/l\.facebook\.com\//.test(a.href) &&
        /(^|\.)facebook\.com$/.test(new URL(a.href, location.href).hostname); };
    const inComment = e => { const a = e.closest('[role="article"]'); return a && a !== root && root.contains(a); };
    return [...root.querySelectorAll('[dir="auto"]')]
      .filter(e => !inComment(e) && !e.closest('[role="button"], a, h1, h2, h3, h4') && !isName(e) &&
        !e.querySelector('[data-oracle-btn], [data-oracle-comment]'))   // never read our own chips back as the caption
      .map(e => e.innerText.trim().replace(SEE, ''))
      .find(t => /\p{L}/u.test(t) && t !== author && !/^(facebook|reels?|follow|public)$/i.test(t) && !/^[\d.,]+\s*[KMB]?\s+\S+$/i.test(t)) || '';
  }

  async function details(post) {
    const message = post.querySelector('[data-ad-rendering-role="story_message"]');
    const more = [...(message?.querySelectorAll('[role="button"]') || [])].find(b => /^(see more|ดูเพิ่มเติม)$/i.test(b.innerText.trim()));
    if (more) { more.click(); await tick(300); }   // the full text, not the "… See more" cut
    const author = (post.querySelector('[data-ad-rendering-role="profile_name"]')?.innerText || '').split('\n')[0].trim();
    const text = (post.querySelector('[data-ad-rendering-role="story_message"]')?.innerText || '').trim() ||
      captionIn(post, author);
    const first = text.split('\n').find(l => l.trim()) || 'Facebook post';
    const { own, shared } = await links(post);
    return { url: own || shared[0] || '', title: (author ? author + ': ' : '') + first.slice(0, 90),
             text: text.slice(0, 2000) + (author ? `\n\nby ${author} on Facebook` : '') +
                   shared.map(h => `\nShared post: ${h}`).join('') };
  }

  function menu(anchor, post, getDetails) {
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
        const d = getDetails ? await getDetails() : await details(post);
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

  // photo/video pages: the author and caption sit in the right panel (role=complementary); the document title is
  // just "Facebook", and the time links there belong to comments (measured on Nat's photo URL, 2026-10-07)
  async function pageDetails() {
    const side = document.querySelector('[role="complementary"]');
    const more = side && [...side.querySelectorAll('[role="button"]')].find(b => /^(see more|ดูเพิ่มเติม)$/i.test(b.innerText.trim()));
    if (more) { more.click(); await tick(300); }
    const authorEl = side && [...side.querySelectorAll('h2 a, h3 a, strong a, span > a[role="link"]')]
      .find(a => a.innerText.trim() && !/online status|^active$/i.test(a.innerText.trim()));
    const author = (authorEl?.innerText || '').trim().split('\n')[0];
    const caption = ((side?.querySelector('[data-ad-rendering-role="story_message"]')?.innerText) ||
      captionIn(side, author) || (document.querySelector('[data-ad-rendering-role="story_message"]')?.innerText) ||
      String(getSelection() || '')).trim().replace(SEE, '');
    const first = caption.split('\n').find(l => l.trim()) || '';
    const docTitle = document.title.replace(/^\(\d+\+?\)\s*/, '').replace(/\s*\|\s*Facebook$/, '').trim();
    const title = author ? `${author}: ${first || 'Facebook ' + (/photo/.test(location.pathname) ? 'photo' : 'video')}` : (first || docTitle || 'Facebook');
    return { url: clean(location.href), title: title.slice(0, 100),
             text: caption.slice(0, 2000) + (author ? `\n\nby ${author} on Facebook` : '') };
  }

  function send(oracle, d) {
    if (window.chrome?.runtime?.sendMessage) chrome.runtime.sendMessage({ kind: 'issue', oracle, ...d });
    else console.log('[oracle] would send', oracle, d);
  }

  // The 🔮 every action row gets: click → DEFAULT, ⇧-click → pick the oracle.
  function barButton(getDetails) {
    const btn = document.createElement('div');
    btn.setAttribute('role', 'button'); btn.tabIndex = 0;
    btn.title = `New issue in ${DEFAULT} Oracle (⇧-click: another oracle)`;
    btn.setAttribute('data-oracle-btn', '1');
    btn.textContent = `🔮 ${DEFAULT}`;
    Object.assign(btn.style, { display: 'flex', alignItems: 'center', justifyContent: 'center', flex: '1 1 0',
      cursor: 'pointer', borderRadius: '6px', color: '#b0b3b8', font: '600 15px system-ui, sans-serif', padding: '6px 0' });
    btn.onmouseenter = () => (btn.style.background = 'rgba(255,255,255,.06)'); btn.onmouseleave = () => (btn.style.background = '');
    btn.onclick = async (e) => {
      e.stopPropagation(); e.preventDefault();
      if (e.shiftKey) return menu(btn, null, getDetails);
      send(DEFAULT, await getDetails());
    };
    return btn;
  }

  function addButtons() {
    for (const like of document.querySelectorAll(LIKE)) {
      const wrap = (like.closest('[role="button"]') || like).parentElement;
      const bar = wrap?.parentElement;
      if (!bar) continue;
      const post = postOf(like);
      if (!post) continue;
      headerChip(post, () => details(post));   // checked every pass: Facebook re-renders headers
      if (bar.hasAttribute(MARK)) continue;
      bar.setAttribute(MARK, '1');
      bar.lastElementChild.after(barButton(() => details(post)));   // after Share, or after Comment when there is no Share
    }
    addHeaderChip();
    addCommentButtons();
  }

  // A comment's own link is its timestamp ("23h" → permalink.php?story_fbid=…&comment_id=…); the commenter's name
  // links to their profile. Links typed in the comment leave through l.facebook.com/l.php?u=<the real URL>.
  async function commentDetails(art) {
    const own = [...art.querySelectorAll('a[href]')].filter(a => a.closest('[role="article"]') === art);
    await resolve(own);
    const name = (own.find(a => a.innerText.trim())?.innerText || '').trim().split('\n')[0];
    const time = own.find(a => /comment_id=/.test(a.href) && /permalink|story_fbid|\/posts\/|fbid=|\/videos\/|\/reel\//.test(a.href));
    const out = [...new Set(own.map(a => {
      try {
        const u = new URL(a.href);
        if (u.hostname === 'l.facebook.com') return u.searchParams.get('u');
        return /(^|\.)facebook\.com$/.test(u.hostname) ? null : u.href;
      } catch { return null; }
    }).filter(Boolean))];
    const text = captionIn(art, name);
    const first = text.split('\n').find(l => l.trim()) || out[0] || 'Facebook comment';
    return { url: clean(time ? time.href : location.href), title: (name ? name + ': ' : '') + first.slice(0, 90),
             text: text.slice(0, 2000) + out.map(h => `\nLink: ${h}`).join('') + (name ? `\n\ncomment by ${name} on Facebook` : '') };
  }

  // A small purple chip that sits inline in Facebook's own text rows (header line, next to Reply).
  function chip(label, title, getDetails, attr) {
    const c = document.createElement('span');
    c.setAttribute('role', 'button'); c.tabIndex = 0; c.setAttribute(attr, '1'); c.textContent = label; c.title = title;
    // a big hand-cursor target (Nat: "make hand mouse click region larger"): generous padding, pulled back with
    // negative margins so the header line keeps its height
    Object.assign(c.style, { margin: '-8px -4px -8px 4px', padding: '9px 14px', borderRadius: '14px', background: 'rgba(171,71,188,.18)',
      color: '#e1bee7', font: '600 13px system-ui, sans-serif', cursor: 'pointer', whiteSpace: 'nowrap', alignSelf: 'center', userSelect: 'none' });
    c.onmouseenter = () => (c.style.background = 'rgba(171,71,188,.38)'); c.onmouseleave = () => (c.style.background = 'rgba(171,71,188,.18)');
    c.onclick = async (e) => {
      e.stopPropagation(); e.preventDefault();
      if (e.shiftKey) return menu(c, null, getDetails);
      send(DEFAULT, await getDetails());
    };
    return c;
  }

  // 🔮 on a header line, after "a day ago · globe" (Nat marked that spot, 2026-10-07). The line is the flex div that
  // holds the time link (first link after the author's name) and the privacy globe — and not the name itself.
  // Photo panel: root = the right panel; feed post: root = the post.
  function headerChip(root, getDetails) {
    if (!root || root.querySelector('[data-oracle-head]')) return;
    const links = [...root.querySelectorAll('a')].filter(a => !a.closest('[role="article"]') || a.closest('[role="article"]') === root);
    const nameEl = root.querySelector('[data-ad-rendering-role="profile_name"]');
    const name = nameEl ? links.find(a => nameEl.contains(a)) : links.find(a => a.innerText.trim() && !/online status|^active$/i.test(a.innerText.trim()));
    const time = name && links.find(a => (name.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING) && !(nameEl || name).contains(a));
    let line = time; while (line && line !== root && !(line.tagName === 'DIV' && getComputedStyle(line).display === 'flex' && line.querySelector('svg') && !line.contains(name))) line = line.parentElement;
    if (!line || line === root) return;
    const c = chip(`🔮 ${DEFAULT}`, `New issue in ${DEFAULT} Oracle for this post (⇧-click: another oracle)`, getDetails, 'data-oracle-btn');
    c.setAttribute('data-oracle-head', '1');
    line.append(c);
  }
  function addHeaderChip() { headerChip(document.querySelector('[role="complementary"]'), pageDetails); }

  // 🔗 inline after every comment's Reply (Nat via the right pane, 2026-10-07): sends THAT comment — its link,
  // text and the links in it. Reply lives in an <li> inside a wrapper div; the chip is that wrapper's next sibling in the same flex row.
  function addCommentButtons() {
    for (const reply of document.querySelectorAll('[role="article"] [role="button"]')) {
      if (!/^(reply|ตอบกลับ)$/i.test(reply.textContent.trim())) continue;
      const art = reply.closest('[role="article"]'), ul = reply.closest('li')?.parentElement;   // Facebook's <li> sits in a <div>, not a <ul>
      if (!art || !ul || !art.contains(ul) || ul.nextElementSibling?.hasAttribute('data-oracle-comment')) continue;
      ul.after(chip(`🔗 ${DEFAULT}`, `Send this comment's link to ${DEFAULT} Oracle (⇧-click: another oracle)`, () => commentDetails(art), 'data-oracle-comment'));
    }
  }

  // Video (/watch, /videos/), photo (/photo/?fbid=) and reel pages carry none of the post markers above
  // (measured 2026-10-07: no like_button there) — but there the page IS the post: a floating pill sends its link.
  const SINGLE = /\/videos\/|\/watch\/?\?v=|\/photo\/?\?fbid=|\/photo\.php|\/reel\/\d|\/posts\/|\/permalink|story\.php/;
  function pill() {
    let p = document.getElementById('oracle-nexus-pill');
    const want = SINGLE.test(location.href) && !document.querySelector('[data-oracle-btn]');
    if (!want) { p?.remove(); return; }
    if (p) return;
    p = document.createElement('div');
    p.id = 'oracle-nexus-pill'; p.setAttribute('role', 'button'); p.textContent = `🔮 ${DEFAULT}`;
    p.title = `New issue in ${DEFAULT} Oracle for this page (⇧-click: another oracle)`;
    Object.assign(p.style, { position: 'fixed', right: '24px', bottom: '24px', zIndex: 2147483646, cursor: 'pointer',
      background: '#242526', color: '#e4e6eb', border: '1px solid #3a3b3c', borderRadius: '999px', padding: '10px 16px',
      font: '600 15px system-ui, sans-serif', boxShadow: '0 6px 20px rgba(0,0,0,.45)' });
    p.onclick = async (e) => {
      e.stopPropagation(); e.preventDefault();
      if (e.shiftKey) return menu(p, null, pageDetails);
      send(DEFAULT, await pageDetails());
    };
    document.body.append(p);
  }

  let t;
  new MutationObserver(() => { clearTimeout(t); t = setTimeout(() => { addButtons(); pill(); }, 400); })
    .observe(document.body, { childList: true, subtree: true });
  addButtons(); pill();
})();
