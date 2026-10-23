import test from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { resetContactCache, hideContact } from '../lib/contact-cache.mjs';
import { recentChats } from '../lib/recent-chats.mjs';

function setup() {
  const db=new Database(':memory:');
  db.exec(`
    CREATE TABLE chats(
      jid TEXT PRIMARY KEY, title TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
      target_language TEXT NOT NULL, last_activity INTEGER NOT NULL DEFAULT 0,
      name_rank INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE messages(
      id TEXT PRIMARY KEY, jid TEXT REFERENCES chats(jid),
      original TEXT NOT NULL, state TEXT NOT NULL
    );
    CREATE TABLE phonebook(phone TEXT PRIMARY KEY,name TEXT NOT NULL);
  `);
  db.pragma('foreign_keys = ON');
  return db;
}

test('contact reset hides all previous chats but retains messages and turns translation on',()=>{
  const db=setup();
  db.prepare('INSERT INTO chats VALUES(?,?,?,?,?,?)').run('123@lid','Some saved private name',0,'English',1700000000000,3);
  db.prepare('INSERT INTO chats VALUES(?,?,?,?,?,?)').run('456@s.whatsapp.net','Another Name',0,'German',1700000003000,2);
  db.prepare('INSERT INTO messages VALUES(?,?,?,?)').run('msg-1','123@lid','Привет','received-original');
  db.prepare('INSERT INTO phonebook VALUES(?,?)').run('123','My Contacts Name');
  assert.equal(recentChats(db).length,2);
  const out=resetContactCache(db);
  assert.deepEqual(out,{book:1,anonymized:2,removed:1});
  assert.equal(recentChats(db).length,0);
  const row=db.prepare('SELECT * FROM chats WHERE jid=?').get('123@lid');
  assert.equal(row.title,'123');
  assert.equal(row.enabled,1);
  assert.equal(row.name_rank,0);
  assert.equal(row.last_activity,0);
  assert.equal(row.target_language,'English');
  assert.equal(db.prepare('SELECT original FROM messages WHERE id=?').get('msg-1').original,'Привет');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM phonebook').get().n,0);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM chats').get().n,1);
  assert.deepEqual(db.pragma('foreign_key_check'),[]);
  db.close();
});

test('newly discovered chats are translation enabled by default; manual OFF remains possible',()=>{
  const db=setup();
  // Mirrors the INSERT ... ON CONFLICT expression used by server.mjs.
  const add=db.prepare('INSERT INTO chats(jid,title,enabled,target_language,last_activity) VALUES(?,?,1,?,?) ON CONFLICT(jid) DO UPDATE SET last_activity=MAX(chats.last_activity,excluded.last_activity)');
  add.run('1@s.whatsapp.net','New','Montenegrin',1700000000000);
  assert.equal(db.prepare('SELECT enabled FROM chats').get().enabled,1);
  db.prepare('UPDATE chats SET enabled=0 WHERE jid=?').run('1@s.whatsapp.net');
  add.run('1@s.whatsapp.net','New','Montenegrin',1700000001000);
  assert.equal(db.prepare('SELECT enabled FROM chats').get().enabled,0);
  const server=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  assert.match(server,/enabled INTEGER NOT NULL DEFAULT 1/);
  assert.match(server,/INSERT INTO chats\(jid,title,enabled,target_language,last_activity\) VALUES\(\?,\?,1,\?,\?\)/);
  db.close();
});

test('hide one chat from UI without deleting its messages or changing language',()=>{
  const db=setup();
  db.prepare('INSERT INTO chats VALUES(?,?,?,?,?,?)').run('123@lid','Personal name',1,'German',1700000000000,2);
  db.prepare('INSERT INTO messages VALUES(?,?,?,?)').run('msg-1','123@lid','Message body','ready');
  assert.equal(hideContact(db,'123@lid'),true);
  assert.equal(recentChats(db).length,0);
  const row=db.prepare('SELECT * FROM chats WHERE jid=?').get('123@lid');
  assert.equal(row.title,'123');
  assert.equal(row.target_language,'German');
  assert.equal(row.enabled,1);
  assert.equal(db.prepare('SELECT original FROM messages WHERE id=?').get('msg-1').original,'Message body');
  assert.throws(()=>hideContact(db,'group@g.us'),/Invalid/);
  db.close();
});
