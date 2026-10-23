/**
 * Message handling rules shared by translated and ordinary WhatsApp chats.
 * Missing checkbox must never silently drop the first live message.
 */
export function incomingMessageState(text, translationEnabled, fromMe=false) {
  if (fromMe) return 'sent-original';
  if (!text?.trim()) return 'received-original';
  return translationEnabled ? 'translating' : 'received-original';
}

export async function outgoingMessageText(original, translationEnabled, language, translator) {
  if (!translationEnabled) return original;
  return translator(original, 'Russian', language);
}
