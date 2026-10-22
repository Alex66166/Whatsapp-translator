'use strict';
const $ = id => document.getElementById(id);
const state = { chats: [], selected: null, busy: false, loggedIn: false, status: '', refreshing: false };
let refreshTimer;
let toastTimer;
let events;
function notification(text) {
  $('toast').textContent = text;
  $('toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 5500);
}
async function api(endpoint, options = {}) {
  const response = await fetch('/api' + endpoint, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    ...options
  });
  let body = {};
  try { body = await response.json(); } catch {}
  if (response.status === 401 && endpoint !== '/login') {
    displayLogin();
    throw new Error('Нужно войти заново');
  }
  if (!response.ok) throw new Error(body.error || 'HTTP ' + response.status);
  return body;
}
function displayLogin() {
  state.loggedIn = false;
  $('login').hidden = false;
  $('app').hidden = true;
  events?.close();
}
function displayApp() {
  state.loggedIn = true;
  $('login').hidden = true;
  $('app').hidden = false;
}
function setStatus(data) {
  state.status = data.connection || 'unknown';
  const labels = {
    connected: '● WhatsApp подключён',
    scan_qr: '○ Ожидается QR-код',
    connecting: '○ Подключение…',
    disconnected: '○ Переподключение…',
    logged_out: '○ Нужна привязка',
    error: '○ Ошибка соединения'
  };
  $('connection').textContent = labels[state.status] || state.status;
  $('connection').classList.toggle('online', state.status === 'connected');
  $('pairing').hidden = state.status === 'connected';
  $('qr').hidden = !data.qr;
  if (data.qr) $('qr').src = data.qr;
  else $('qr').removeAttribute('src');
  $('reconnect').hidden = !['logged_out', 'error', 'disconnected'].includes(state.status);
  $('reconnect').textContent = state.status === 'logged_out' ? 'Привязать WhatsApp заново' : 'Переподключить';
  $('pairing-title').textContent = state.status === 'logged_out' ? 'Сессия отключена. Требуется новая привязка.' : 'Подключение WhatsApp';
  $('pairing-details').textContent = data.qr
    ? 'В телефоне: WhatsApp → Связанные устройства → Привязка устройства → сканировать QR.'
    : 'Дождитесь QR-кода. Если соединение потеряно, используйте кнопку повторного подключения.';
  if (!data.groqConfigured) notification('Groq API-ключ не настроен на сервере: переводы не будут работать.');
  updateComposer();
}
function initial(name) { return (name || '?').trim().slice(0, 1).toUpperCase(); }
function el(tag, className, value) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (value !== undefined) element.textContent = value;
  return element;
}
function currentChat() { return state.chats.find(c => c.jid === state.selected); }
function renderChats() {
  const list = $('chat-list');
  list.replaceChildren();
  const term = $('search').value.trim().toLocaleLowerCase();
  const only = $('only-enabled').checked;
  const chats = state.chats.filter(c =>
    (!only || c.enabled) &&
    (c.title.toLocaleLowerCase().includes(term) || c.jid.toLowerCase().includes(term))
  );
  if (!chats.length) list.append(el('p', 'muted list-hint', 'Нет подходящих чатов. Список появится после синхронизации WhatsApp.'));
  for (const c of chats) {
    const button = el('button', 'chat-item');
    button.type = 'button';
    if (c.jid === state.selected) button.classList.add('selected');
    const avatar = el('span', 'avatar', initial(c.title));
    const details = el('span', 'chat-item-text');
    details.append(el('strong', '', c.title));
    details.append(el('small', '', c.enabled ? '🌐 ' + c.targetLanguage : 'Без перевода'));
    button.append(avatar, details);
    button.addEventListener('click', () => chooseChat(c.jid));
    list.append(button);
  }
}
function chooseChat(jid) {
  state.selected = jid;
  $('app').classList.add('show-conversation');
  renderChats();
  renderHeader();
  void refreshMessages();
}
function renderHeader() {
  const c = currentChat();
  $('empty').hidden = !!c;
  $('active-chat').hidden = !c;
  if (!c) return;
  $('chat-name').textContent = c.title;
  $('chat-jid').textContent = c.jid;
  $('enable-chat').checked = c.enabled;
  if (document.activeElement !== $('target-language')) $('target-language').value = c.targetLanguage;
  updateComposer();
}
function updateComposer() {
  const c = currentChat();
  const allow = !!c?.enabled && state.status === 'connected' && !state.busy;
  $('draft').disabled = !allow;
  $('send').disabled = !allow || !$('draft').value.trim();
  $('compose-state').textContent = !c?.enabled ? 'Для этого чата перевод отключён'
    : state.status !== 'connected' ? 'WhatsApp не подключён'
    : state.busy ? 'Перевод и отправка…'
    : 'Сообщение будет переведено автоматически';
}
function renderMessages(messages) {
  const list = $('messages');
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 120;
  list.replaceChildren();
  if (!messages.length) {
    list.append(el('p', 'muted', 'Здесь будут новые сообщения после включения перевода. Старая история автоматически не загружается.'));
    return;
  }
  for (const m of messages) {
    const bubble = el('article', 'bubble ' + (m.direction === 'out' ? 'out' : 'in'));
    const display = (m.direction === 'in' ? m.translated : m.original) || m.original;
    if (m.media_state === 'ready') {
      const photo = el('img', 'chat-photo');
      photo.alt = 'Фото из WhatsApp';
      photo.loading = 'lazy';
      photo.src = '/api/messages/' + encodeURIComponent(m.id) + '/image';
      photo.addEventListener('click', () => window.open(photo.src, '_blank', 'noopener,noreferrer'));
      photo.tabIndex = 0;
      photo.addEventListener('keydown', e => {
        if (e.key === 'Enter') window.open(photo.src, '_blank', 'noopener,noreferrer');
      });
      bubble.append(photo);
    } else if (m.media_state === 'loading') {
      bubble.append(el('div', 'photo-status', '⏳ Загрузка изображения из WhatsApp…'));
    } else if (m.media_state === 'error') {
      bubble.append(el('div', 'photo-status', '⚠️ Фото недоступно (лимит, истёк срок или ошибка загрузки)'));
    }
    if (display) bubble.append(el('div', 'text', display));
    if (m.translated && m.translated !== display) bubble.append(el('div', 'original', m.translated));
    else if (m.direction === 'in' && m.translated) bubble.append(el('div', 'original', m.original));
    const footer = el('div', 'msg-meta');
    const t = new Date(m.created_at).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
    const status = { translating: 'Переводится', ready: 'Переведено', sent: 'Отправлено', 'sent-original': 'Отправлено из WhatsApp без перевода', sending: 'Отправляется', error: 'Ошибка — не подтверждено', uncertain: 'Доставка не подтверждена' };
    footer.textContent = t + ' · ' + (status[m.state] || m.state);
    bubble.append(footer);
    if (m.direction === 'in' && m.state === 'error') {
      const retry = el('button', 'secondary small', 'Повторить перевод');
      retry.addEventListener('click', async () => {
        try { await api('/messages/retry', { method: 'POST', body: JSON.stringify({ id: m.id }) }); await refreshMessages(); }
        catch (e) { notification(e.message); }
      });
      bubble.append(retry);
    }
    list.append(bubble);
  }
  if (nearBottom) list.scrollTop = list.scrollHeight;
}
async function refreshMessages() {
  if (!state.selected) return;
  const jid = state.selected;
  try {
    const messages = await api('/chats/' + encodeURIComponent(jid) + '/messages');
    if (jid === state.selected) renderMessages(messages);
  } catch (e) { notification(e.message); }
}
async function refreshAll() {
  if (!state.loggedIn || state.refreshing) return;
  state.refreshing = true;
  try {
    const [status, chats] = await Promise.all([api('/status'), api('/chats')]);
    setStatus(status);
    state.chats = chats;
    renderChats();
    if (state.selected && !currentChat()) state.selected = null;
    renderHeader();
    if (state.selected) await refreshMessages();
  } catch (e) { if (state.loggedIn) notification(e.message); }
  finally { state.refreshing = false; }
}
function startRealtime() {
  if (events) events.close();
  events = new EventSource('/api/events');
  events.onmessage = () => {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => void refreshAll(), 300);
  };
  // Polling fallback if a proxy/browser interrupts the event stream.
  setInterval(() => { if (state.loggedIn) void refreshAll(); }, 10000);
}
$('login-form').addEventListener('submit', async e => {
  e.preventDefault();
  $('login-error').textContent = '';
  try {
    await api('/login', { method: 'POST', body: JSON.stringify({ password: $('login-password').value }) });
    $('login-password').value = '';
    displayApp();
    await refreshAll();
    startRealtime();
  } catch (error) { $('login-error').textContent = error.message; }
});
$('logout').addEventListener('click', async () => {
  try { await api('/logout', { method: 'POST', body: '{}' }); } catch {}
  displayLogin();
});
$('reconnect').addEventListener('click', async () => {
  try {
    if (state.status === 'logged_out') {
      if (!window.confirm('WhatsApp отвязал это устройство. Повторная привязка создаст новую сессию. Продолжить?')) return;
      const password = window.prompt('Введите пароль входа в переводчик для повторной привязки:');
      if (!password) return;
      await api('/relink', { method: 'POST', body: JSON.stringify({ password, confirm: 'RELINK' }) });
    } else {
      await api('/connect', { method: 'POST', body: '{}' });
    }
    await refreshAll();
  } catch (e) { notification(e.message); }
});
$('search').addEventListener('input', renderChats);
$('only-enabled').addEventListener('change', renderChats);
$('enable-chat').addEventListener('change', async e => {
  const c = currentChat();
  if (!c) return;
  try {
    await api('/chats/' + encodeURIComponent(c.jid), {
      method: 'PATCH', body: JSON.stringify({ enabled: e.target.checked })
    });
    await refreshAll();
  } catch (error) { notification(error.message); e.target.checked = c.enabled; }
});
$('save-language').addEventListener('click', async () => {
  const c = currentChat();
  if (!c) return;
  try {
    await api('/chats/' + encodeURIComponent(c.jid), {
      method: 'PATCH', body: JSON.stringify({ targetLanguage: $('target-language').value })
    });
    notification('Язык сохранён');
    await refreshAll();
  } catch (error) { notification(error.message); }
});
$('compose').addEventListener('submit', async e => {
  e.preventDefault();
  const c = currentChat();
  const text = $('draft').value.trim();
  if (!c?.enabled || !text || state.busy) return;
  state.busy = true;
  updateComposer();
  const requestId = crypto.randomUUID();
  try {
    await api('/chats/' + encodeURIComponent(c.jid) + '/send', {
      method: 'POST', body: JSON.stringify({ text, requestId })
    });
    $('draft').value = '';
    await refreshMessages();
  } catch (error) { notification(error.message); await refreshMessages(); }
  finally { state.busy = false; updateComposer(); }
});
$('draft').addEventListener('input', updateComposer);
$('draft').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    if (!$('send').disabled) $('compose').requestSubmit();
  }
});
$('mobile-back').addEventListener('click', () => $('app').classList.remove('show-conversation'));
(async () => {
  try {
    await api('/status');
    displayApp();
    await refreshAll();
    startRealtime();
  } catch { displayLogin(); }
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
})();
