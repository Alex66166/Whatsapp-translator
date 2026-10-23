import 'dotenv/config';
import express from 'express';
import Database from 'better-sqlite3';
import makeWASocket, { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, downloadMediaMessage, Browsers } from '@whiskeysockets/baileys';
import pino from 'pino';
import QRCode from 'qrcode';
import { randomBytes, createHmac, scryptSync, timingSafeEqual, randomUUID, createHash } from 'node:crypto';
import { mkdirSync, createWriteStream, existsSync, unlinkSync, createReadStream } from 'node:fs';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { translate } from './lib/translate.mjs';
import { migrateMessages, bindWhatsAppAck } from './lib/message-ledger.mjs';
import { retireLinkedAuth } from './lib/auth-session.mjs';
import { enforceStorageQuota, storageUsage } from './lib/storage-fifo.mjs';
import { parseVcard } from './lib/vcard.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DATA = path.resolve(HERE, process.env.DATA_DIR || '.data');
const DEFAULT_LANGUAGE = process.env.DEFAULT_TARGET_LANGUAGE || 'Montenegrin (Latin script, Ijekavian)';
mkdirSync(DATA, { recursive: true, mode: 0o700 });
const MEDIA_DIR = path.join(DATA, 'media');
mkdirSync(MEDIA_DIR, { recursive: true, mode: 0o700 });
const MEDIA_MAX_BYTES = Math.min(32, Math.max(1, Number(process.env.MEDIA_MAX_MB || 8))) * 1048576;
// Historical MEDIA_TOTAL_MB configurations remain supported after upgrading.
const STORAGE_TOTAL_BYTES = Math.max(16, Number(process.env.STORAGE_TOTAL_MB || process.env.MEDIA_TOTAL_MB || 512)) * 1048576;
function pruneHistory(protectedIds = [], extraBytes = 0) {
  try {
    const status = enforceStorageQuota(db, MEDIA_DIR, STORAGE_TOTAL_BYTES,
      { protectedIds, extraBytes });
    if (status.removed) emit();
    return status;
  } catch (error) {
    log.error({ error: error.message }, 'Storage FIFO cleanup failed');
    return { overLimit: true, removed: 0 };
  }
}
const db = new Database(path.join(DATA, 'messages.sqlite'));
db.pragma('journal_mode = WAL');
db.pragma('busy_timeout = 5000');
db.exec([
  'CREATE TABLE IF NOT EXISTS chats (jid TEXT PRIMARY KEY, title TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, target_language TEXT NOT NULL, last_activity INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, jid TEXT NOT NULL, direction TEXT NOT NULL, original TEXT NOT NULL, translated TEXT, state TEXT NOT NULL, created_at INTEGER NOT NULL, FOREIGN KEY(jid) REFERENCES chats(jid))',
  'CREATE INDEX IF NOT EXISTS messages_jid_time ON messages(jid, created_at DESC)',
  'CREATE TABLE IF NOT EXISTS phonebook (phone TEXT PRIMARY KEY, name TEXT NOT NULL)'
].join(';') + ';');
migrateMessages(db);

