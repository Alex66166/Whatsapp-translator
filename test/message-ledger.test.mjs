import test from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { migrateMessages, bindWhatsAppAck } from '../lib/message-ledger.mjs';

function schema(db) {
  db.exec('CREATE TABLE messages (id TEXT PRIMARY KEY, jid TEXT NOT NULL, direction TEXT NOT NULL, original TEXT NOT NULL, translated TEXT, state TEXT NOT NULL, created_at INTEGER NOT NULL)');
}
const put=(db,id,jid,direction,state,translated=null)=>db.prepare(
  'INSERT INTO messages (id,jid,direction,original,translated,state,created_at) VALUES (?,?,?,?,?,?,?)'
).run(id,jid,direction,'Текст',translated,state,Date.now());

test('SQLite migration is idempotent and preserves incomplete incoming translations', () => {
  const dir=mkdtempSync(path.join(tmpdir(),'wa-sqlite-test-'));
  try {
    const filename=path.join(dir,'messages.sqlite');
    let db=new Database(filename);
    schema(db);
    put(db,'i1','test@s.whatsapp.net','in','translating');
    put(db,'o1','test@s.whatsapp.net','out','sending');
    put(db,'img','test@s.whatsapp.net','in','ready');
    db.exec("ALTER TABLE messages ADD COLUMN media_state TEXT");
    db.prepare("UPDATE messages SET media_state='loading' WHERE id='img'").run();
    migrateMessages(db);
    migrateMessages(db);
    assert.equal(db.prepare("SELECT state FROM messages WHERE id='i1'").get().state,'translating');
    assert.equal(db.prepare("SELECT state FROM messages WHERE id='o1'").get().state,'uncertain');
    assert.equal(db.prepare("SELECT media_state FROM messages WHERE id='img'").get().media_state,'error');
    db.prepare("UPDATE messages SET source_language='Montenegrin' WHERE id='i1'").run();
    db.close();
    db=new Database(filename);
    migrateMessages(db);
    const row=db.prepare("SELECT state,source_language FROM messages WHERE id='i1'").get();
    assert.deepEqual(row,{state:'translating',source_language:'Montenegrin'});
    db.close();
  } finally { rmSync(dir,{recursive:true,force:true}); }
});

test('WhatsApp acknowledgement reconciles early mirror without deleting local original', () => {
  const db=new Database(':memory:');
  schema(db);
  migrateMessages(db);
  const jid='123@s.whatsapp.net';
  put(db,'local:one',jid,'out','uncertain','Dobar dan');
  put(db,jid+'|remote1',jid,'out','sent-original','Dobar dan');
  db.prepare('UPDATE messages SET wa_id=? WHERE id=?').run('remote1',jid+'|remote1');
  bindWhatsAppAck(db,'local:one',jid,'remote1');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM messages').get().n,1);
  const kept=db.prepare('SELECT id,wa_id FROM messages').get();
  assert.equal(kept.id,'local:one');
  assert.equal(kept.wa_id,'remote1');
  assert.throws(()=>bindWhatsAppAck(db,'missing',jid,'remote2'),/missing/);
  db.close();
});

test('WhatsApp acknowledgements are unique per chat, not across accounts', () => {
  const db=new Database(':memory:');schema(db);migrateMessages(db);
  const a='a@s.whatsapp.net',b='b@s.whatsapp.net';
  put(db,'local:A',a,'out','sending');
  put(db,'local:B',b,'out','sending');
  bindWhatsAppAck(db,'local:A',a,'remote1');
  bindWhatsAppAck(db,'local:B',b,'remote1');
  assert.equal(db.prepare('SELECT COUNT(*) n FROM messages').get().n,2);
  assert.throws(()=>bindWhatsAppAck(db,'local:A',a,''),/Invalid/);
  db.close();
});
