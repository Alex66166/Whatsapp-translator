import { statSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

function fileSize(filename) {
  try { return statSync(filename).size; }
  catch (error) { if (error.code === 'ENOENT') return 0; throw error; }
}
export function storageUsage(db, mediaDir) {
  const images = db.prepare("SELECT COALESCE(SUM(media_bytes),0) AS bytes FROM messages WHERE media_state='ready'").get().bytes;
  // The on-disk database and its WAL are included. SQLite SHM is ephemeral, 
  // bounded separately by the operating system; auth keys are never subject to FIFO.
  const database = fileSize(db.name) + fileSize(db.name + '-wal');
  return { bytes: database + images, images, database };
}
/**
 * Delete only the oldest *completed* messages, including their image files.
 * Never delete the WhatsApp auth state, saved chat/contact settings, in-flight
 * sends/translations, or the message/image currently being processed.
 * VACUUM makes the SQLite database release disk space after pruning.
 */
export function enforceStorageQuota(db, mediaDir, maxBytes, { protectedIds = [], extraBytes = 0 } = {}) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1024 * 1024) throw new Error('Invalid storage quota');
  if (!Number.isSafeInteger(extraBytes) || extraBytes < 0) throw new Error('Invalid pending storage size');
  const excluded = new Set(protectedIds);
  let usage = storageUsage(db, mediaDir);
  if (usage.bytes + extraBytes <= maxBytes) return { removed: 0, bytes: usage.bytes };
  const oldest = db.prepare(
    "SELECT id,media_state FROM messages WHERE state NOT IN ('translating','sending') " +
    "AND COALESCE(media_state,'')!='loading' ORDER BY created_at ASC, rowid ASC LIMIT 1 OFFSET ?"
  );
  const remove = db.prepare('DELETE FROM messages WHERE id=?');
  let removed = 0;
  const compact = () => {
    db.pragma('wal_checkpoint(TRUNCATE)');
    db.exec('VACUUM');
    db.pragma('wal_checkpoint(TRUNCATE)');
    usage = storageUsage(db, mediaDir);
  };
  while (usage.bytes + extraBytes > maxBytes) {
    let changed = 0;
    let offset = 0;
    while (changed < 25) {
      const row = oldest.get(offset);
      if (!row) break;
      if (excluded.has(row.id)) { offset++; continue; }
      const photo = path.join(mediaDir, createHash('sha256').update(row.id).digest('hex') + '.image');
      if (row.media_state === 'ready') {
        try { unlinkSync(photo); }
        catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
      remove.run(row.id);
      changed++;
      removed++;
      // A deleted media file returns space immediately. SQLite bytes can only
      // be reclaimed after VACUUM, hence a bounded batch before compaction.
      const nextUsage = storageUsage(db, mediaDir);
      if (nextUsage.bytes + extraBytes <= maxBytes) { usage = nextUsage; break; }
    }
    if (!changed) break;
    compact();
  }
  return { removed, bytes: usage.bytes, overLimit: usage.bytes + extraBytes > maxBytes };
}
