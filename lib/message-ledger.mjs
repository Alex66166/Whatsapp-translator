// Persistent message lifecycle helpers, separated so they can be tested
// without opening a WhatsApp session or connecting to the network.
export function migrateMessages(db) {
  const columns = new Set(db.prepare('PRAGMA table_info(messages)').all().map(c => c.name));
  if (!columns.has('media_mime')) db.exec('ALTER TABLE messages ADD COLUMN media_mime TEXT');
  if (!columns.has('media_state')) db.exec('ALTER TABLE messages ADD COLUMN media_state TEXT');
  if (!columns.has('media_bytes')) db.exec('ALTER TABLE messages ADD COLUMN media_bytes INTEGER');
  if (!columns.has('source_language')) db.exec('ALTER TABLE messages ADD COLUMN source_language TEXT');
  if (!columns.has('wa_id')) db.exec('ALTER TABLE messages ADD COLUMN wa_id TEXT');
  db.exec('CREATE UNIQUE INDEX IF NOT EXISTS message_wa_id_unique ON messages(jid,wa_id) WHERE wa_id IS NOT NULL');

  // Incoming translations survive a reboot and will be retried once the
  // worker starts. Outgoing sends may have succeeded before a crash; do not
  // automatically resubmit them.
  db.prepare("UPDATE messages SET state='uncertain' WHERE direction='out' AND state IN ('translating','sending')").run();
  // Raw WhatsApp image payloads are not kept in RAM across restarts.
  db.prepare("UPDATE messages SET media_state='error' WHERE media_state='loading'").run();
}
export function bindWhatsAppAck(db, localId, jid, remoteId) {
  if (typeof remoteId !== 'string' || !remoteId || remoteId.length > 200)
    throw new Error('Invalid WhatsApp message identifier');
  return db.transaction(() => {
    const local = db.prepare("SELECT id FROM messages WHERE id=? AND jid=? AND direction='out'").get(localId, jid);
    if (!local) throw new Error('Local outgoing entry missing');
    const mirror = db.prepare('SELECT id FROM messages WHERE jid=? AND wa_id=?').get(jid, remoteId);
    if (mirror && mirror.id !== localId) {
      db.prepare('DELETE FROM messages WHERE id=?').run(mirror.id);
    }
    db.prepare('UPDATE messages SET wa_id=? WHERE id=?').run(remoteId, localId);
  })();
}
