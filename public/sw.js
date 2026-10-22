// PWA shell only. Never cache auth, QR codes, API responses, or private messages.
self.addEventListener('install', event => { self.skipWaiting(); });
self.addEventListener('activate', event => { event.waitUntil(self.clients.claim()); });
