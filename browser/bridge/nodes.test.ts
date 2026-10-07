import { test, expect } from 'bun:test';
import { nodesOf } from './nodes.ts';
const ids = (h: string) => nodesOf(h).map(n => n.id);
test('post + comment', () => expect(ids('https://www.facebook.com/alice/posts/pfbid0U5?comment_id=4000000001')).toEqual(['comment:4000000001', 'post:pfbid0U5', 'user:alice']));
test('reply names reply, parent, post', () => expect(ids('https://www.facebook.com/permalink.php?story_fbid=pfbid02Uw&id=1000000001&comment_id=1650&reply_comment_id=999'))
  .toEqual(['comment:999', 'comment:1650', 'post:pfbid02Uw', 'user:1000000001']));
test('photo + album', () => expect(ids('https://www.facebook.com/photo/?fbid=5000000001&set=a.6000000001')).toEqual(['photo:5000000001', 'album:6000000001']));
test('photo in a post', () => expect(ids('https://www.facebook.com/photo/?fbid=1017&set=pcb.1018')).toEqual(['photo:1017', 'post:1018']));
test('reel', () => expect(ids('https://www.facebook.com/reel/7000000001')).toEqual(['video:7000000001']));
test('group post', () => expect(ids('https://www.facebook.com/groups/2000000001/?multi_permalinks=3000000002')).toEqual(['group:2000000001', 'post:3000000002']));
test('profile', () => { expect(ids('https://www.facebook.com/profile.php?id=1000000001')).toEqual(['user:1000000001']); expect(ids('https://www.facebook.com/bob')).toEqual(['user:bob']); });
test('reserved words are not users', () => expect(ids('https://www.facebook.com/marketplace')).toEqual([]));
test('external link', () => expect(ids('https://github.com/example/repo')[0]).toBe('url:https://github.com/example/repo'));
test('group post + member', () => {
  expect(ids('https://www.facebook.com/groups/2000000001/posts/3000000001/')).toEqual(['group:2000000001', 'post:3000000001']);
  expect(ids('https://www.facebook.com/groups/2000000001/user/1000000002/')).toEqual(['group:2000000001', 'user:1000000002']);
});
test('outside links lose fbclid / utm_*', () => {
  expect(ids('https://github.com/example/project?fbclid=IwZXh0bgNhZW0')).toEqual(['url:https://github.com/example/project']);
  expect(ids('https://book.example.com/?utm_source=fb&x=1')).toEqual(['url:https://book.example.com/?x=1']);
});
