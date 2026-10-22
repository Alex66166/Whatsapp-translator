#!/usr/bin/env bash
# Install on Ubuntu 24.04. Run from a checked-out repository as root.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ "$(id -u)" -eq 0 ]] || { echo "Run: sudo bash install.sh"; exit 1; }
[[ -f ./package.json && -f ./server.mjs ]] || { echo "Run from the project directory"; exit 1; }
SOURCE_DIR="$(pwd)"
DEST=/opt/whatsapp-translator
SERVICE=whatsapp-translator
APPUSER=wttranslator

echo "=== WhatsApp Translator / Ubuntu 24.04 ==="
read -rp "Public DNS name pointing to this VPS (example: wa.example.com): " DOMAIN
read -rp "Email address for HTTPS certificate renewal notices: " EMAIL
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ || "$DOMAIN" != *.* || "$DOMAIN" == -* ]]; then
  echo "Invalid domain"; exit 1
fi
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "Invalid email"; exit 1
fi
if [[ ! -f "$DEST/.env" ]]; then
  read -rsp "Web-app password (minimum 12 chars): " PASSWORD; echo
  [[ "$(printf '%s' "$PASSWORD" | wc -c)" -ge 12 ]] || { echo "Password too short"; exit 1; }
  read -rsp "Groq API key (from console.groq.com/keys): " GROQ_KEY; echo
  [[ "$GROQ_KEY" =~ ^gsk_[-_a-zA-Z0-9]+$ ]] || { echo "Invalid Groq key format"; exit 1; }
fi
echo "Installing prerequisites..."
apt-get update
apt-get install -y ca-certificates curl gnupg openssl build-essential python3 nginx certbot rsync
if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/wt-nodesource.sh
  bash /tmp/wt-nodesource.sh
  apt-get install -y nodejs
  rm -f /tmp/wt-nodesource.sh
fi
id "$APPUSER" >/dev/null 2>&1 || useradd --system --home-dir "$DEST" --shell /usr/sbin/nologin "$APPUSER"
install -d -m 750 -o "$APPUSER" -g "$APPUSER" "$DEST"
rsync -a --exclude='.git/' --exclude='.env' --exclude='.data/' --exclude='node_modules/' "$SOURCE_DIR/" "$DEST/"
if [[ ! -f "$DEST/.env" ]]; then
  SALT="$(openssl rand -hex 16)"
  export SALT
  HASH="$(printf '%s' "$PASSWORD" | node -e 'const c=require("crypto");let b=[];process.stdin.on("data",x=>b.push(x));process.stdin.on("end",()=>process.stdout.write(c.scryptSync(Buffer.concat(b),Buffer.from(process.env.SALT,"hex"),64).toString("hex")))' )"
  {
    printf 'HOST=127.0.0.1\nPORT=3080\n'
    printf 'GROQ_API_KEY=%s\n' "$GROQ_KEY"
    printf 'GROQ_MODEL=openai/gpt-oss-120b\n'
    printf 'DEFAULT_TARGET_LANGUAGE="Montenegrin (Latin script, Ijekavian)"\n'
    printf 'ADMIN_PASSWORD_HASH=%s:%s\n' "$SALT" "$HASH"
    printf 'SESSION_SECRET=%s\n' "$(openssl rand -hex 32)"
    printf 'COOKIE_SECURE=1\nDATA_DIR=.data\n'
  } > "$DEST/.env"
  chmod 600 "$DEST/.env"
  unset PASSWORD GROQ_KEY HASH SALT
fi
install -d -m 700 -o "$APPUSER" -g "$APPUSER" "$DEST/.data"
chown -R "$APPUSER:$APPUSER" "$DEST"
echo "Installing Node.js dependencies..."
runuser -u "$APPUSER" -- sh -c "cd '$DEST' && npm install --omit=dev --no-audit --no-fund"
runuser -u "$APPUSER" -- sh -c "cd '$DEST' && npm run check"

cat > "/etc/systemd/system/$SERVICE.service" <<'UNIT'
[Unit]
Description=Private WhatsApp Translator
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=wttranslator
Group=wttranslator
WorkingDirectory=/opt/whatsapp-translator
ExecStart=/usr/bin/node /opt/whatsapp-translator/server.mjs
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=768
Restart=always
RestartSec=7
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/whatsapp-translator/.data
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "$SERVICE"

echo "Configuring Nginx & automatic HTTPS..."
install -d -m 755 /var/www/letsencrypt/.well-known/acme-challenge
cat >/etc/nginx/sites-available/whatsapp-translator <<'NGINX'
server {
  listen 80;
  server_name __DOMAIN__;
  location ^~ /.well-known/acme-challenge/ {
    root /var/www/letsencrypt;
  }
  location / { return 404; }
}
NGINX
sed -i "s/__DOMAIN__/$DOMAIN/g" /etc/nginx/sites-available/whatsapp-translator
ln -sf /etc/nginx/sites-available/whatsapp-translator /etc/nginx/sites-enabled/whatsapp-translator
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "Requesting certificate. DNS A record and port 80 must already work."
certbot certonly --non-interactive --agree-tos --email "$EMAIL" --webroot -w /var/www/letsencrypt -d "$DOMAIN" --keep-until-expiring

cat >/etc/nginx/sites-available/whatsapp-translator <<'NGINX'
server {
  listen 80;
  server_name __DOMAIN__;
  location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
  location / { return 301 https://$host$request_uri; }
}
server {
  listen 443 ssl;
  server_name __DOMAIN__;
  ssl_certificate /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  add_header Strict-Transport-Security "max-age=31536000" always;
  client_max_body_size 32k;
  location / {
    proxy_pass http://127.0.0.1:3080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 3600s;
  }
}
NGINX
sed -i "s/__DOMAIN__/$DOMAIN/g" /etc/nginx/sites-available/whatsapp-translator
nginx -t
systemctl reload nginx
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-wt.sh
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-wt.sh
echo "READY: https://$DOMAIN"
echo "Service: systemctl status $SERVICE"
echo "Logs: journalctl -u $SERVICE -n 80 --no-pager"
