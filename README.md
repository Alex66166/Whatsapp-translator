# WhatsApp Translator

Private, self-hosted WhatsApp translation inbox for **Windows 11 and Android**. One linked WhatsApp account, as many individual chats as WhatsApp synchronizes, translation via **Groq Cloud** (no local language model).

> **Initial MVP; not yet tested against a real WhatsApp account.** Baileys uses an unofficial WhatsApp protocol. Using it may risk temporary or permanent account restrictions. Never use this project for bulk messaging, unsolicited outreach or scraping.

## Capabilities

- One WhatsApp number; link once by QR code in **Linked Devices**.
- Dynamic list and search of chats; **no hardcoded contacts, numbers or chat IDs**.
- Translation is **off by default** for each chat. Enable and set the contact's target language independently.
- Incoming: contact's language → Russian, with source text visible.
- Outgoing: write Russian → Groq translates → WhatsApp receives translated text. Both variants remain visible locally.
- Free-tier Groq API (limited by the provider), SQLite, single Node.js process, web interface with login, QR pairing, SSE updates.
- Windows browser/desktop shortcut and Android browser/home-screen shortcut.
- Only selected chats' new text is sent for translation.

**Not in this first version:** group chats, media/voice, native device push notifications, complete history import, multiple WhatsApp accounts. New contact availability depends on WhatsApp synchronization. Messages sent directly from regular WhatsApp are not rewritten by this app.

## Server requirements

- Ubuntu 24.04 VPS; 2 GB RAM recommended, 4 GB swap optional, 20 GB disk enough for a small text inbox.
- Public DNS A record pointing at the server; TCP ports **80 and 443** open.
- Free Groq key: https://console.groq.com/keys (availability/rate limits are not guaranteed).
- A long web-app administrator password.
- Node 22 or higher (installer configures Node 22).
- GitHub SSH credentials/deploy key for cloning this **private** repository.

## Installation

Clone this repository to the VPS via SSH (configure a deploy key or GitHub CLI credentials first). Run from the cloned directory:

```bash
sudo bash install.sh
```

Installer prompts for DNS domain, Let's Encrypt email, strong password and Groq key. It copies files to `/opt/whatsapp-translator`, installs dependencies, sets up a dedicated service user, systemd, Nginx reverse proxy and HTTPS.

**Important:** do not use a domain already configured in another Nginx virtual host without checking conflicts. Existing `.env` and `.data` are preserved when reinstalling. The VPS needs working DNS and reachable port 80 for Let's Encrypt to succeed. The installer does not adjust firewall rules. Node dependencies are installed from npm.

After installation:

1. Open `https://YOUR-DOMAIN` in Chrome/Edge on Windows or Android.
2. Log in with the password chosen during installation.
3. On the phone, go to **WhatsApp → Linked Devices → Link a device**, then scan the QR code shown in the web client.
4. Wait for synchronization. Select a contact, turn on **Translation**, and enter a language, e.g. **Montenegrin (Latin script, Ijekavian)**.
5. Read the Russian translations and write Russian replies. **Enter** sends; **Shift+Enter** adds a new line.

If translation fails, an incoming message has a **Retry translation** action. Outgoing messages won't intentionally be sent in Russian when translation fails. However, **network failures can leave delivery uncertain**; before trying again, check the ordinary WhatsApp conversation to avoid duplicate messages.

## Operations

```bash
sudo systemctl status whatsapp-translator
sudo journalctl -u whatsapp-translator -n 100 --no-pager
sudo systemctl restart whatsapp-translator
```

To update: `git pull` in your original clone and rerun `sudo bash install.sh`. The installer keeps local session credentials. Back up `/opt/whatsapp-translator/.env` and `/opt/whatsapp-translator/.data` into **encrypted storage**. These files include sensitive login and WhatsApp session material. Never commit either file.

## Architecture

```
WhatsApp <-> Baileys 6.7.24 <-> Node.js / Express <-> SQLite
                                  |
                                  +-- Groq Cloud translation
                                  |
                                  +-- Nginx HTTPS <-> Windows / Android PWA
```

No Docker, Chromium, Redis or local LLM.

## Development

Copy `.env.example` to `.env` and provide a Groq key, a random session secret and an admin password hash in format `salt_hex:scrypt_digest_hex`. The production installer generates the hash automatically. For a **local-only** HTTP setup, set `COOKIE_SECURE=0`; never run with insecure cookies on a publicly exposed HTTP port.

```bash
npm install
npm run check
npm test
npm start
```

The app listens on `127.0.0.1:3080` by default.

## Security and caveats

- Selected message contents are sent to Groq for translation. Review the provider's privacy/data handling before confidential use.
- Secure cookies and a password gate protect the web interface. Only expose the HTTPS Nginx endpoint; the Node port is loopback-only.
- Session tokens stored under `.data/auth` allow access to the WhatsApp account.
- This initial implementation has not yet been tested with live WhatsApp pairing, LID contact mappings and long-term reconnections. Validate with a noncritical account before relying on it.
