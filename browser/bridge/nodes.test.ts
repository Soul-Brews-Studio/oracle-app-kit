import { test, expect } from 'bun:test';
import { nodesOf } from './nodes.ts';
const ids = (h: string) => nodesOf(h).map(n => n.id);
test('post + comment', () => expect(ids('https://www.facebook.com/nat.wrw/posts/pfbid0U5?comment_id=2871912116526153')).toEqual(['comment:2871912116526153', 'post:pfbid0U5', 'user:nat.wrw']));
test('reply names reply, parent, post', () => expect(ids('https://www.facebook.com/permalink.php?story_fbid=pfbid02Uw&id=61555688363983&comment_id=1650&reply_comment_id=999'))
  .toEqual(['comment:999', 'comment:1650', 'post:pfbid02Uw', 'user:61555688363983']));
test('photo + album', () => expect(ids('https://www.facebook.com/photo/?fbid=122299734638189612&set=a.122095564712189612')).toEqual(['photo:122299734638189612', 'album:122095564712189612']));
test('photo in a post', () => expect(ids('https://www.facebook.com/photo/?fbid=1017&set=pcb.1018')).toEqual(['photo:1017', 'post:1018']));
test('reel', () => expect(ids('https://www.facebook.com/reel/3376772145863784')).toEqual(['video:3376772145863784']));
test('group post', () => expect(ids('https://www.facebook.com/groups/1461988771737551/?multi_permalinks=1751145816155177')).toEqual(['group:1461988771737551', 'post:1751145816155177']));
test('profile', () => { expect(ids('https://www.facebook.com/profile.php?id=61555688363983')).toEqual(['user:61555688363983']); expect(ids('https://www.facebook.com/piyalitt')).toEqual(['user:piyalitt']); });
test('reserved words are not users', () => expect(ids('https://www.facebook.com/marketplace')).toEqual([]));
test('external link', () => expect(ids('https://github.com/gain9999/thaiwater')[0]).toBe('url:https://github.com/gain9999/thaiwater'));
test('group post + member', () => {
  expect(ids('https://www.facebook.com/groups/1461988771737551/posts/1610261913576902/')).toEqual(['group:1461988771737551', 'post:1610261913576902']);
  expect(ids('https://www.facebook.com/groups/1461988771737551/user/61588028537843/')).toEqual(['group:1461988771737551', 'user:61588028537843']);
});
test('outside links lose fbclid / utm_*', () => {
  expect(ids('https://github.com/Soul-Brews-Studio/maw-js?fbclid=IwZXh0bgNhZW0')).toEqual(['url:https://github.com/Soul-Brews-Studio/maw-js']);
  expect(ids('https://book.buildwithoracle.com/?utm_source=fb&x=1')).toEqual(['url:https://book.buildwithoracle.com/?x=1']);
});
