// Recent personal chats are ranked by WhatsApp's conversation timestamps,
// not by contact-sync arrival time or import order.
// Metadata-only: no message body is required to select a conversation.
export const RECENT_CHAT_LIMIT = 20;

export function whatsappTimestampMs(value) {
  let n;
  if (value && typeof value === 'object' && typeof value.toNumber === 'function') {
    n = value.toNumber();
  } else if (value && typeof value === 'object' && typeof value.low === 'number') {
    n = value.low >>> 0;
  } else {
    n = Number(value);
  }
  if (!Number.isFinite(n) || n <= 0) return 0;
  const ms = n < 1e11 ? n * 1000 : n;
  return ms < Date.now() + 365 * 86400000 ? Math.floor(ms) : 0;
}

export function chatMetadataTime(chat) {
  return whatsappTimestampMs(chat?.conversationTimestamp ??
    chat?.lastMessageRecvTimestamp ??
    chat?.lastMessage?.messageTimestamp ??
    chat?.lastMessage?.timestamp ??
    chat?.timestamp ?? 0);
}

// Historical WhatsApp message metadata is useful solely for ranking chat
// contacts. Never inspect or store any content of message.message.
export function historicalChatRef(message) {
  const jid = message?.key?.remoteJid;
  if (typeof jid !== 'string' ||
      !(jid.endsWith('@lid') || jid.endsWith('@s.whatsapp.net')) ||
      message?.key?.participant) return null;
  const timestamp = whatsappTimestampMs(message?.messageTimestamp);
  if (!timestamp) return null;
  return {
    jid,
    timestamp,
    name: !message.key.fromMe && typeof message.pushName === 'string'
      ? message.pushName.slice(0,160) : ''
  };
}

export function recentChats(db, limit=RECENT_CHAT_LIMIT) {
  if (!Number.isInteger(limit) || limit < 1 || limit > RECENT_CHAT_LIMIT) throw Error('Invalid recent chat limit');
  return db.prepare("SELECT * FROM chats WHERE last_activity > 0 AND (jid GLOB '*@s.whatsapp.net' OR jid GLOB '*@lid') ORDER BY last_activity DESC, jid ASC LIMIT ?").all(limit);
}