const stmt = {
  chat: db.prepare('SELECT * FROM chats WHERE jid = ?'),
  chats: db.prepare('SELECT * FROM chats ORDER BY last_activity DESC, title COLLATE NOCASE'),
  imported: db.prepare('SELECT phone,name FROM phonebook ORDER BY name COLLATE NOCASE'),
  importContact: db.prepare('INSERT INTO phonebook(phone,name) VALUES(?,?) ON CONFLICT(phone) DO UPDATE SET name=excluded.name'),
  addChat: db.prepare('INSERT INTO chats(jid,title,target_language,last_activity) VALUES(?,?,?,?) ON CONFLICT(jid) DO UPDATE SET last_activity=MAX(chats.last_activity,excluded.last_activity)'),
  title: db.prepare('UPDATE chats SET title=? WHERE jid=?'),
  setting: db.prepare('UPDATE chats SET enabled=?, target_language=? WHERE jid=?'),
  messages: db.prepare('SELECT * FROM (SELECT * FROM messages WHERE jid=? ORDER BY created_at DESC LIMIT 150) ORDER BY created_at ASC'),
  addMsg: db.prepare('INSERT OR IGNORE INTO messages(id,jid,direction,original,translated,state,created_at) VALUES(?,?,?,?,?,?,?)'),
  updateMsg: db.prepare('UPDATE messages SET translated=?,state=? WHERE id=?'),
  stateMsg: db.prepare('UPDATE messages SET state=? WHERE id=?'),
  msg: db.prepare('SELECT * FROM messages WHERE id=?'),
  mediaState: db.prepare('UPDATE messages SET media_state=?,media_mime=?,media_bytes=? WHERE id=?'),
  mediaUsage: db.prepare("SELECT COALESCE(SUM(media_bytes),0) AS bytes FROM messages WHERE media_state='ready'"),
  pendingIncoming: db.prepare("SELECT id, original, source_language FROM messages WHERE direction='in' AND state='translating' ORDER BY created_at ASC LIMIT 1"),
  pendingCount: db.prepare("SELECT COUNT(*) AS n FROM messages WHERE direction='in' AND state='translating'"),
  setSource: db.prepare('UPDATE messages SET source_language=? WHERE id=?'),
  duplicateWa: db.prepare('SELECT id FROM messages WHERE jid=? AND wa_id=?'),
  claimWa: db.prepare('UPDATE messages SET wa_id=? WHERE id=?'),
  deleteDuplicate: db.prepare('DELETE FROM messages WHERE id=?'),
  sendingMatch: db.prepare("SELECT id FROM messages WHERE jid=? AND direction='out' AND translated=? AND wa_id IS NULL AND state IN ('sending','uncertain') AND created_at>? ORDER BY created_at DESC LIMIT 1")
};
let wa = null;
let connection = 'starting';
let qrImage = null;
let generation = 0;
let reconnectTimer = null;
const people = new Map();
const clients = new Set();
let running = false;
const log = pino({ level: process.env.LOG_LEVEL || 'warn' });

function emit() {
  for (const response of clients) {
    try { response.write('data: changed\n\n'); } catch { clients.delete(response); }
  }
}
function validChat(jid) {
  return typeof jid === 'string' && jid.length <= 160 &&
    (jid.endsWith('@s.whatsapp.net') || jid.endsWith('@lid'));
}
function shortJid(jid) { return jid.split('@')[0] || jid; }
function touch(jid, name, timestamp = 0) {
  if (!validChat(jid)) return;
  const label = typeof name === 'string' && name.trim() ? name.trim() : people.get(jid) || shortJid(jid);
  const existing = stmt.chat.get(jid);
  stmt.addChat.run(jid, label, DEFAULT_LANGUAGE, timestamp);
  // Contact names outrank raw IDs, but a remote pushName must not erase a saved address-book name.
  if (!existing || (label !== shortJid(jid) && (existing.title === shortJid(jid) || name))) {
    stmt.title.run(label, jid);
  }
}
function updateContact(contact) {
  if (!contact) return;
  const name = [contact.name, contact.verifiedName, contact.notify]
    .find(n => typeof n === 'string' && n.trim())?.trim();
  // Phone-number and private LID aliases are different JIDs for the same user.
  // Store names for every alias sent by Baileys, without inventing LID mappings.
  const ids = [contact.id, contact.lid, contact.phoneNumber]
    .filter((jid, index, list) => validChat(jid) && list.indexOf(jid) === index);
  for (const jid of ids) {
    if (name) people.set(jid, name);
    // Insert contacts as selectable conversations, even when no incoming message has arrived.
    if (name || stmt.chat.get(jid)) touch(jid, name, 0);
  }
}
function bodyOf(message) {
  // Не сохраняем медиа одноразового просмотра (view-once).
  if (message?.message?.viewOnceMessage || message?.message?.viewOnceMessageV2) return null;
  let m = message?.message;
  for (let i = 0; i < 4 && m; i++) {
    if (m.ephemeralMessage) { m = m.ephemeralMessage.message; continue; }
    if (m.viewOnceMessage || m.viewOnceMessageV2 || m.imageMessage?.viewOnce) return null;
    if (m.documentWithCaptionMessage) { m = m.documentWithCaptionMessage.message; continue; }
    break;
  }
  return m;
}
function textOf(message) {
  const m = bodyOf(message);
  return m?.conversation || m?.extendedTextMessage?.text ||
    m?.imageMessage?.caption || m?.videoMessage?.caption || '';
}
const allowedMimes = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/gif']);
const pictureQueue = [];
let pictureRunning = false;
function queueImage(id, rawMessage, image) {
  if (pictureQueue.length >= 40) {
    stmt.mediaState.run('error', null, null, id);
    emit();
    return;
  }
  pictureQueue.push({ id, rawMessage, image });
  void drainPictures();
}
async function drainPictures() {
  if (pictureRunning) return;
  pictureRunning = true;
  try {
    while (pictureQueue.length) {
      const { id, rawMessage, image } = pictureQueue.shift();
      try {
        const mime = image.mimetype || 'image/jpeg';
        const reported = Number(image.fileLength?.low ?? image.fileLength ?? 0);
        if (!allowedMimes.has(mime)) throw new Error('Unsupported image MIME');
        if (reported && reported > MEDIA_MAX_BYTES) throw new Error('Image exceeds size limit');
        if (!wa) throw new Error('WhatsApp is disconnected');
        const maxBytes = MEDIA_MAX_BYTES;
        const file = path.join(MEDIA_DIR, createHash('sha256').update(id).digest('hex') + '.image');
        let downloaded = 0;
        try {
          // Streamed transfer: no complete photo Buffer in 2-GB VPS memory.
          const stream = await downloadMediaMessage(rawMessage, 'stream', {}, {
            logger: log,
            reuploadRequest: wa.updateMediaMessage?.bind(wa)
          });
          const limiter = new Transform({
            transform(chunk, encoding, callback) {
              downloaded += chunk.length;
              if (downloaded > maxBytes) callback(new Error('Image size or disk quota exceeded'));
              else callback(null, chunk);
            }
          });
          await pipeline(stream, limiter, createWriteStream(file, { flags: 'wx', mode: 0o600 }));
          if (!downloaded) throw new Error('Empty image');
          stmt.mediaState.run('ready', mime, downloaded, id);
          // Images and SQLite text share the same FIFO quota; current image stays
          // protected and older completed entries are evicted first.
          const quota = pruneHistory([id]);
          if (quota.overLimit) {
            unlinkSync(file);
            stmt.mediaState.run('error', null, null, id);
            log.warn('Current image cannot fit the allocated history quota');
          }
        } catch (error) {
          if (existsSync(file)) unlinkSync(file);
          throw error;
        }
      } catch (error) {
        log.warn({ error: error.message }, 'Image unavailable');
        stmt.mediaState.run('error', null, null, id);
      }
      emit();
    }
  } finally { pictureRunning = false; }
}

