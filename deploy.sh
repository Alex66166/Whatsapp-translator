#!/usr/bin/env bash
# Этап 2: установки ТОЛЬКО после изучения отдельного отчёта audit.sh.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Запустите sudo bash deploy.sh"; exit 1; }
cd "$(dirname "$(readlink -f "$0")")"
SRC="$(pwd)"
[[ -f "$SRC/server.mjs" && -f "$SRC/package.json" ]] || { echo "Запускать из корня проекта"; exit 1; }

ask() {
  local variable="$1" label="$2" suggested="$3" entered=""
  if [[ -n "$suggested" ]]; then
    read -rp "$label [$suggested]: " entered || exit 1
  else
    read -rp "$label: " entered || exit 1
  fi
  printf -v "$variable" "%s" "${entered:-$suggested}"
}
echo "==== ЭТАП 2. Настройка по результатам аудита ===="
AUDIT="${WA_AUDIT_REPORT:-}"
# При запуске через bootstrap.sh отчёт известен и повторно не спрашивается.
if [[ -z "$AUDIT" ]]; then
  ask AUDIT "Путь к отчёту аудита" ""
fi
[[ "$AUDIT" = /* && -f "$AUDIT" ]] || { echo "Отчёт аудита не найден; сначала выполните аудит"; exit 1; }
grep -Fq 'АУДИТ ЗАВЕРШЁН:' "$AUDIT" || { echo "Отчёт аудита не завершён"; exit 1; }
AGE="$(find "$AUDIT" -mmin +2880 -print)"
[[ -z "$AGE" ]] || { echo "Отчёт старше 48 часов; повторите аудит"; exit 1; }
echo "Аудит завершён, отчёт сохранён: $AUDIT"

ask APP_DIR "Каталог приложения" "${WA_REC_APP_DIR:-/opt/whatsapp-translator}"
ask SERVICE "Служба systemd" "${WA_REC_SERVICE:-whatsapp-translator}"
ask APPUSER "Системный пользователь" "${WA_REC_APPUSER:-wttranslator}"
ask PORT "Локальный порт Node.js (только 127.0.0.1)" "${WA_REC_PORT:-3080}"
ask EXTERNAL_PORT "Внешний порт HTTPS (стандартно 443)" "${WA_REC_EXTERNAL_PORT:-443}"
ask DOMAIN "Домен HTTPS" "${WA_REC_DOMAIN:-}"
echo "Реверс-прокси: manual (без изменений); nginx (новый); nginx-existing/apache-existing/caddy-existing (интеграция в работающий HTTPS-сервер)."
ask PROXY_MODE "Режим reverse-proxy (manual/nginx)" "${WA_REC_PROXY_MODE:-manual}"
[[ "$APP_DIR" = /* && "$APP_DIR" =~ ^/[a-zA-Z0-9_./-]+$ && "$APP_DIR" != "/" && "$APP_DIR" != "/opt" && "$APP_DIR" != "/srv" ]] || { echo "Небезопасный путь приложения"; exit 1; }
[[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ && "$APPUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Недопустимые имена пользователя или службы"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Порт должен быть числом"; exit 1; }
(( 10#$PORT >= 1024 && 10#$PORT <= 65535 )) || { echo "Выберите TCP-порт 1024–65535"; exit 1; }
PORT="$((10#$PORT))"
[[ "$EXTERNAL_PORT" =~ ^[0-9]+$ ]] || { echo "Внешний порт должен быть числом"; exit 1; }
(( 10#$EXTERNAL_PORT >= 1 && 10#$EXTERNAL_PORT <= 65535 )) || { echo "Внешний порт: 1–65535"; exit 1; }
EXTERNAL_PORT="$((10#$EXTERNAL_PORT))"
[[ "$EXTERNAL_PORT" != "$PORT" ]] || { echo "Внешний и внутренний порты должны различаться"; exit 1; }
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ && "$DOMAIN" == *.* && "$DOMAIN" != -* ]] || { echo "Некорректный домен"; exit 1; }
[[ "$PROXY_MODE" =~ ^(manual|nginx|nginx-existing|apache-existing|caddy-existing)$ ]] || { echo "Неизвестный режим reverse-proxy"; exit 1; }
[[ "$APP_DIR" != "$SRC" && "$APP_DIR" != "$SRC/"* && "$SRC" != "$APP_DIR/"* ]] || { echo "Каталог установки не должен совпадать с каталогом исходников"; exit 1; }
if [[ -L "$APP_DIR" ]]; then echo "Установка в симлинк запрещена"; exit 1; fi
case "$APP_DIR" in
  /opt/*|/srv/*|/var/lib/*) ;;
  *) echo "Каталог установки должен находиться под /opt, /srv или /var/lib (systemd ProtectHome)"; exit 1;;
esac
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
if [[ -f "$APP_DIR/.env" ]]; then
  EXISTING=1
elif [[ -e "$APP_DIR" ]]; then
  echo "Каталог приложения уже существует без конфигурации .env; автоматическое обновление запрещено."
  exit 1
fi
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
# On an existing server, a non-standard public TLS port must be free or already owned by nginx.
if [[ "$PROXY_MODE" == "apache-existing" || "$PROXY_MODE" == "caddy-existing" ]] && [[ "$EXTERNAL_PORT" != 443 ]]; then
  echo "Для существующих Apache/Caddy автоматическая интеграция поддерживает внешний 443. Выберите manual для другого порта."; exit 1
fi
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
  ask EMAIL "Email Let's Encrypt" "${WA_REC_EMAIL:-}"
  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "Некорректный email"; exit 1; }
  ask ACME_DIR "Каталог ACME" "${WA_REC_ACME_DIR:-/var/www/letsencrypt}"
  [[ "$ACME_DIR" = /* && "$ACME_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo "Некорректный каталог"; exit 1; }
fi
if [[ "$EXISTING" -eq 1 ]]; then
  ask BACKUP_DIR "Каталог резервных копий" "${WA_REC_BACKUP_DIR:-/root/whatsapp-translator-backups}"
  [[ "$BACKUP_DIR" = /* ]] || { echo "Каталог должен быть абсолютным"; exit 1; }
  echo "Старые .env, WhatsApp-сессия, БД и медиа будут сохранены."
else
  read -rsp "Пароль веб-интерфейса (не менее 6 символов): " PASSWORD; echo
  [[ "${#PASSWORD}" -ge 6 ]] || { echo "Пароль должен содержать минимум 6 символов"; exit 1; }
  # Ключ намеренно вводится ВИДИМО: вставка из буфера через Ctrl+Shift+V/правую кнопку.
  # Не печатать ключ повторно, не включать shell xtrace, не сохранять в отчёт аудита.
  read -rp "Вставьте ключ Groq (ввод виден на экране, gsk_...): " GROQ
  [[ "$GROQ" =~ ^gsk_[-_a-zA-Z0-9]+$ ]] || { echo "Некорректный формат ключа Groq"; exit 1; }
  ask GROQ_MODEL "Модель Groq" "${WA_REC_MODEL:-openai/gpt-oss-120b}"
  ask TARGET_LANG "Язык собеседников по умолчанию" "${WA_REC_LANGUAGE:-Montenegrin (Latin script, Ijekavian)}"
  [[ "$GROQ_MODEL" =~ ^[a-zA-Z0-9_./-]+$ && "$TARGET_LANG" =~ ^[a-zA-Z0-9.,\ \(\)-]+$ ]] || { echo "Некорректные настройки языка или модели"; exit 1; }
  ask MAX_IMAGE "Лимит одного фото, МБ" "${WA_REC_MAX_IMAGE:-8}"
  ask MAX_MEDIA "Общая квота фото, МБ" "${WA_REC_MEDIA_TOTAL:-512}"
  [[ "$MAX_IMAGE" =~ ^[0-9]+$ && "$MAX_MEDIA" =~ ^[0-9]+$ ]] || { echo "Лимиты должны быть целыми числами"; exit 1; }
  (( MAX_IMAGE >= 1 && MAX_IMAGE <= 32 && MAX_MEDIA >= MAX_IMAGE && MAX_MEDIA <= 10000 )) || { echo "Лимиты должны быть в диапазоне 1–32 МБ и от размера файла до 10000 МБ"; exit 1; }
fi

echo
echo "==== ПЛАН ИЗМЕНЕНИЙ ===="
printf 'Каталог: %s\nSystemd: %s\nПользователь: %s\nВнутренний порт: 127.0.0.1:%s\nВнешний HTTPS-порт: %s\nДомен: %s\nРеверс-прокси: %s\n' "$APP_DIR" "$SERVICE" "$APPUSER" "$PORT" "$EXTERNAL_PORT" "$DOMAIN" "$PROXY_MODE"
echo "Установятся необходимые пакеты/Node.js, приложение и systemd. Файрвол не меняется."
if [[ "$PROXY_MODE" == *-existing ]]; then
  echo "После установки будет запрошено отдельное подтверждение INTEGRATE."
  echo "Nginx/Apache: только отдельный сайт с подходящим действующим TLS-сертификатом."
  echo "Caddy: отдельный сайт со штатным управлением сертификатами."
  echo "Перед изменениями создаётся резервная копия затрагиваемого файла и выполняется проверка/откат."
fi
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

# Transactional application/vhost rollback after confirmation.
# Does not roll back already-installed system packages; report this honestly.
FREE_MB="$(df -Pm "$(dirname "$APP_DIR")" | awk 'END {print $4}')"
if [[ -z "$FREE_MB" || "$FREE_MB" -lt 2048 ]]; then
  echo "Свободное место менее 2 ГБ. Установка остановлена без изменения приложения."
  exit 1
fi
TXN="$(mktemp -d /root/whatsapp-translator-rollback.XXXXXXXX)"
TXN_COMMITTED=0
HAD_UNIT=0
WAS_ACTIVE=0
HAD_NGINX_SITE=0
HAD_NGINX_LINK=0
[[ -f "/etc/systemd/system/$SERVICE.service" ]] && HAD_UNIT=1
if [[ "$HAD_UNIT" -eq 1 ]]; then
  cp -a "/etc/systemd/system/$SERVICE.service" "$TXN/service.unit"
  if systemctl is-active --quiet "$SERVICE.service"; then WAS_ACTIVE=1; fi
fi
if [[ "$EXISTING" -eq 1 ]]; then
  mkdir "$TXN/app"
  echo "Резервируем предыдущую версию приложения для автоматического отката..."
  rsync -a --exclude='.data/' "$APP_DIR/" "$TXN/app/"
fi
if [[ "$PROXY_MODE" == nginx ]]; then
  if [[ -e "$NGINX_SITE" ]]; then
    HAD_NGINX_SITE=1
    cp -a "$NGINX_SITE" "$TXN/nginx-site.conf"
  fi
  if [[ -L "/etc/nginx/sites-enabled/$SERVICE.conf" ]]; then
    HAD_NGINX_LINK=1
    cp -a --no-dereference "/etc/nginx/sites-enabled/$SERVICE.conf" "$TXN/nginx-link.conf"
  fi
fi
rollback_install() {
  local status=$?
  trap - EXIT
  if [[ "$TXN_COMMITTED" -ne 1 ]]; then
    echo "Установка прервана — восстанавливаем предыдущую версию приложения и конфигурацию." >&2
    systemctl stop "$SERVICE.service" >/dev/null 2>&1 || :
    if [[ "$EXISTING" -eq 1 ]]; then
      mkdir -p "$APP_DIR"
      rsync -a --delete --exclude='.data/' "$TXN/app/" "$APP_DIR/" || :
    else
      # Deletion limited to the validated new installation directory.
      rm -rf -- "$APP_DIR" || :
    fi
    if [[ "$HAD_UNIT" -eq 1 ]]; then
      cp -a "$TXN/service.unit" "/etc/systemd/system/$SERVICE.service" || :
    else
      rm -f "/etc/systemd/system/$SERVICE.service" || :
    fi
    systemctl daemon-reload || :
    if [[ "$HAD_UNIT" -eq 1 && "$WAS_ACTIVE" -eq 1 ]]; then
      systemctl start "$SERVICE.service" || :
    fi
    if [[ "$PROXY_MODE" == nginx ]]; then
      if [[ "$HAD_NGINX_SITE" -eq 1 ]]; then
        cp -a "$TXN/nginx-site.conf" "$NGINX_SITE" || :
      else
        rm -f "$NGINX_SITE" || :
      fi
      if [[ "$HAD_NGINX_LINK" -eq 1 ]]; then
        cp -a --no-dereference "$TXN/nginx-link.conf" "/etc/nginx/sites-enabled/$SERVICE.conf" || :
      else
        rm -f "/etc/nginx/sites-enabled/$SERVICE.conf" || :
      fi
      if command -v nginx >/dev/null 2>&1; then nginx -t && systemctl reload nginx || :; fi
    fi
    echo "Данные WhatsApp и .data не удалялись при обновлении. Системные пакеты остаются обновлёнными." >&2
  fi
  rm -rf -- "$TXN" || :
  exit "$status"
}
trap rollback_install EXIT
if [[ "$EXISTING" -eq 1 ]]; then
  systemctl stop "$SERVICE.service" || :
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
  : # При обновлении сохранённый .env не меняется.
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
# Refuse to mark install successful if the app did not start or its local API is broken.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet "$SERVICE.service" &&
     curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 10 ]]; then
    echo "WhatsApp Translator service failed health checks"
    exit 1
  fi
  sleep 2
done

install -d -m 750 "$APP_DIR/deploy-examples"
cat > "$APP_DIR/deploy-examples/nginx-example.conf" <<CONF
# Пример для ручной настройки существующего Nginx. Нужен действующий HTTPS.
server {
    listen $EXTERNAL_PORT ssl;
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
  REDIRECT_PORT=""
  if [[ "$EXTERNAL_PORT" != 443 ]]; then REDIRECT_PORT=":$EXTERNAL_PORT"; fi
  cat > "$NGINX_SITE" <<CONF
# Configured by WhatsApp Translator deploy.sh
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { return 301 https://\$host$REDIRECT_PORT\$request_uri; }
}
server {
    listen $EXTERNAL_PORT ssl;
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
  if [[ "$EXTERNAL_PORT" == 443 ]]; then echo "Готово: https://$DOMAIN"; else echo "Готово: https://$DOMAIN:$EXTERNAL_PORT"; fi
elif [[ "$PROXY_MODE" == *-existing ]]; then
  echo "Подключаем к уже работающему HTTPS-серверу; все изменения требуют подтверждения."
  if ! bash "$SRC/integrate-existing.sh" "$PROXY_MODE" "$DOMAIN" "$PORT" "$SERVICE" "$EXTERNAL_PORT"; then
    echo "HTTPS-интеграция не выполнена. Сервис остаётся доступным только локально."
    echo "Ни один существующий сайт не должен оставаться изменённым после ошибки."
    echo "Для ручной конфигурации: $APP_DIR/deploy-examples/nginx-example.conf"
    exit 1
  fi
else
  echo "Приложение запущено локально. Подключите существующий HTTPS reverse-proxy:"
  echo "$APP_DIR/deploy-examples/nginx-example.conf"
fi
echo "Служба: systemctl status $SERVICE"
echo "Журнал: journalctl -u $SERVICE -n 100 --no-pager"
TXN_COMMITTED=1
echo
echo "=== Финальная диагностика ==="
if ! runuser -u "$APPUSER" -- env HOME="$APP_DIR" sh -c 'cd "$1" && npm run doctor' sh "$APP_DIR"; then
  echo "ВНИМАНИЕ: диагностика Groq/API или ресурсов выявила проблему."
  echo "Служба установлена, но перевод может быть недоступен. Исправьте проблему и повторите npm run doctor."
fi
