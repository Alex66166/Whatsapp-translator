#!/usr/bin/env bash
# Этап 2: установки ТОЛЬКО после изучения отдельного отчёта audit.sh.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Запустите sudo bash deploy.sh"; exit 1; }
cd "$(dirname "$(readlink -f "$0")")"
SRC="$(pwd)"
[[ -f "$SRC/server.mjs" && -f "$SRC/package.json" ]] || { echo "Запускать из корня проекта"; exit 1; }

echo "==== ЭТАП 2. Настройка по результатам аудита ===="
read -rp "Абсолютный путь к изученному файлу audit-report.txt: " AUDIT
[[ "$AUDIT" = /* && -f "$AUDIT" ]] || { echo "Аудит не найден. Сначала sudo bash audit.sh | tee audit-report.txt"; exit 1; }
grep -Fq 'АУДИТ ЗАВЕРШЁН:' "$AUDIT" || { echo "Это не законченный отчёт audit.sh"; exit 1; }
AGE="$(find "$AUDIT" -mmin +2880 -print)"
[[ -z "$AGE" ]] || { echo "Отчёт старше 48 часов, проведите повторный аудит"; exit 1; }
echo "Убедитесь, что вы проанализировали веб-серверы, все порты и влияние на другие службы."
read -rp "Наберите AUDIT-APPROVED после согласования конфигурации: " AGREEMENT
[[ "$AGREEMENT" == "AUDIT-APPROVED" ]] || { echo "Установка отменена"; exit 1; }

read -rp "Абсолютный каталог приложения (например, /opt/whatsapp-translator): " APP_DIR
read -rp "Имя systemd-службы (например, whatsapp-translator): " SERVICE
read -rp "Непривилегированный системный пользователь приложения (например, wttranslator): " APPUSER
read -rp "Свободный TCP-порт приложения на 127.0.0.1 (например, 3080): " PORT
read -rp "Домен для HTTPS-доступа (например, chat.example.com): " DOMAIN
echo "Реверс-прокси: [manual] ничего не меняем, создаём шаблон; [nginx] добавляем отдельный Nginx vhost после проверок."
read -rp "Режим [manual/nginx]: " PROXY_MODE
[[ "$APP_DIR" = /* && "$APP_DIR" =~ ^/[a-zA-Z0-9_./-]+$ && "$APP_DIR" != "/" && "$APP_DIR" != "/opt" && "$APP_DIR" != "/srv" ]] || { echo "Небезопасный путь приложения"; exit 1; }
[[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ && "$APPUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Недопустимые имена пользователя или службы"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Порт должен быть числом"; exit 1; }
(( 10#$PORT >= 1024 && 10#$PORT <= 65535 )) || { echo "Выберите TCP-порт 1024–65535"; exit 1; }
PORT="$((10#$PORT))"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ && "$DOMAIN" == *.* && "$DOMAIN" != -* ]] || { echo "Некорректный домен"; exit 1; }
[[ "$PROXY_MODE" == "manual" || "$PROXY_MODE" == "nginx" ]] || { echo "Выберите manual или nginx"; exit 1; }
[[ "$APP_DIR" != "$SRC" && "$APP_DIR" != "$SRC/"* && "$SRC" != "$APP_DIR/"* ]] || { echo "Каталог установки не должен совпадать с каталогом исходников"; exit 1; }
if [[ -L "$APP_DIR" ]]; then echo "Установка в симлинк запрещена"; exit 1; fi
if [[ -e "$APP_DIR" && ! -f "$APP_DIR/server.mjs" ]]; then
  echo "Каталог уже существует и не принадлежит нашему приложению"; exit 1
fi
if [[ -f "/etc/systemd/system/$SERVICE.service" ]] &&
   ! grep -Fq "WorkingDirectory=$APP_DIR" "/etc/systemd/system/$SERVICE.service"; then
  echo "Systemd-служба с таким именем уже принадлежит другому приложению"; exit 1
fi
if id "$APPUSER" >/dev/null 2>&1 && [[ "$(id -u "$APPUSER")" -eq 0 ]]; then
  echo "Приложение нельзя запускать от root"; exit 1
fi
EXISTING=0
[[ -f "$APP_DIR/.env" ]] && EXISTING=1
if ss -H -ltn "( sport = :$PORT )" | grep -q .; then
  OLD_PORT=""
  if [[ "$EXISTING" -eq 1 ]]; then
    OLD_PORT="$(grep '^PORT=' "$APP_DIR/.env" | tail -n 1 | cut -d= -f2-)"
  fi
  if [[ "$EXISTING" -ne 1 || "$OLD_PORT" != "$PORT" ]] ; then
    echo "Порт $PORT занят, выберите другой по результатам аудита"
    exit 1
  fi
  echo "Порт используется текущей инсталляцией; обновление согласовано."
fi
if [[ "$EXISTING" -eq 1 ]]; then
  CONFIG_PORT="$(grep '^PORT=' "$APP_DIR/.env" | tail -n 1 | cut -d= -f2-)"
  [[ "$CONFIG_PORT" == "$PORT" ]] || { echo "При переустановке укажите прежний порт; изменение порта — отдельная операция"; exit 1; }
fi

NGINX_SITE="/etc/nginx/sites-available/$SERVICE.conf"
if [[ "$PROXY_MODE" == "nginx" ]]; then
  if [[ -e "$NGINX_SITE" ]] && ! grep -Fq '# Configured by WhatsApp Translator deploy.sh' "$NGINX_SITE"; then
    echo "Файл Nginx уже используется другим приложением: $NGINX_SITE"; exit 1
  fi
  if command -v ss >/dev/null 2>&1; then
    # Если порт 80/443 обслуживает другой сервер, Nginx добавлять нельзя.
    if ss -ltnp | grep -E ':80[[:space:]]|:443[[:space:]]' | grep -Eiv 'nginx|State|Recv-Q' | grep -q .; then
      echo "На 80/443 работает процесс, который может конфликтовать с Nginx. Используйте manual."; exit 1
    fi
  fi
  if [[ -d /etc/nginx ]] &&
     grep -R -Fq "server_name $DOMAIN;" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null &&
     [[ ! -f "$NGINX_SITE" ]]; then
    echo "Домен уже настроен в Nginx. Воспользуйтесь manual."; exit 1
  fi
  read -rp "Email для Let's Encrypt: " EMAIL
  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "Некорректный email"; exit 1; }
  read -rp "Каталог HTTP-01 ACME challenge (например, /var/www/letsencrypt): " ACME_DIR
  [[ "$ACME_DIR" = /* && "$ACME_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo "Некорректный каталог"; exit 1; }
fi
if [[ "$EXISTING" -eq 1 ]]; then
  read -rp "Абсолютный каталог для ЗАШИФРОВАННОЙ копии перед переустановкой (например, /root/wt-backups): " BACKUP_DIR
  [[ "$BACKUP_DIR" = /* ]] || { echo "Каталог должен быть абсолютным"; exit 1; }
  echo "Старые .env, WhatsApp-сессия, БД и медиа будут сохранены."
else
  read -rsp "Пароль веб-интерфейса (не менее 12 символов): " PASSWORD; echo
  [[ "$(printf '%s' "$PASSWORD" | wc -c)" -ge 12 ]] || { echo "Слишком короткий пароль"; exit 1; }
  read -rsp "Ключ Groq (gsk_...): " GROQ; echo
  [[ "$GROQ" =~ ^gsk_[-_a-zA-Z0-9]+$ ]] || { echo "Некорректный формат ключа Groq"; exit 1; }
  read -rp "Модель Groq (например, openai/gpt-oss-120b): " GROQ_MODEL
  read -rp "Язык собеседников по умолчанию (например, Montenegrin (Latin script, Ijekavian)): " TARGET_LANG
  [[ "$GROQ_MODEL" =~ ^[a-zA-Z0-9_./-]+$ && "$TARGET_LANG" =~ ^[a-zA-Z0-9.,\ \(\)-]+$ ]] || { echo "Некорректные настройки языка или модели"; exit 1; }
  read -rp "Максимальный размер изображения, МБ (например, 8): " MAX_IMAGE
  read -rp "Общий лимит изображений на диске, МБ (например, 512): " MAX_MEDIA
  [[ "$MAX_IMAGE" =~ ^[0-9]+$ && "$MAX_MEDIA" =~ ^[0-9]+$ ]] || { echo "Лимиты должны быть целыми числами"; exit 1; }
  (( MAX_IMAGE >= 1 && MAX_IMAGE <= 32 && MAX_MEDIA >= MAX_IMAGE && MAX_MEDIA <= 10000 )) || { echo "Лимиты должны быть в диапазоне 1–32 МБ и от размера файла до 10000 МБ"; exit 1; }
fi

echo
echo "==== ПЛАН ИЗМЕНЕНИЙ ===="
printf 'Каталог: %s\nSystemd: %s\nПользователь: %s\nПривязка: 127.0.0.1:%s\nДомен: %s\nРеверс-прокси: %s\n' "$APP_DIR" "$SERVICE" "$APPUSER" "$PORT" "$DOMAIN" "$PROXY_MODE"
echo "Установятся необходимые пакеты/Node.js, приложение и systemd. Файрвол и действующие vhost не будут меняться."
if [[ "$PROXY_MODE" == "nginx" ]]; then
  echo "Будет добавлен отдельный vhost Nginx, получен сертификат Let's Encrypt."
else
  echo "Текущий веб-сервер останется нетронутым. Будет создан только шаблон настроек."
fi
if [[ "$EXISTING" -eq 1 ]]; then echo "Обновление только после ЗАШИФРОВАННОГО бэкапа."; fi
read -rp "Для применения наберите INSTALL: " YES
[[ "$YES" == "INSTALL" ]] || { echo "Отменено без изменений"; exit 1; }

if [[ "$EXISTING" -eq 1 ]]; then
  bash "$SRC/backup.sh" "$APP_DIR" "$BACKUP_DIR" "$SERVICE"
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg build-essential python3 rsync openssl
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  echo "Устанавливаем Node.js 22 LTS"
  curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/wt-node-setup.sh
  bash /tmp/wt-node-setup.sh
  apt-get install -y nodejs
  rm -f /tmp/wt-node-setup.sh
fi
if [[ "$PROXY_MODE" == "nginx" ]]; then apt-get install -y nginx certbot; fi
if ! id "$APPUSER" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APPUSER"
fi
APPGROUP="$(id -gn "$APPUSER")"
install -d -m 750 -o "$APPUSER" -g "$APPGROUP" "$APP_DIR"
rsync -a --exclude='.git/' --exclude='.env' --exclude='.data/' --exclude='node_modules/' --exclude='audit-report.txt' --exclude='audit-*.txt' "$SRC/" "$APP_DIR/"
if [[ "$EXISTING" -eq 0 ]]; then
  SALT="$(openssl rand -hex 16)"
  export SALT
  HASH="$(printf '%s' "$PASSWORD" | node -e 'const c=require("crypto");let b=[];process.stdin.on("data",x=>b.push(x));process.stdin.on("end",()=>process.stdout.write(c.scryptSync(Buffer.concat(b),Buffer.from(process.env.SALT,"hex"),64).toString("hex")))' )"
  {
    printf 'HOST=127.0.0.1\nPORT=%s\n' "$PORT"
    printf 'GROQ_API_KEY=%s\n' "$GROQ"
    printf 'GROQ_MODEL=%s\n' "$GROQ_MODEL"
    printf 'DEFAULT_TARGET_LANGUAGE="%s"\n' "$TARGET_LANG"
    printf 'MEDIA_MAX_MB=%s\nMEDIA_TOTAL_MB=%s\n' "$MAX_IMAGE" "$MAX_MEDIA"
    printf 'ADMIN_PASSWORD_HASH=%s:%s\n' "$SALT" "$HASH"
    printf 'SESSION_SECRET=%s\n' "$(openssl rand -hex 32)"
    printf 'COOKIE_SECURE=1\nDATA_DIR=.data\n'
  } > "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  unset PASSWORD GROQ HASH SALT
else
  # Конфигурация обновления не меняется без явного согласования.
fi
install -d -m 700 -o "$APPUSER" -g "$APPGROUP" "$APP_DIR/.data"
chown -R "$APPUSER:$APPGROUP" "$APP_DIR"
runuser -u "$APPUSER" -- env HOME="$APP_DIR" sh -c 'cd "$1" && npm install --omit=dev --no-audit --no-fund && npm run check' sh "$APP_DIR"

cat > "/etc/systemd/system/$SERVICE.service" <<UNIT
[Unit]
Description=Private WhatsApp translation web client
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$APPUSER
Group=$APPGROUP
WorkingDirectory=$APP_DIR
ExecStart=$(command -v node) $APP_DIR/server.mjs
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=768
Restart=always
RestartSec=7
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$APP_DIR/.data
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "$SERVICE.service"
systemctl restart "$SERVICE.service"

install -d -m 750 "$APP_DIR/deploy-examples"
cat > "$APP_DIR/deploy-examples/nginx-example.conf" <<CONF
# Пример для ручной настройки существующего Nginx. Нужен действующий HTTPS.
server {
    listen 443 ssl;
    server_name $DOMAIN;
    # Укажите пути уже полученного TLS-сертификата.
    ssl_certificate /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
CONF
if [[ "$PROXY_MODE" == "nginx" ]]; then
  [[ ! -e "$NGINX_SITE" ]] || grep -Fq '# Configured by WhatsApp Translator deploy.sh' "$NGINX_SITE" || { echo "У Nginx появился конфликт"; exit 1; }
  install -d -m 755 "$ACME_DIR/.well-known/acme-challenge"
  cat > "$NGINX_SITE" <<CONF
# Configured by WhatsApp Translator deploy.sh
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { return 404; }
}
CONF
  ln -sfn "$NGINX_SITE" "/etc/nginx/sites-enabled/$SERVICE.conf"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  certbot certonly --non-interactive --agree-tos --email "$EMAIL" --webroot -w "$ACME_DIR" -d "$DOMAIN" --keep-until-expiring
  cat > "$NGINX_SITE" <<CONF
# Configured by WhatsApp Translator deploy.sh
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 32k;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
CONF
  nginx -t
  systemctl reload nginx
  echo "Готово: https://$DOMAIN"
else
  echo "Приложение запущено локально. Согласуйте TLS/reverse-proxy по шаблону:"
  echo "$APP_DIR/deploy-examples/nginx-example.conf"
fi
echo "Служба: systemctl status $SERVICE"
echo "Журнал: journalctl -u $SERVICE -n 100 --no-pager"
