// Facebook URL → graph node ids. Pure (no server, no db) so it can be tested and so a rebuild from the JSONL gives the
// same graph. Node ids: user:<name|num>  post:<pfbid|num>  comment:<num>  photo:<fbid>  video:<num>  album:<num>
// group:<id|name>  url:<external href>
const RESERVED = new Set(['watch', 'groups', 'photo', 'photo.php', 'reel', 'reels', 'marketplace', 'events', 'pages', 'gaming', 'stories', 'permalink.php',
  'story.php', 'profile.php', 'hashtag', 'share', 'messages', 'notifications', 'friends', 'bookmarks', 'saved', 'login', 'search', 'people', 'ads']);
export type N = { id: string; type: string; url: string };
export function nodesOf(href: string): N[] {   // one URL can name several nodes (a reply link names the reply, its parent and the post)
  if (!href) return [];
  let u: URL; try { u = new URL(href); } catch { return []; }
  if (!/(^|\.)facebook\.com$/.test(u.hostname)) {   // an outside link: drop Facebook's click ids and utm_* so one page is one node
    for (const k of [...u.searchParams.keys()]) if (k === 'fbclid' || k.startsWith('utm_') || k === '__cft__' || k === '__tn__') u.searchParams.delete(k);
    return [{ id: `url:${u.origin}${u.pathname}${u.search}`, type: 'link', url: u.href }];
  }
  const p = u.pathname.split('/').filter(Boolean), q = u.searchParams, out: N[] = [];
  const add = (type: string, id: string) => { if (id) out.push({ id: `${type}:${id}`, type, url: u.href }); };
  const reply = q.get('reply_comment_id'), comment = q.get('comment_id');
  if (reply) add('comment', reply);
  if (comment && /^\d+$/.test(comment)) add('comment', comment);
  if (p[0] === 'groups' && p[1]) {
    add('group', p[1]);
    if (p[2] === 'posts' || p[2] === 'permalink') add('post', p[3]);
    if (p[2] === 'user' && p[3]) add('user', p[3]);   // a member, as linked inside the group
    if (q.get('multi_permalinks')) add('post', q.get('multi_permalinks')!);
  }
  else if (p[1] === 'posts' && p[2]) { add('post', p[2]); add('user', p[0]); }
  else if (/^(permalink|story)\.php$/.test(p[0] || '')) { add('post', q.get('story_fbid') || ''); add('user', q.get('id') || ''); }
  else if (p[0] === 'photo' || p[0] === 'photo.php') {
    add('photo', q.get('fbid') || ''); const set = q.get('set') || '';
    if (set.startsWith('a.')) add('album', set.slice(2)); if (set.startsWith('pcb.')) add('post', set.slice(4));
  }
  else if (p[0] === 'reel' && p[1]) add('video', p[1]);
  else if (p[1] === 'videos' && p[2]) { add('video', p[2]); add('user', p[0]); }
  else if (p[0] === 'watch') add('video', q.get('v') || '');
  else if (p[0] === 'profile.php') add('user', q.get('id') || '');
  else if (p[0] === 'people' && p[2]) add('user', p[2]);
  else if (p.length === 1 && !RESERVED.has(p[0])) add('user', p[0]);
  return out;
}
