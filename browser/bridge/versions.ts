// Is a post we already hold the same, or does it need an update? Pure, so it is testable.
// A snapshot is what we know about one node: its text, its comments (id → text), its media ids, its outside links.
// Facebook shows a post differently each time (a cut caption, one comment in the feed, the whole thread on its own
// page), so a capture only ADDS: a shorter view of the same text, or fewer comments than we hold, is "same";
// longer or different text, a new comment, an edited comment, new media or links is "updated".
export type Snap = { text: string; comments: Record<string, string>; media: string[]; links: string[] };
export const tidy = (t: unknown) => String(t ?? '').replace(/\s*…?\s*(see more|see less|ดูเพิ่มเติม|ดูน้อยลง)\s*$/i, '').replace(/\s+/g, ' ').trim();

export function compare(prev: Snap | null, cur: Snap): { status: 'new' | 'same' | 'updated'; merged: Snap; changes: string[] } {
  if (!prev) return { status: 'new', merged: cur, changes: [] };
  const changes: string[] = [];
  const merged: Snap = { text: prev.text, comments: { ...prev.comments }, media: [...prev.media], links: [...prev.links] };
  if (cur.text && cur.text !== prev.text && !prev.text.startsWith(cur.text)) {   // a shorter view of the same text is not a change
    changes.push(cur.text.startsWith(prev.text) ? `text +${cur.text.length - prev.text.length} chars` : 'text edited');
    merged.text = cur.text;
  }
  let added = 0, longer = 0, edited = 0;
  for (const [k, t] of Object.entries(cur.comments)) {
    const old = merged.comments[k];
    if (old === undefined) { added++; merged.comments[k] = t; continue; }
    if (!t || t === old || old.startsWith(t)) continue;
    if (t.startsWith(old)) longer++; else edited++;
    merged.comments[k] = t;
  }
  const n = (x: number, one: string) => `${x} ${one}${x > 1 ? 's' : ''}`;
  if (added) changes.push(`+${n(added, 'comment')}`);
  if (longer) changes.push(`${n(longer, 'comment')} longer`);
  if (edited) changes.push(`${n(edited, 'comment')} edited`);
  const union = (a: string[], b: string[], what: string) => {
    const have = new Set(a), fresh = b.filter(x => !have.has(x));
    if (fresh.length) changes.push(`+${fresh.length} ${what}`);
    return [...a, ...fresh];
  };
  merged.media = union(prev.media, cur.media, 'media');
  merged.links = union(prev.links, cur.links, 'links');
  return { status: changes.length ? 'updated' : 'same', merged, changes };
}
