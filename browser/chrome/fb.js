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

  // What the post SHOWS besides words: each photo/video links to its own page; the alt text is Facebook's description.
  function mediaLines(root) {
    const seen = new Set(), lines = [];
    for (const a of root.querySelectorAll('a[href*="/photo"], a[href*="/videos/"], a[href*="/reel/"]')) {
      if (a.closest('[role="article"]') && a.closest('[role="article"]') !== root) continue;   // not a comment's
      const h = clean(a.href); if (!POSTLINK.test(h) || seen.has(h)) continue; seen.add(h);
      const alt = a.querySelector('img[alt]')?.getAttribute('alt') || '';
      lines.push(`- ${/photo/.test(h) ? 'photo' : 'video'}: <${h}>${alt && !/^no photo description/i.test(alt) ? ` — ${alt.slice(0, 160)}` : ''}`);
    }
    return lines.length ? `\n\nMedia (${lines.length}):\n${lines.slice(0, 12).join('\n')}` : '';
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
    const media = mediaLines(post);
    return { url: own || shared[0] || '', title: (author ? author + ': ' : '') + first.slice(0, 90),
             text: text.slice(0, 20000) + (author ? `\n\nby ${author} on Facebook` : '') +
                   shared.map(h => `\nShared post: ${h}`).join('') + media };
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

  // The panel that holds THIS photo's post. Coming from the feed, the feed's own right rail (Birthdays, Contacts) is
  // also role=complementary and comes first in the DOM, so querySelector picked the wrong one (Nat: header chip
  // missing after a click from the feed, present after a refresh). The post's panel has the Like/Comment buttons
  // (named by aria-label) or comment articles; the rail has neither.
  function sidePanel() {
    const all = [...document.querySelectorAll('[role="complementary"]')];
    return all.find(p => p.querySelector('[aria-label^="Comment on"], [aria-label^="React with Like"], [aria-label^="Leave a comment"], [role="article"]'))
      || (all.length === 1 ? all[0] : null)
      || reelPanel();
  }
  // Reels (Nat's /reel/3376772145863784, measured in Ego 2026-10-07): no role=complementary, no data-ad-rendering-role.
  // The panel is the nearest block above the comments that also holds the author's "Shared with …" globe.
  const GLOBE = '[aria-label^="Shared with"], [aria-label^="Public"]';
  function reelPanel() {
    const art = document.querySelector('[role="article"]');
    for (let n = art; n && n !== document.body; n = n.parentElement)
      if ([...n.querySelectorAll(GLOBE)].some(g => !g.closest('[role="article"]'))) return n;
    return null;
  }

  // photo/video pages: the author and caption sit in the right panel (role=complementary); the document title is
  // just "Facebook", and the time links there belong to comments (measured on Nat's photo URL, 2026-10-07)
  async function pageDetails() {
    const side = sidePanel();
    const more = side && [...side.querySelectorAll('[role="button"]')].find(b => /^(see more|ดูเพิ่มเติม)$/i.test(b.innerText.trim()));
    if (more) { more.click(); await tick(300); }
    // the right column also holds the top bar (messenger, notifications, YOUR account link), so the first link is not
    // the author (issue #14 said "Nat Weerawan:"); the Like/Comment buttons name the author in their aria-label
    const named = side && [...side.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))
      .map(l => /^Comment on (.+?)['’]s (post|photo|video|reel)/i.exec(l) || /^React with Like to (.+)$/i.exec(l)).find(Boolean);
    const authorEl = side && [...side.querySelectorAll('h2 a, h3 a, strong a, span > a[role="link"]')]
      .find(a => a.innerText.trim() && !/online status|^active$/i.test(a.innerText.trim()) && !a.closest('[role="banner"], [role="navigation"]'));
    const author = (named?.[1] || authorEl?.innerText || (side?.innerText || '').split('\n').find(l => l.trim()) || '').replace(/['’]s (post|photo|video|reel)$/i, '').trim().split('\n')[0];
    const caption = ((side?.querySelector('[data-ad-rendering-role="story_message"]')?.innerText) ||
      captionIn(side, author) || (document.querySelector('[data-ad-rendering-role="story_message"]')?.innerText) ||
      String(getSelection() || '')).trim().replace(SEE, '');
    const first = caption.split('\n').find(l => l.trim()) || '';
    const docTitle = document.title.replace(/^\(\d+\+?\)\s*/, '').replace(/\s*\|\s*Facebook$/, '').trim();
    const title = author ? `${author}: ${first || 'Facebook ' + (/photo/.test(location.pathname) ? 'photo' : 'video')}` : (first || docTitle || 'Facebook');
    return { url: clean(location.href), title: title.slice(0, 100),
             text: caption.slice(0, 2000) + (author ? `\n\nby ${author} on Facebook` : '') };
  }

  // ── the whole thread, as a human sees it ─────────────────────────────────────────────────────────────────────
  // Every comment keeps its own link (comment_id from its timestamp) so a reply can find it again. The markdown goes to
  // the bridge (a thread is too big for a URL); the draft in the app reads it from ~/.oracle-fb/threads/<id>.md.
  const hash = (str) => { let h = 5381; for (const ch of str) h = ((h << 5) + h + ch.charCodeAt(0)) >>> 0; return h.toString(36).padStart(6, '0').slice(0, 8); };
  const EXPAND = /^(view (all )?(\d+ )?(more |previous )?(repl|comment)|(view |see )?(more|previous) comments|ดูความคิดเห็น|ดู \d+ การตอบกลับ)/i;
  async function expandThread(root) {
    for (let round = 0; round < 8; round++) {
      const more = [...root.querySelectorAll('[role="button"]')].filter(b => !b.hasAttribute('data-oracle-open') &&
        (EXPAND.test(b.textContent.trim()) || (/^(see more|ดูเพิ่มเติม)$/i.test(b.textContent.trim()) && b.closest('[role="article"]'))));
      if (!more.length) break;
      more.forEach(b => { b.setAttribute('data-oracle-open', '1'); b.click(); });
      await tick(1000);
    }
  }
  const COMMENT_LABEL = /^(comment|reply) (by|to)\b|^(ความคิดเห็น|ตอบกลับ)/i;
  async function collectThread(root, d) {
    await expandThread(root);
    const arts = [...root.querySelectorAll('[role="article"]')].filter(a => a !== root && COMMENT_LABEL.test(a.getAttribute('aria-label') || ''));
    const comments = [];
    const owned = new Map(arts.map(art => [art, [...art.querySelectorAll('a[href]')].filter(a => a.closest('[role="article"]') === art)]));
    await resolve([...owned.values()].flat());
    for (const art of arts) {
      const own = owned.get(art);
      const time = own.find(a => /comment_id=/.test(a.href) && /permalink|story_fbid|\/posts\/|fbid=|\/videos\/|\/reel\//.test(a.href));
      const id = time ? (time.href.match(/reply_comment_id=(\d+)/) || time.href.match(/comment_id=(\d+)/) || [])[1] || '' : '';
      const author = (own.find(a => a.innerText.trim())?.innerText || '').trim().split('\n')[0];
      const text = captionIn(art, author);
      const out = [...new Set(own.map(a => { try { const u = new URL(a.href); return u.hostname === 'l.facebook.com' ? u.searchParams.get('u') : null; } catch { return null; } }).filter(Boolean))];
      comments.push({ key: `c${comments.length + 1}`, id, author, level: /^reply/i.test(art.getAttribute('aria-label') || '') ? 1 : 0,
        link: time ? clean(time.href) : '', text, links: out });
    }
    const id = hash(d.url || location.href);
    const md = [`# ${d.title}`, '', `Post: ${d.url}`, '', ...d.text.split('\n').map(l => `> ${l}`), '', `## Comments (${comments.length})`, '',
      ...comments.map(c => `${c.level ? '    ' : ''}**${c.key}** ${c.author || '?'}${c.link ? ` — <${c.link}>` : ''}\n${c.level ? '    ' : ''}${c.text.split('\n').map(l => `> ${l}`).join(`\n${c.level ? '    ' : ''}`)}` +
        c.links.map(h => `\n${c.level ? '    ' : ''}link: <${h}>`).join('') + '\n')].join('\n');
    const res = await new Promise(r => chrome.runtime.sendMessage({ kind: 'thread', thread: { id, url: d.url, title: d.title, md,
      comments: comments.map(({ key, id: cid, author, level, link }) => ({ key, id: cid, author, level, link })) } }, r));
    return { ...(res || { ok: false, error: 'no answer from the extension' }), id, md, count: comments.length };
  }

  // The 🔗 chip sends ONE comment. It still gets a reply path: a one-comment thread keyed by the comment's own link,
  // so `fbreply <id> c1 "text"` types into that comment's box (issue #16 had no way back before this).
  async function registerComment(d) {
    const cid = (d.url.match(/reply_comment_id=(\d+)/) || d.url.match(/comment_id=(\d+)/) || [])[1] || '';
    const id = hash(d.url);
    const md = `# ${d.title}\n\nComment: ${d.url}\n\n${d.text.split('\n').map(l => `> ${l}`).join('\n')}`;
    const res = await new Promise(r => chrome.runtime.sendMessage({ kind: 'thread', thread: { id, url: d.url, title: d.title, md,
      comments: [{ key: 'c1', id: cid, author: d.author || '', level: 0, link: d.url }] } }, r));
    return { ...(res || { ok: false, error: 'no answer from the extension' }), id, md, count: 1 };
  }

  // ── bridge → page: type a reply into one comment's box, never submit ──────────────────────────────────────────
  async function fillReply({ comment, text }) {
    let art = null;
    for (let i = 0; i < 30 && !art; i++) {
      for (const a of document.querySelectorAll('[role="article"]')) {
        const own = [...a.querySelectorAll('a[href]')].filter(x => x.closest('[role="article"]') === a);
        await resolve(own);
        if (own.some(x => x.href.includes(`comment_id=${comment}`))) { art = a; break; }
      }
      if (!art) await tick(500);
    }
    if (!art) return { ok: false, note: `comment ${comment} is not on this page (open the post, expand its replies)` };
    art.scrollIntoView({ block: 'center' });
    const btn = [...art.querySelectorAll('[role="button"]')].find(b => /^(reply|ตอบกลับ)$/i.test(b.textContent.trim()));
    if (!btn) return { ok: false, note: 'no Reply button on that comment' };
    btn.click();
    let box = null;
    for (let i = 0; i < 20 && !box; i++) {
      await tick(250);
      const y = art.getBoundingClientRect().bottom;
      box = [...document.querySelectorAll('div[contenteditable="true"][role="textbox"]')]
        .filter(b => /^(reply|ตอบกลับ)/i.test(b.getAttribute('aria-label') || b.getAttribute('aria-placeholder') || ''))
        .sort((p, q) => Math.abs(p.getBoundingClientRect().top - y) - Math.abs(q.getBoundingClientRect().top - y))[0] || null;
    }
    if (!box) return { ok: false, note: 'the reply box did not open' };
    box.focus();
    const sel = getSelection(); sel.selectAllChildren(box); sel.collapseToEnd();   // after the @mention Facebook pre-fills
    document.execCommand('insertText', false, text);
    await tick(300);
    const ok = box.innerText.includes(text.slice(0, 12));
    return ok ? { ok: true, note: 'typed — press Enter in Chrome to post' } : { ok: false, note: 'Facebook did not accept the text' };
  }
  if (window.chrome?.runtime?.onMessage) chrome.runtime.onMessage.addListener((msg, _s, reply) => {
    if (msg?.kind === 'fillReply') { fillReply(msg).then(reply, (e) => reply({ ok: false, note: String(e) })); return true; }
  });

  // Click → a small box opens beside the button with the cursor already in it: type a note, Enter sends (⇧Enter =
  // new line, Esc closes). The note goes first in the issue body. (Nat: "when click it should input box popup and
  // active in the box, let me type and can enter using keyboard".) Facebook binds single-key shortcuts and traps
  // focus inside its dialogs, so the box lives INSIDE the nearest dialog and swallows its own key events.
  function compose(anchor, getDetails, getThread, inclLabel = 'Include every comment (each with its own link)') {
    document.querySelectorAll('.oracle-compose').forEach(m => m.remove());
    const host = anchor.closest('[role="dialog"]') || document.body;
    const box = document.createElement('div');
    box.className = 'oracle-compose';
    Object.assign(box.style, { position: 'fixed', zIndex: 2147483647, width: '320px', padding: '10px', borderRadius: '14px',
      background: '#242526', color: '#e4e6eb', border: '1px solid #ab47bc', boxShadow: '0 10px 30px rgba(0,0,0,.6)',
      font: '14px system-ui, sans-serif' });
    let oracle = DEFAULT;
    const head = document.createElement('div');
    Object.assign(head.style, { display: 'flex', gap: '6px', alignItems: 'center', marginBottom: '8px' });
    const label = document.createElement('span'); label.textContent = 'New issue in'; label.style.opacity = '.65';
    head.append(label);
    const pick = {};
    for (const o of ORACLES) {
      const b = document.createElement('span'); b.textContent = o; pick[o] = b;
      Object.assign(b.style, { padding: '3px 10px', borderRadius: '10px', cursor: 'pointer', font: '600 12px system-ui, sans-serif' });
      b.onclick = (e) => { e.stopPropagation(); oracle = o; paint(); ta.focus(); };
      head.append(b);
    }
    const paint = () => { for (const o of ORACLES) { pick[o].style.background = o === oracle ? '#ab47bc' : 'rgba(171,71,188,.18)'; pick[o].style.color = o === oracle ? '#fff' : '#e1bee7'; } };
    paint();
    const ta = document.createElement('textarea');
    ta.placeholder = 'Add a note…  (Enter = send, ⇧Enter = new line, Esc = close)'; ta.rows = 3;
    Object.assign(ta.style, { width: '100%', boxSizing: 'border-box', resize: 'vertical', background: '#18191a', color: '#e4e6eb',
      border: '1px solid #3a3b3c', borderRadius: '8px', padding: '8px', font: '14px system-ui, sans-serif', outline: 'none' });
    const incl = document.createElement('label');
    Object.assign(incl.style, { display: getThread ? 'flex' : 'none', gap: '6px', alignItems: 'center', margin: '8px 0 0', cursor: 'pointer', fontSize: '13px' });
    const cb = document.createElement('input'); cb.type = 'checkbox'; cb.checked = true;
    incl.append(cb, document.createTextNode(inclLabel));
    const foot = document.createElement('div');
    Object.assign(foot.style, { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '8px' });
    const hint = document.createElement('span'); hint.style.opacity = '.55'; hint.style.fontSize = '12px'; hint.textContent = 'Enter to send';
    const go = document.createElement('span'); go.textContent = 'Send ↵';
    Object.assign(go.style, { padding: '6px 14px', borderRadius: '10px', background: '#ab47bc', color: '#fff', cursor: 'pointer', font: '600 13px system-ui, sans-serif' });
    foot.append(hint, go);
    box.append(head, ta, incl, foot);
    const close = () => { box.remove(); document.removeEventListener('mousedown', outside, true); };
    const outside = (e) => { if (!box.contains(e.target) && !anchor.contains(e.target)) close(); };
    const submit = async () => {
      go.innerHTML = '<span class="oracle-spin">⟳</span> Sending…'; go.style.opacity = '.7';
      const base = await getDetails();   // the post as a human sees it — the note is NOT part of the thread file
      let d = base;
      const note = ta.value.trim();
      if (note) d = { ...d, text: `${note}\n\n---\n${d.text}` };
      if (getThread && cb.checked) {
        const t = await getThread(base);
        if (t.ok) d = { url: d.url, title: d.title, text: note, thread: t.id };   // the thread file already holds the whole post
        else d = { ...d, text: `${d.text}\n\n(thread not forwarded: ${t.error || 'bridge down'} — start it: bun /opt/Code/github.com/Soul-Brews-Studio/oracle-app-kit/browser/bridge/server.ts)` };
      }
      send(oracle, d);
      close();
    };
    go.onclick = (e) => { e.stopPropagation(); submit(); };
    // Facebook's own shortcuts (j/k, /, c …) and its focus trap must not see what is typed here
    for (const type of ['keydown', 'keypress', 'keyup']) box.addEventListener(type, (e) => {
      e.stopPropagation();
      if (type !== 'keydown') return;
      if (e.key === 'Escape') { e.preventDefault(); close(); }
      else if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); }   // isComposing: Thai/CJK input
    });
    box.addEventListener('mousedown', (e) => e.stopPropagation());
    host.append(box);
    const r = anchor.getBoundingClientRect();
    box.style.left = `${Math.max(8, Math.min(innerWidth - 328, r.left))}px`;
    box.style.top = `${Math.min(innerHeight - box.offsetHeight - 8, r.bottom + 8)}px`;
    setTimeout(() => document.addEventListener('mousedown', outside, true), 0);
    ta.focus();
  }

  function send(oracle, d) {
    if (window.chrome?.runtime?.sendMessage) chrome.runtime.sendMessage({ kind: 'issue', oracle, ...d });
    else console.log('[oracle] would send', oracle, d);
  }

  // The 🔮 every action row gets: click → DEFAULT, ⇧-click → pick the oracle.
  function barButton(getDetails, getThread) {
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
      compose(btn, getDetails, getThread);
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
      capturePost(post);   // every post that carries a 🔮 (header chip OR action-bar button — group posts only get the latter)
      if (bar.hasAttribute(MARK)) continue;
      bar.setAttribute(MARK, '1');
      bar.lastElementChild.after(barButton(() => details(post), (d) => collectThread(post, d)));   // after Share, or after Comment when there is no Share
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
    return { author: name, url: clean(time ? time.href : location.href), title: (name ? name + ': ' : '') + first.slice(0, 90),
             text: text.slice(0, 2000) + out.map(h => `\nLink: ${h}`).join('') + (name ? `\n\ncomment by ${name} on Facebook` : '') };
  }

  // A small purple chip that sits inline in Facebook's own text rows (header line, next to Reply).
  function chip(label, title, getDetails, attr, getThread, inclLabel) {
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
      compose(c, getDetails, getThread, inclLabel);
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
    if (!line || line === root) {   // reel: "Nat Weerawan 🌐" is one row with no time link
      const globe = [...root.querySelectorAll(GLOBE)].find(g => !g.closest('[role="article"]'));
      line = globe; while (line && line !== root && !(line.tagName === 'DIV' && getComputedStyle(line).display === 'flex')) line = line.parentElement;
      if (!line || line === root) return;
    }
    const c = chip(`🔮 ${DEFAULT}`, `New issue in ${DEFAULT} Oracle for this post (⇧-click: another oracle)`, getDetails, 'data-oracle-btn', (d) => collectThread(root, d));
    c.setAttribute('data-oracle-head', '1');
    line.append(c);
    capturePost(root);   // Nat's goal: every post that gets our 🔮 goes to the bridge whole — REC or not
  }
  function addHeaderChip() { headerChip(sidePanel(), pageDetails); }

  // 🔗 inline after every comment's Reply (Nat via the right pane, 2026-10-07): sends THAT comment — its link,
  // text and the links in it. Reply lives in an <li> inside a wrapper div; the chip is that wrapper's next sibling in the same flex row.
  function addCommentButtons() {
    for (const reply of document.querySelectorAll('[role="article"] [role="button"]')) {
      if (!/^(reply|ตอบกลับ)$/i.test(reply.textContent.trim())) continue;
      const art = reply.closest('[role="article"]'), ul = reply.closest('li')?.parentElement;   // Facebook's <li> sits in a <div>, not a <ul>
      if (!art || !ul || !art.contains(ul) || ul.nextElementSibling?.hasAttribute('data-oracle-comment')) continue;
      ul.after(chip(`🔗 ${DEFAULT}`, `Send this comment's link to ${DEFAULT} Oracle (⇧-click: another oracle)`, () => commentDetails(art), 'data-oracle-comment', (d) => registerComment(d), 'Add a reply path (an agent can answer this comment)'));
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
      compose(p, pageDetails, (d) => collectThread(sidePanel() || document.body, d));
    };
    document.body.append(p);
  }

  let t = 0;
  // A throttle, not a debounce: Facebook's feed never goes quiet (autoplay, live counters), and a timer that resets on
  // every mutation never fires — the chips lagged or never came (Nat, 2026-10-07). Reproduced in Ego: 0 chips in 6 s.
  new MutationObserver(() => { if (t) return; t = setTimeout(() => { t = 0; addButtons(); pill(); watchSeen(); watchNav(); }, 300); })
    .observe(document.body, { childList: true, subtree: true });
  addButtons(); pill();
  // ── the surrogate stream: what Nat SEES and DOES on Facebook, recorded locally ─────────────────────────────────
  // OFF by default, per tab (sessionStorage survives reloads of that tab only). On: posts/comments that stay ≥50 %
  // visible for 1 s become "seen", clicks on Like/Comment/Share/media/our chips become actions, page changes become
  // "nav". Batched every 3 s to the bridge (127.0.0.1 only) → ~/.oracle-fb/stream/<day>.jsonl + stream.db.
  // Passive: it never clicks anything to read (no "See more"), so what it stores is what was on screen.
  const recOn = () => sessionStorage.getItem('oracleRec') === '1';
  if (!document.getElementById('oracle-style')) {   // the loading animation (Nat: "show some icon for animation loading")
    const st = document.createElement('style'); st.id = 'oracle-style';
    st.textContent = '@keyframes oracle-spin{to{transform:rotate(360deg)}} .oracle-spin{display:inline-block;animation:oracle-spin .8s linear infinite} @keyframes oracle-pulse{50%{opacity:.35}} .oracle-pulse{animation:oracle-pulse 1s ease-in-out infinite}';
    document.documentElement.append(st);
  }
  let flight = 0, sent = 0, lastKinds = '', lastErr = '';
  const paintFlight = () => {
    const rec = document.getElementById('oracle-rec'); if (!rec || !recOn()) return;
    rec.innerHTML = flight ? '<span class="oracle-spin">⟳</span> sending…' : `<span class="${lastErr ? '' : 'oracle-pulse'}">●</span> REC ${sent ? `· ${sent} sent` : ''}${lastErr ? ' ⚠' : ''}`;
    rec.title = lastErr ? `last send failed: ${lastErr}` : `recording this tab (local only). sent ${sent}${lastKinds ? ` · last batch: ${lastKinds}` : ''}\nclick to stop`;
  };
  const queue = [];
  const emit = (ev) => { if (recOn()) queue.push({ ts: Date.now(), url: clean(location.href), ...ev }); };
  setInterval(() => {
    if (!queue.length) return;
    const batch = queue.splice(0, queue.length);
    flight++; paintFlight();
    const t0 = Date.now();
    chrome.runtime?.sendMessage({ kind: 'events', events: batch }, (r) => setTimeout(() => {   // keep the spinner up ≥ 700 ms: a 20 ms send is otherwise invisible
      flight--;
      if (r?.ok) { sent += batch.length; lastErr = ''; lastKinds = [...new Set(batch.map(e => e.kind))].join(','); markCollected(r.ids || {}); }
      else { lastErr = 'bridge not reachable — kept the newest 200'; queue.unshift(...batch.slice(-200)); }   // bridge down: keep the newest 200
      paintFlight();
    }, Math.max(0, 700 - (Date.now() - t0))));
  }, 3000);

  // The post's 🔮 header chip shows whether the bridge holds it: "🔮 Nexus ✓" + the node id in the tooltip.
  const clock = (ms) => new Date(ms).toLocaleTimeString('en-GB');
  function markCollected(ids) {
    for (const [key, n] of Object.entries(ids)) {
      for (const post of document.querySelectorAll('[data-oracle-key]')) {
        if (post.dataset.oracleKey !== key) continue;
        const c = post.querySelector('[data-oracle-head]') || post.querySelector('[data-oracle-btn]'); if (!c) continue;   // group posts: the action-bar 🔮
        c.dataset.collected = n.id || 'hash';
        c.textContent = `🔮 ${DEFAULT} ✓`;
        c.title = n.id ? `collected as ${n.id}\nseen ${n.seen || 1}× · first ${n.first_seen ? clock(n.first_seen) : 'now'}\nclick: new issue in ${DEFAULT} Oracle`
          : `collected (${n.note || 'no id'})\nclick: new issue in ${DEFAULT} Oracle`;
        c.style.boxShadow = 'inset 0 0 0 1px rgba(102,187,106,.7)';
      }
    }
  }
  const seenKeys = new Set(), timers = new Map();
  const io = new IntersectionObserver((entries) => {
    for (const en of entries) {
      const el = en.target;
      if (en.isIntersecting && en.intersectionRatio >= 0.5) {
        if (!timers.has(el)) timers.set(el, setTimeout(() => { timers.delete(el); sawIt(el); }, 1000));
      } else { clearTimeout(timers.get(el)); timers.delete(el); }
    }
  }, { threshold: [0, 0.5] });
  async function sawIt(el) {
    if (!recOn() || !el.isConnected) return;
    if (el.getAttribute('role') === 'article') {   // a comment
      const own = [...el.querySelectorAll('a[href]')].filter(a => a.closest('[role="article"]') === el);
      await resolve(own);
      const time = own.find(a => /comment_id=/.test(a.href));
      const author = (own.find(a => a.innerText.trim())?.innerText || '').trim().split('\n')[0];
      const key = time ? clean(time.href) : hash(author + el.innerText.slice(0, 80));
      if (seenKeys.has(key)) return; seenKeys.add(key);
      const authorUrl = own.find(a => a.innerText.trim())?.href || '';
      const external = own.map(a => { try { const u = new URL(a.href); return u.hostname === 'l.facebook.com' ? u.searchParams.get('u') : null; } catch { return null; } }).filter(Boolean);
      return emit({ kind: 'comment-seen', key, author, authorUrl: clean(authorUrl), link: time ? clean(time.href) : '', text: captionIn(el, author).slice(0, 4000), external });
    }
    const author = (el.querySelector('[data-ad-rendering-role="profile_name"]')?.innerText || '').split('\n')[0].trim();
    const text = (el.querySelector('[data-ad-rendering-role="story_message"]')?.innerText || captionIn(el, author)).trim();
    const { own, shared } = await links(el);
    const key = own || hash(author + text.slice(0, 120));
    el.dataset.oracleKey = key;
    if (seenKeys.has(key)) return; seenKeys.add(key);
    const nameA = el.querySelector('[data-ad-rendering-role="profile_name"] a[href]');
    const anchors = [...el.querySelectorAll('a[href]')].filter(a => !a.closest('[role="article"]') || a.closest('[role="article"]') === el);
    const media = [...new Set(anchors.map(a => a.href).filter(h => /\/photo|\/videos\/|\/reel\/|\/watch/.test(h)).map(clean))].slice(0, 30);
    const group = anchors.map(a => a.href).find(h => /\/groups\/[^/?]+/.test(h)) || '';
    const external = [...new Set(anchors.map(a => { try { const u = new URL(a.href); return u.hostname === 'l.facebook.com' ? u.searchParams.get('u') : null; } catch { return null; } }).filter(Boolean))].slice(0, 20);
    emit({ kind: 'seen', key, author, authorUrl: nameA ? clean(nameA.href) : '', link: own, text: text.slice(0, 8000), media: media.length,
      mediaUrls: media, shared, group: group ? clean(group) : '', external });
  }
  function watchSeen() {
    if (!recOn()) return;
    for (const like of document.querySelectorAll(LIKE)) { const p = postOf(like); if (p && !p.hasAttribute('data-oracle-watch')) { p.setAttribute('data-oracle-watch', '1'); io.observe(p); } }
    for (const a of document.querySelectorAll('[role="article"]')) {
      if (!a.hasAttribute('data-oracle-watch') && /^(comment|reply) (by|to)\b/i.test(a.getAttribute('aria-label') || '')) { a.setAttribute('data-oracle-watch', '1'); io.observe(a); }
    }
  }
  // what Nat DOES: one capture listener, classified by Facebook's own markers
  document.addEventListener('click', (e) => {
    if (!recOn()) return;
    const t = e.target instanceof Element ? e.target : null; if (!t) return;
    const post = t.closest('[data-oracle-key]')?.dataset.oracleKey || '';
    const role = t.closest('[data-ad-rendering-role]')?.getAttribute('data-ad-rendering-role') || '';
    const btn = t.closest('[role="button"], a[href]');
    if (t.closest('[data-oracle-btn], [data-oracle-comment], #oracle-nexus-pill')) return emit({ kind: 'oracle', post, text: t.textContent.trim().slice(0, 40) });
    if (role === 'like_button') return emit({ kind: 'react', post });
    if (role === 'comment_button') return emit({ kind: 'open-comments', post });
    if (role === 'share_button') return emit({ kind: 'share', post });
    const a = t.closest('a[href]');
    if (a && /\/photo|\/videos\/|\/reel\//.test(a.href)) return emit({ kind: 'open-media', post, link: clean(a.href) });
    if (btn && /^(reply|ตอบกลับ)$/i.test(btn.textContent.trim())) return emit({ kind: 'reply-open', post, text: btn.closest('[role="article"]')?.getAttribute('aria-label') || '' });
  }, true);
  let lastUrl = '';
  function watchNav() {
    if (!recOn() || location.href === lastUrl) return;
    lastUrl = location.href;
    emit({ kind: 'nav', key: clean(location.href), text: document.title });
  }

  // ── capture: the whole post as it is on screen right now, once per page view, for every post that gets a 🔮 chip ──
  // Feed post (root = the post), photo panel or reel (root = its panel). Passive like the stream: no "See more" click,
  // so a long caption is kept as far as Facebook shows it until the 🔮 itself is clicked.
  async function capturePost(root) {
    if (!root || root.hasAttribute('data-oracle-captured')) return;
    root.setAttribute('data-oracle-captured', '1');
    await tick(600);   // let Facebook finish drawing the post
    const isPanel = !root.querySelector('[data-ad-rendering-role="profile_name"]');
    const named = [...root.querySelectorAll('[aria-label]')].map(e => e.getAttribute('aria-label'))
      .map(l => /^Comment on (.+?)['’]s (post|photo|video|reel)/i.exec(l) || /^React with Like to (.+)$/i.exec(l)).find(Boolean);
    const author = ((root.querySelector('[data-ad-rendering-role="profile_name"]')?.innerText) || named?.[1] ||
      (root.innerText || '').split('\n').find(l => l.trim() && !/online status|^active$/i.test(l.trim())) || '').replace(/['’]s (post|photo|video|reel)$/i, '').split('\n')[0].trim();
    const text = ((root.querySelector('[data-ad-rendering-role="story_message"]')?.innerText) || captionIn(root, author) || '').trim();
    const { own, shared } = await links(root);
    let link = own || (isPanel ? clean(location.href) : '');
    const mine = [...root.querySelectorAll('a[href]')].filter(a => !a.closest('[role="article"]') || a.closest('[role="article"]') === root);
    if (!link) {   // group posts and some layouts: the post's link is elsewhere in it ("29 comments", the time) — any post-shaped link
      await resolve(mine);
      link = clean(mine.map(a => a.href).find(h => /\/groups\/[^/]+\/(posts|permalink)\/\d+|\/[^/]+\/posts\/(pfbid|\d)|permalink\.php|story\.php|\/reel\/\d|\/videos\/\d/.test(h)) || '');
    }
    const ad = !link && !!root.querySelector('a[href*="/ads/"], a[href*="ads/about"]');   // an ad has no post of its own
    const key = link || `${ad ? 'ad:' : ''}${hash(author + text.slice(0, 120))}`;
    root.dataset.oracleKey = key;
    const nameA = root.querySelector('[data-ad-rendering-role="profile_name"] a[href]') ||
      [...root.querySelectorAll('a[href]')].find(a => a.innerText.trim() && a.innerText.trim() === author);
    const anchors = [...root.querySelectorAll('a[href]')].filter(a => !a.closest('[role="article"]') || a.closest('[role="article"]') === root);
    const mediaUrls = [...new Set(anchors.map(a => a.href).filter(h => /\/photo|\/videos\/|\/reel\/|\/watch/.test(h)).map(clean))].slice(0, 30);
    const group = anchors.map(a => a.href).find(h => /\/groups\/[^/?]+/.test(h)) || '';
    const external = [...new Set(anchors.map(a => { try { const u = new URL(a.href); return u.hostname === 'l.facebook.com' ? u.searchParams.get('u') : null; } catch { return null; } }).filter(Boolean))].slice(0, 20);
    // the comments that are on screen with it (the feed shows one or two; a photo or post page shows the thread)
    const arts = [...root.querySelectorAll('[role="article"]')].filter(a => a !== root && /^(comment|reply) (by|to)\b/i.test(a.getAttribute('aria-label') || ''));
    const owned = new Map(arts.map(a => [a, [...a.querySelectorAll('a[href]')].filter(x => x.closest('[role="article"]') === a)]));
    await resolve([...owned.values()].flat());
    const commentList = arts.slice(0, 60).map(a => {
      const own2 = owned.get(a);
      const time = own2.find(x => /comment_id=/.test(x.href) && !/\/user\/|^https:\/\/www\.facebook\.com\/[^/]+\/?\?comment_id/.test(x.href)) || own2.find(x => /comment_id=/.test(x.href));
      const who = own2.find(x => x.innerText.trim() && !/online status/i.test(x.innerText));
      const name = (who?.innerText || '').trim().split('\n')[0];
      return { author: name, authorUrl: who ? clean(who.href) : '', link: time ? clean(time.href) : '', text: captionIn(a, name).slice(0, 4000),
        reply: /^reply/i.test(a.getAttribute('aria-label') || '') };
    });
    const comments = commentList.length;
    queue.push({ ts: Date.now(), url: clean(location.href), kind: 'post', key, author, authorUrl: nameA ? clean(nameA.href) : '', link, text: text.slice(0, 20000),
      media: mediaUrls.length, mediaUrls, shared, group: group ? clean(group) : '', external, comments, commentList, ad });
  }

  // Each tab knows its own id and shows it (the Gemini proxy's TAB:<id> badge): bottom-left, tiny; a click copies the
  // fbreply flags that aim a reply at exactly this tab. Green dot = bridge connected.
  function tabBadge() {
    chrome.runtime?.sendMessage({ kind: 'getTabId' }, (r) => {
      if (!r?.tabId) return;
      document.documentElement.dataset.oracleTab = `${r.browser}:${r.tabId}`;
      let el = document.getElementById('oracle-tab-id');
      if (!el) {
        el = document.createElement('div'); el.id = 'oracle-tab-id';
        Object.assign(el.style, { position: 'fixed', left: '10px', bottom: '10px', zIndex: 2147483645, padding: '3px 9px', borderRadius: '9px',
          background: 'rgba(36,37,38,.85)', color: '#b0b3b8', font: '600 11px ui-monospace, monospace', cursor: 'pointer', userSelect: 'none', opacity: '.75' });
        el.onmouseenter = () => (el.style.opacity = '1'); el.onmouseleave = () => (el.style.opacity = '.75');
        el.append(Object.assign(document.createElement('span'), { id: 'oracle-tab-label' }), Object.assign(document.createElement('span'), { id: 'oracle-rec' }));
        el.querySelector('#oracle-tab-label').onclick = () => { navigator.clipboard?.writeText(`--to ${r.browser} --tab ${r.tabId}`); el.title = 'copied: --to … --tab …'; };
        const rec = el.querySelector('#oracle-rec');
        Object.assign(rec.style, { marginLeft: '8px', padding: '0 6px', borderRadius: '6px' });
        rec.onclick = (e) => { e.stopPropagation(); sessionStorage.setItem('oracleRec', recOn() ? '0' : '1'); paintRec(); if (recOn()) { emit({ kind: 'rec-on' }); watchSeen(); watchNav(); } };
        document.body.append(el);
      }
      el.querySelector('#oracle-tab-label').textContent = `${r.bridge ? '●' : '○'} TAB ${r.tabId}`;
      paintRec();
      el.style.color = r.bridge ? '#a5d6a7' : '#ef9a9a';
      el.title = `${r.browser} tab ${r.tabId} — bridge ${r.bridge ? 'connected' : 'NOT connected'}\nclick: copy  --to ${r.browser} --tab ${r.tabId}`;
    });
  }
  function paintRec() {
    const rec = document.getElementById('oracle-rec'); if (!rec) return;
    if (recOn()) paintFlight(); else rec.textContent = 'REC off';
    Object.assign(rec.style, recOn() ? { background: '#c62828', color: '#fff' } : { background: 'transparent', color: '#8a8d91' });
    if (!recOn()) rec.title = 'click to record what you see in this tab (local only, stays on this Mac)';
  }
  tabBadge(); setInterval(() => { if (!document.hidden) tabBadge(); }, 5000);

  // what the toolbar badge says, readable from the page: <html data-oracle-bridge="on:ON">
  const bridgeState = () => chrome.runtime?.sendMessage({ kind: 'bridge-status' }, (r) => { document.documentElement.dataset.oracleBridge = r ? `${r.on ? 'on' : 'off'}:${r.badge}` : 'none'; });
  bridgeState(); setInterval(() => { if (!document.hidden) bridgeState(); }, 5000);   // wakes the worker so it reconnects
  document.addEventListener('visibilitychange', () => { if (!document.hidden) bridgeState(); });
})();
