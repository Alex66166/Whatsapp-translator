import test from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { enforceStorageQuota, storageUsage } from '../lib/storage-fifo.mjs';

test('FIFO removes oldest message and its picture while preserving newer media and contacts', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'wt-fifo-'));
  try {
    const media = path.join(dir,'media');
    mkdirSync(media);
    const db = new Database(path.join(dir,'messages.sqlite'));
    db.exec("CREATE TABLE chats(jid TEXT PRIMARY KEY,title TEXT);" +
      "CREATE TABLE messages(id TEXT PRIMARY KEY,created_at INTEGER,state TEXT,media_state TEXT,media_bytes INTEGER);");
    db.prepare('INSERT INTO chats VALUES (?,?)').run('person@s.whatsapp.net','Saved contact');
    const insert = db.prepare('INSERT INTO messages VALUES (?,?,?,?,?)');
    const filename = id => path.join(media,createHash('sha256').update(id).digest('hex')+'.image');
    for (const [id,time] of [['old',10],['new',20]]) {
      insert.run(id,time,'ready','ready',650000);
      writeFileSync(filename(id),Buffer.alloc(650000));
    }
    const result=enforceStorageQuota(db,media,1200000);
    assert.equal(result.removed,1);
    assert.equal(existsSync(filename('old')),false);
    assert.equal(existsSync(filename('new')),true);
    assert.equal(db.prepare('SELECT COUNT(*) n FROM messages').get().n,1);
    assert.equal(db.prepare('SELECT COUNT(*) n FROM chats').get().n,1);
    assert.ok(storageUsage(db,media).bytes<=1200000);
    db.close();
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
test('FIFO preserves active outgoing and currently downloaded photo when quota is exceeded',()=>{
  const dir=mkdtempSync(path.join(tmpdir(),'wt-fifo-'));
  try{
    const media=path.join(dir,'media');mkdirSync(media);
    const db=new Database(path.join(dir,'messages.sqlite'));
    db.exec('CREATE TABLE messages(id TEXT PRIMARY KEY,created_at INTEGER,state TEXT,media_state TEXT,media_bytes INTEGER)');
    const insert=db.prepare('INSERT INTO messages VALUES (?,?,?,?,?)');
    insert.run('sending',1,'sending',null,null);
    insert.run('current',2,'ready','ready',1300000);
    const current=path.join(media,createHash('sha256').update('current').digest('hex')+'.image');
    writeFileSync(current,Buffer.alloc(1300000));
    const result=enforceStorageQuota(db,media,1200000,{protectedIds:['current']});
    assert.equal(result.overLimit,true);
    assert.equal(db.prepare('SELECT COUNT(*) n FROM messages').get().n,2);
    assert.equal(existsSync(current),true);
    db.close();
  }finally{rmSync(dir,{recursive:true,force:true});}
});
