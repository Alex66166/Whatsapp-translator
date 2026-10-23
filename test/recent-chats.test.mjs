import test from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import { chatMetadataTime, recentChats, RECENT_CHAT_LIMIT } from '../lib/recent-chats.mjs';

test('returns only 20 newest personal chats by WhatsApp activity (not address book)', () => {
  const db = new Database(':memory:');
  db.exec('CREATE TABLE chats (jid TEXT PRIMARY KEY, title TEXT, last_activity INTEGER NOT NULL)');
  const insert = db.prepare('INSERT INTO chats VALUES (?, ?, ?)');
  for (let i=1;i<=30;i++) {
    insert.run(i + '@s.whatsapp.net', 'Contact ' + i, i * 1000);
  }
  insert.run('never-opened@s.whatsapp.net', 'Phonebook only', 0);
  insert.run('group@g.us', 'Group', 999999);
  // The production schema receives only valid personal JIDs. In this test,
  // the helper intentionally enforces personal chats even for stray rows.
  const picked=recentChats(db);
  assert.equal(picked.length,RECENT_CHAT_LIMIT);
  assert.equal(picked[0].jid,'30@s.whatsapp.net');
  assert.equal(picked.at(-1).jid,'11@s.whatsapp.net');
  assert.ok(!picked.some(c=>c.jid.includes('never-opened')));
  assert.ok(!picked.some(c=>c.jid.endsWith('@g.us')));
  db.close();
});

test('WhatsApp timestamp metadata is converted to milliseconds and never uses arrival time',()=>{
  assert.equal(chatMetadataTime({conversationTimestamp:1760000000}),1760000000000);
  assert.equal(chatMetadataTime({conversationTimestamp:{low:1760000000}}),1760000000000);
  assert.equal(chatMetadataTime({conversationTimestamp:'1760000000'}),1760000000000);
  assert.equal(chatMetadataTime({conversationTimestamp:0}),0);
  assert.equal(chatMetadataTime({}),0);
});
