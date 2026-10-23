/**
 * Resets cached contact metadata without damaging the message ledger.
 * Rows referenced by existing messages remain as anonymous placeholders to
 * honor FOREIGN KEY(msg.jid -> chats.jid). They become invisible because
 * recentChats() only returns rows with last_activity > 0.
 */
export function resetContactCache(db) {
  const fields=new Set(db.prepare('PRAGMA table_info(chats)').all().map(col=>col.name));
  for (const name of ['jid','title','enabled','last_activity','name_rank']) {
    if (!fields.has(name)) throw new Error('Schema is missing chats.'+name+'; upgrade the application before reset');
  }
  if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='phonebook'").get()) {
    throw new Error('Schema is missing the phonebook table; upgrade the application before reset');
  }

  // secure_delete prevents deleted page content from being reused verbatim.
  db.pragma('secure_delete = ON');
  const reset=db.transaction(() => {
    const book=db.prepare('DELETE FROM phonebook').run().changes;
    // Old contact names are deleted. Keep only JIDs needed as message foreign
    // keys, and set their visibility/recency to zero.
    const anonymized=db.prepare(
      "UPDATE chats SET title=substr(jid,1,instr(jid,'@')-1)," +
      " last_activity=0, enabled=1, name_rank=0"
    ).run().changes;
    const removed=db.prepare(
      'DELETE FROM chats WHERE NOT EXISTS (SELECT 1 FROM messages WHERE messages.jid=chats.jid)'
    ).run().changes;
    return { book, anonymized, removed };
  });
  const result=reset();
  // Release SQLite free pages containing former contact names when possible.
  db.pragma('wal_checkpoint(TRUNCATE)');
  db.exec('VACUUM');
  db.pragma('wal_checkpoint(TRUNCATE)');
  return result;
}

export function hideContact(db, jid) {
  if (typeof jid !== 'string' || !/^(?:[0-9A-Za-z_.-]+)@(?:lid|s\.whatsapp\.net)$/.test(jid)) throw new Error('Invalid personal contact JID');
  const update = db.prepare("UPDATE chats SET title=substr(jid,1,instr(jid,'@')-1), last_activity=0, name_rank=0 WHERE jid=?");
  return update.run(jid).changes > 0;
}
