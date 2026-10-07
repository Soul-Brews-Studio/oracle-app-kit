import { test, expect } from 'bun:test';
import { compare, tidy, type Snap } from './versions.ts';
const S = (text: string, comments: Record<string, string> = {}, media: string[] = [], links: string[] = []): Snap => ({ text, comments, media, links });
test('first capture is new', () => expect(compare(null, S('hi')).status).toBe('new'));
test('identical is same', () => expect(compare(S('hello world', { 'comment:1': 'a' }), S('hello world', { 'comment:1': 'a' })).status).toBe('same'));
test('a cut caption ("… See more") is the same post', () => {
  expect(compare(S('long caption that goes on'), S(tidy('long caption … See more'))).status).toBe('same');
});
test('fewer comments on screen than we hold is same', () => expect(compare(S('t', { 'comment:1': 'a', 'comment:2': 'b' }), S('t', { 'comment:1': 'a' })).status).toBe('same'));
test('the full caption after See more is an update', () => {
  const r = compare(S('long caption'), S('long caption that goes on'));
  expect(r.status).toBe('updated'); expect(r.changes).toEqual(['text +13 chars']); expect(r.merged.text).toBe('long caption that goes on');
});
test('a new comment, an edited one, new media', () => {
  const r = compare(S('t', { 'comment:1': 'old words' }, ['photo:1']), S('t', { 'comment:1': 'new words', 'comment:2': 'hi' }, ['photo:1', 'photo:2']));
  expect(r.status).toBe('updated'); expect(r.changes).toEqual(['+1 comment', '1 comment edited', '+1 media']);
  expect(Object.keys(r.merged.comments)).toEqual(['comment:1', 'comment:2']); expect(r.merged.media).toEqual(['photo:1', 'photo:2']);
});
test('edited post text', () => expect(compare(S('first version'), S('second version')).changes).toEqual(['text edited']));
