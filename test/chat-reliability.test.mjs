import test from 'node:test';
import assert from 'node:assert/strict';
import { incomingMessageState, outgoingMessageText } from '../lib/message-policy.mjs';
import { historicalChatRef, recentChats, chatMetadataTime } from '../lib/recent-chats.mjs';
import Database from 'better-sqlite3';

test('first live incoming message is kept when translation checkbox is OFF', () => {
  assert.equal(incomingMessageState('Привет!', false), 'received-original');
  assert.equal(incomingMessageState('Привет!', true), 'translating');
  assert.equal(incomingMessageState('', false), 'received-original');
  assert.equal(incomingMessageState('ok', true, true), 'sent-original');
});

test('ordinary send does NOT call Groq, whereas enabled chat translates', async () => {
  let calls=0;
  const translate=async (text, source, dest)=>{
    calls++;
    assert.equal(source,'Russian');
    assert.equal(dest,'Montenegrin (Latin script, Ijekavian)');
    return 'Zdravo';
  };
  const target='Montenegrin (Latin script, Ijekavian)';
  assert.equal(await outgoingMessageText('Привет',false,target,translate),'Привет');
  assert.equal(calls,0);
  assert.equal(await outgoingMessageText('Привет',true,target,translate),'Zdravo');
  assert.equal(calls,1);
});

test('history metadata indexes 20 newest contacts without touching message bodies', () => {
  const db=new Database(':memory:');
  db.exec('CREATE TABLE chats(jid TEXT PRIMARY KEY,title TEXT NOT NULL,last_activity INTEGER NOT NULL)');
  const put=db.prepare('INSERT INTO chats VALUES(?,?,?)');
  for(let i=0;i<25;i++){
    const item={
      key:{remoteJid:(i+1)+'@lid',fromMe:i%2===0},
      messageTimestamp:1700000000+i,
      pushName:'Person '+(i+1),
      message:{conversation:'OLD PRIVATE TEXT SHOULD NEVER BE INDEXED'}
    };
    const ref=historicalChatRef(item);
    assert.ok(ref);
    assert.equal(Object.prototype.hasOwnProperty.call(ref,'message'),false);
    assert.equal(Object.prototype.hasOwnProperty.call(ref,'content'),false);
    put.run(ref.jid,ref.name||'Unknown',ref.timestamp);
  }
  assert.equal(recentChats(db).length,20);
  assert.equal(recentChats(db)[0].jid,'25@lid');
  assert.equal(recentChats(db).at(-1).jid,'6@lid');
  assert.equal(historicalChatRef({key:{remoteJid:'123@g.us'},messageTimestamp:1700000000}),null);
  assert.equal(chatMetadataTime({lastMessage:{messageTimestamp:1700000001}}),1700000001000);
  db.close();
});