async function runQueue() {
  if (running) return;
  running = true;
  try {
    // SQLite is the durable translation queue. After restart, unsent incoming
    // translations resume; outbound messages are NEVER auto-resubmitted.
    for (;;) {
      const job = stmt.pendingIncoming.get();
      if (!job) break;
      try {
        const language = job.source_language || DEFAULT_LANGUAGE;
        const translated = await translate(job.original, language, 'Russian');
        stmt.updateMsg.run(translated, 'ready', job.id);
        pruneHistory([job.id]);
      } catch (error) {
        log.warn({ error: error.message }, 'Translation failed');
        stmt.updateMsg.run(null, 'error', job.id);
      }
      emit();
    }
  } finally {
    running = false;
  }
}
function queueIncoming(id, text, target) {
  stmt.setSource.run(target, id);
  if (stmt.pendingCount.get().n > 200) {
    stmt.stateMsg.run('error', id);
    return;
  }
  void runQueue();
}
// Attach the acknowledged WhatsApp message ID to the local optimistic entry.
// A mirror event may arrive before or after sendMessage() resolves.
function bindOutgoingWaId(localId, jid, remoteId) {
  bindWhatsAppAck(db, localId, jid, remoteId);
}

function ingest(message) {
  const jid = message?.key?.remoteJid;
  if (!validChat(jid) || !message?.key?.id || message?.key?.participant) return;
  const text = textOf(message);
  const image = bodyOf(message)?.imageMessage;
  if ((!text || !text.trim()) && !image) return;
  const timestamp = Number(message.messageTimestamp?.low ?? message.messageTimestamp ?? 0);
  const timeMs = Number.isFinite(timestamp) && timestamp > 0 ? timestamp * 1000 : Date.now();
  const pushName = message.pushName || '';
  if (pushName && !message.key.fromMe) people.set(jid, pushName);
  touch(jid, pushName && !message.key.fromMe ? pushName : '', timeMs);
  const chat = stmt.chat.get(jid);
  if (!chat?.enabled) { emit(); return; }
  const id = jid + '|' + message.key.id;
  const self = !!message.key.fromMe;
  if (self) {
    const already = stmt.duplicateWa.get(jid, message.key.id);
    if (already) return;
    // Do not create a duplicate for a message from this web client while
    // WhatsApp is still acknowledging the send; bindOutgoingWaId will
    // reconcile a mirrored event if it arrives first.
    const pending = stmt.sendingMatch.get(jid, text || '', Date.now() - 90000);
    if (pending) {
      try { bindOutgoingWaId(pending.id, jid, message.key.id); } catch (err) {
        log.warn({ error: err.message }, 'Outgoing mirror reconciliation failed');
      }
      emit();
      return;
    }
  }
  const result = stmt.addMsg.run(id, jid, self ? 'out' : 'in', text || '',
    self ? text || '' : null, self ? 'sent-original' : text ? 'translating' : 'ready', timeMs);
  if (!result.changes) return;
  pruneHistory([id]);
  if (image) {
    stmt.mediaState.run('loading', null, null, id);
    queueImage(id, message, image);
  }
  emit();
  if (self) stmt.claimWa.run(message.key.id, id);
  if (!self && text?.trim()) queueIncoming(id, text, chat.target_language);
}
function scheduleReconnect() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => { reconnectTimer = null; void connectWhatsApp(); }, 7000);
}
async function connectWhatsApp() {
  if (wa) return;
  const myGeneration = ++generation;
  connection = 'connecting';
  qrImage = null;
  emit();
  try {
    const { state, saveCreds } = await useMultiFileAuthState(path.join(DATA, 'auth'));
    const { version } = await fetchLatestBaileysVersion();
    if (myGeneration !== generation) return;
    const sock = makeWASocket({
      version,
      auth: state,
      logger: log,
      printQRInTerminal: false,
      syncFullHistory: false,
      markOnlineOnConnect: false,
      // Ask WhatsApp for the most complete linked-device chat/contact history.
      // Baileys may still receive fewer contacts than the Android phonebook.
      browser: Browsers.macOS('Desktop'),
      syncFullHistory: process.env.WHATSAPP_FULL_SYNC !== '0'
    });
    wa = sock;
    sock.ev.on('creds.update', saveCreds);
    sock.ev.on('contacts.upsert', items => { for (const item of items) updateContact(item); emit(); });
    sock.ev.on('contacts.update', items => { for (const item of items) updateContact(item); emit(); });
    sock.ev.on('chats.upsert', items => {
      for (const item of items) touch(item.id, item.name || '', 0);
      emit();
    });
    sock.ev.on('chats.update', items => {
      for (const item of items) touch(item.id, item.name || '', 0);
      emit();
    });
    sock.ev.on('messaging-history.set', data => {
      for (const person of data.contacts || []) updateContact(person);
      for (const chat of data.chats || []) touch(chat.id, chat.name || '', 0);
      // Only index the sender/chat metadata of prior messages. Do NOT import or
      // translate old message bodies or download historical media.
      for (const msg of data.messages || []) {
        const jid = msg?.key?.remoteJid;
        if (validChat(jid) && !msg?.key?.participant) {
          const name = !msg.key.fromMe ? msg.pushName || '' : '';
          touch(jid, name, 0);
        }
      }
      log.info({ contacts: (data.contacts || []).length, chats: (data.chats || []).length,
        messages: (data.messages || []).length }, 'WhatsApp history metadata received');
      emit();
    });
    sock.ev.on('messages.upsert', data => {
      for (const m of data.messages || []) {
        try {
          if (data.type === 'notify') ingest(m);
          else {
            // Append is used for backfilled WhatsApp events; discover the
            // conversation without importing/retranslating historical bodies.
            const jid = m?.key?.remoteJid;
            if (validChat(jid) && !m.key.participant)
              touch(jid, !m.key.fromMe ? m.pushName || '' : '', 0);
          }
        } catch (error) { log.error({ error: error.message }, 'message ingest failed'); }
      }
      emit();
    });
    sock.ev.on('connection.update', async update => {
      if (myGeneration !== generation) return;
      if (update.qr) {
        try { qrImage = await QRCode.toDataURL(update.qr, { margin: 1, width: 320 }); }
        catch { qrImage = null; }
        connection = 'scan_qr';
        emit();
      }
      if (update.connection === 'open') {
        connection = 'connected';
        qrImage = null;
        emit();
      }
      if (update.connection === 'close') {
        const code = update.lastDisconnect?.error?.output?.statusCode;
        wa = null;
        qrImage = null;
        connection = code === DisconnectReason.loggedOut ? 'logged_out' : 'disconnected';
        emit();
        if (code !== DisconnectReason.loggedOut) scheduleReconnect();
      }
    });
  } catch (error) {
    wa = null;
    connection = 'error';
    log.error({ error: error.message }, 'WhatsApp connection failed');
    scheduleReconnect();
  }
}

const app = express();
app.disable('x-powered-by');
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
  next();
});
app.use(express.json({ limit: '24kb' }));
function cookieValue(req) {
  return (req.headers.cookie || '').split(';').map(x => x.trim()).find(x => x.startsWith('wt_session='))?.slice(11) || '';
}
const secret = process.env.SESSION_SECRET || randomBytes(32).toString('hex');
function sign(payload) { return createHmac('sha256', secret).update(payload).digest('hex'); }
function validSession(req) {
  const token = cookieValue(req);
  const [payload, mac] = token.split('.');
  if (!payload || !mac || mac.length !== 64) return false;
  const expected = sign(payload);
  if (!timingSafeEqual(Buffer.from(mac), Buffer.from(expected))) return false;
  const expires = Number(Buffer.from(payload, 'base64url').toString('utf8'));
  return Number.isFinite(expires) && expires > Date.now();
}
function secureCookie() {
  return '; HttpOnly; SameSite=Strict; Path=/' + (process.env.COOKIE_SECURE === '0' ? '' : '; Secure');
}
function requireAuth(req, res, next) {
  if (!validSession(req)) return res.status(401).json({ error: 'Sign in required' });
  next();
}
app.use('/api', (req, res, next) => {
  if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
    const origin = req.get('origin');
    const host = req.get('host');
    const expectedScheme = process.env.COOKIE_SECURE === '0' ? 'http' : 'https';
    if (origin && origin !== expectedScheme + '://' + host) return res.status(403).json({ error: 'Bad origin' });
    if (req.get('sec-fetch-site') === 'cross-site') return res.status(403).json({ error: 'Cross-site request blocked' });
  }
  next();
});
function checkHash(password) {
  const [salt, stored] = (process.env.ADMIN_PASSWORD_HASH || '').split(':');
  if (!salt || !stored || !/^[a-f0-9]{32}$/.test(salt) || !/^[a-f0-9]{128}$/.test(stored)) return false;
  const actual = scryptSync(password, Buffer.from(salt, 'hex'), 64);
  return timingSafeEqual(actual, Buffer.from(stored, 'hex'));
}
const attempts = new Map();
app.post('/api/login', (req, res) => {
  const ip = req.socket.remoteAddress || 'unknown';
  const now = Date.now();
  let attempt = attempts.get(ip);
  if (!attempt || now - attempt.start > 15 * 60000) attempt = { start: now, count: 0 };
  attempt.count++;
  attempts.set(ip, attempt);
  if (attempt.count > 10) return res.status(429).json({ error: 'Too many attempts; retry later' });
  const password = req.body?.password;
  if (typeof password !== 'string' || password.length > 256 || !checkHash(password)) {
    return res.status(401).json({ error: 'Incorrect password' });
  }
  attempts.delete(ip);
  const payload = Buffer.from(String(now + 7 * 86400000)).toString('base64url');
  res.setHeader('Set-Cookie', 'wt_session=' + payload + '.' + sign(payload) + secureCookie());
  res.json({ ok: true });
});
app.post('/api/logout', requireAuth, (req, res) => {
  res.setHeader('Set-Cookie', 'wt_session=; Max-Age=0' + secureCookie());
  res.json({ ok: true });
});
app.get('/api/status', requireAuth, (req, res) => {
  const used = storageUsage(db, MEDIA_DIR).bytes;
  res.json({ connection, qr: qrImage, groqConfigured: !!process.env.GROQ_API_KEY,
    storageUsedBytes: used, storageMaxBytes: STORAGE_TOTAL_BYTES });
});
app.post('/api/relink', requireAuth, (req, res) => {
  if (connection !== 'logged_out') return res.status(409).json({ error: 'Re-linking is only available after WhatsApp logged out' });
  if (req.body?.confirm !== 'RELINK' || !checkHash(req.body?.password || ''))
    return res.status(403).json({ error: 'Password and RELINK confirmation required' });
  try {
    const retiredPath = retireLinkedAuth(DATA);
    if (retiredPath) log.warn('Former WhatsApp credentials retained in restricted session-backup folder');
    ++generation;
    wa = null;
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    connection = 'disconnected';
    emit();
    void connectWhatsApp();
    return res.json({ ok: true });
  } catch (error) {
    log.error({ error: error.message }, 'Re-link failed');
    return res.status(500).json({ error: 'Unable to reset session, original credentials retained' });
  }
});
app.post('/api/connect', requireAuth, (req, res) => {
  if (connection === 'error' || connection === 'disconnected') {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    void connectWhatsApp();
  }
  res.json({ ok: true });
});
app.get('/api/chats', requireAuth, (req, res) => {
  const chats = stmt.chats.all().map(c => ({
    jid: c.jid, title: c.title, enabled: !!c.enabled,
    targetLanguage: c.target_language, lastActivity: c.last_activity
  }));
  const ids = new Set(chats.map(c => c.jid));
  for (const person of stmt.imported.all()) {
    const jid = person.phone + '@s.whatsapp.net';
    if (!ids.has(jid)) {
      chats.push({ jid, title: person.name, enabled: false,
        targetLanguage: DEFAULT_LANGUAGE, lastActivity: 0, imported: true });
    }
  }
  res.json(chats);
});
app.post('/api/contacts/import', requireAuth,
  express.text({ type: ['text/vcard', 'text/x-vcard'], limit: '2mb' }),
  (req, res) => {
    try {
      const contacts = parseVcard(req.body);
      if (!contacts.length) return res.status(422).json({ error: 'VCF не содержит телефонных номеров в международном формате' });
      db.transaction(() => {
        for (const { phone, name } of contacts) {
          stmt.importContact.run(phone, name);
          const jid = phone + '@s.whatsapp.net';
          people.set(jid, name);
          if (stmt.chat.get(jid)) stmt.title.run(name, jid);
        }
      })();
      emit();
      return res.json({ added: contacts.length });
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }
  }
);
app.post('/api/chats/by-phone', requireAuth, async (req, res) => {
  // A fallback when WhatsApp does not synchronize its contact list. The phone
  // number is supplied by the user, not hardcoded into application sources.
  const number = String(req.body?.phone ?? '').replace(/[+\s()\-]/g, '');
  if (!/^[1-9][0-9]{6,14}$/.test(number)) {
    return res.status(400).json({ error: 'Введите номер с кодом страны (7–15 цифр)' });
  }
  if (!wa || connection !== 'connected') {
    return res.status(503).json({ error: 'WhatsApp не подключён' });
  }
  try {
    const lookup = await wa.onWhatsApp(number);
    const found = lookup?.find(contact => contact.exists && validChat(contact.jid));
    if (!found) return res.status(404).json({ error: 'WhatsApp не подтвердил этот номер' });
    touch(found.jid, people.get(found.jid) || '', 0);
    emit();
    return res.json({ jid: found.jid });
  } catch (error) {
    log.warn({ error: error.message }, 'WhatsApp phone lookup failed');
    return res.status(503).json({ error: 'Не удалось проверить номер в WhatsApp. Повтори позже.' });
  }
});
app.get('/api/chats/:jid/messages', requireAuth, (req, res) => {
  const jid = req.params.jid;
  if (!validChat(jid) || !stmt.chat.get(jid)) return res.status(404).json({ error: 'Chat not found' });
  res.json(stmt.messages.all(jid));
});
app.patch('/api/chats/:jid', requireAuth, (req, res) => {
  const jid = req.params.jid;
  const old = stmt.chat.get(jid);
  if (!validChat(jid) || !old) return res.status(404).json({ error: 'Chat not found' });
  const enabled = typeof req.body?.enabled === 'boolean' ? req.body.enabled : !!old.enabled;
  const target = req.body?.targetLanguage ?? old.target_language;
  if (typeof target !== 'string' || target.trim().length < 2 || target.length > 100)
    return res.status(400).json({ error: 'Language must be 2–100 characters' });
  stmt.setting.run(enabled ? 1 : 0, target.trim(), jid);
  emit();
  res.json({ ok: true });
});
app.post('/api/chats/:jid/send', requireAuth, async (req, res) => {
  const jid = req.params.jid;
  const chat = stmt.chat.get(jid);
  const original = req.body?.text;
  if (!validChat(jid) || !chat) return res.status(404).json({ error: 'Chat not found' });
  if (!chat.enabled) return res.status(409).json({ error: 'Enable translation for this chat first' });
  if (typeof original !== 'string' || !original.trim() || original.length > 4000)
    return res.status(400).json({ error: 'Message must contain 1–4000 characters' });
  if (connection !== 'connected' || !wa) return res.status(503).json({ error: 'WhatsApp is disconnected' });
  const requestId = req.body?.requestId;
  if (typeof requestId !== 'string' || !/^[0-9a-f-]{36}$/i.test(requestId))
    return res.status(400).json({ error: 'requestId required' });
  const id = 'local:' + requestId;
  const existing = stmt.msg.get(id);
  if (existing) return res.status(409).json({ error: 'This request was already processed; check the chat before retrying' });
  stmt.addMsg.run(id, jid, 'out', original, null, 'translating', Date.now());
  pruneHistory([id]);
  emit();
  try {
    const translated = await translate(original, 'Russian', chat.target_language);
    stmt.updateMsg.run(translated, 'sending', id);
    emit();
    // This is not safe to retry automatically after interruption.
    stmt.stateMsg.run('uncertain', id);
    const sent = await wa.sendMessage(jid, { text: translated });
    if (!sent?.key?.id) throw new Error('WhatsApp did not confirm message submission');
    bindOutgoingWaId(id, jid, sent.key.id);
    stmt.stateMsg.run('sent', id);
    pruneHistory([id]);
    emit();
    return res.json({ ok: true, translated });
  } catch (error) {
    log.warn({ error: error.message }, 'Outgoing message failed');
    stmt.stateMsg.run('error', id);
    pruneHistory([id]);
    emit();
    return res.status(502).json({ error: 'Not sent or status uncertain: ' + error.message + '. Check the chat before trying again.' });
  }
});
app.get('/api/messages/:id/image', requireAuth, (req, res) => {
  const id = req.params.id;
  const record = stmt.msg.get(id);
  if (!record || record.media_state !== 'ready' || !allowedMimes.has(record.media_mime))
    return res.status(404).end();
  const file = path.join(MEDIA_DIR, createHash('sha256').update(id).digest('hex') + '.image');
  if (!existsSync(file)) return res.status(404).end();
  res.setHeader('Content-Type', record.media_mime);
  res.setHeader('Content-Disposition', 'inline');
  res.setHeader('Cache-Control', 'private, no-store');
  res.setHeader('Content-Security-Policy', "default-src 'none'");
  const stream = createReadStream(file);
  stream.on('error', () => { if (!res.headersSent) res.status(500).end(); else res.destroy(); });
  stream.pipe(res);
});
app.post('/api/messages/retry', requireAuth, (req, res) => {
  const row = stmt.msg.get(req.body?.id);
  if (!row || row.direction !== 'in' || row.state !== 'error') return res.status(404).json({ error: 'No failed incoming translation found' });
  const chat = stmt.chat.get(row.jid);
  if (!chat?.enabled) return res.status(409).json({ error: 'Chat translation disabled' });
  stmt.stateMsg.run('translating', row.id);
  queueIncoming(row.id, row.original, chat.target_language);
  emit();
  res.json({ ok: true });
});
app.get('/api/events', requireAuth, (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();
  res.write('data: connected\n\n');
  clients.add(res);
  const heartbeat = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 20000);
  req.on('close', () => { clearInterval(heartbeat); clients.delete(res); });
});
app.get('/health', (_req, res) => res.json({ ok: true }));
app.use(express.static(path.join(HERE, 'public'), { index: 'index.html', maxAge: 0 }));
app.use((_req, res) => res.status(404).json({ error: 'Not found' }));
const PORT = Number(process.env.PORT || 3080);
const HOST = process.env.HOST || '127.0.0.1';
app.listen(PORT, HOST, () => {
  console.log('WhatsApp Translator listening on ' + HOST + ':' + PORT);
  pruneHistory();
  void connectWhatsApp();
  void runQueue();
});
process.on('SIGTERM', () => { db.close(); process.exit(0); });
