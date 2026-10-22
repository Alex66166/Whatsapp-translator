#!/usr/bin/env bash
# Безопасная интеграция с действующим HTTPS-сервером: без замены его конфигурации.
# Вызывается deploy.sh ПОСЛЕ отдельного подтверждения установки.
set -Eeuo pipefail
umask 077
[[ "$(id -u)" -eq 0 ]] || { echo "Требуются права root"; exit 1; }
[[ "$#" -eq 4 ]] || { echo "Аргументы: тип_сервера домен порт имя_службы"; exit 1; }
TYPE="$1"; DOMAIN="$2"; PORT="$3"; SERVICE="$4"
[[ "$TYPE" =~ ^(nginx-existing|apache-existing|caddy-existing)$ ]] || exit 1
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ && "$DOMAIN" == *.* ]] || exit 1
[[ "$PORT" =~ ^[0-9]+$ && "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 1
command -v openssl >/dev/null || { echo "openssl отсутствует"; exit 1; }

# Запоминаем оригинал изменяемого файла ВНЕ директории веб-сервера.
BKDIR=/root/whatsapp-translator-config-backups
install -d -m 700 "$BKDIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIGINAL=""
FILE=""
LINK=""
HAD_FILE=0
HAD_LINK=0
CHANGED=0
COMPLETED=0

rollback() {
  if [[ "$CHANGED" -ne 1 || "$COMPLETED" -eq 1 ]]; then return; fi
  echo "ОШИБКА: восстанавливаем исходную конфигурацию веб-сервера." >&2
  if [[ "$HAD_FILE" -eq 1 ]]; then
    cp -a "$ORIGINAL" "$FILE" || :
  else
    rm -f "$FILE" || :
  fi
  if [[ -n "$LINK" && "$HAD_LINK" -eq 0 ]]; then rm -f "$LINK" || :; fi
  case "$TYPE" in
    nginx-existing) nginx -t && systemctl reload nginx || : ;;
    apache-existing)
      if [[ "$HAD_LINK" -eq 0 ]]; then a2dissite "$SERVICE.conf" >/dev/null 2>&1 || :; fi
      apache2ctl configtest && systemctl reload apache2 || :
      ;;
    caddy-existing) caddy validate --config "$FILE" --adapter caddyfile && systemctl reload caddy || : ;;
  esac
}
trap rollback EXIT

check_cert_pair() {
  local cert="$1" key="$2" one two
  [[ "$cert" = /* && "$key" = /* && -f "$cert" && -f "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" 2>/dev/null | grep -qi 'does match' || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  one="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)" || return 1
  two="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)" || return 1
  [[ -n "$one" && "$one" == "$two" ]]
}
select_certificate() {
  CERT=""; KEY=""
  echo
  echo "=== Проверка существующего TLS-сертификата для $DOMAIN ==="
  for c in /etc/letsencrypt/live/*/fullchain.pem; do
    [[ -f "$c" ]] || continue
    local_key="$(dirname "$c")/privkey.pem"
    if check_cert_pair "$c" "$local_key"; then
      CERT="$c"; KEY="$local_key"
      break
    fi
  done
  if [[ -n "$CERT" ]]; then
    echo "Найден действующий сертификат, покрывающий $DOMAIN:"
    echo "  $CERT"
    read -rp "Использовать его? [Y/n]: " CHOICE
    if [[ "$CHOICE" =~ ^([nN]|[Нн])$ ]]; then CERT=""; KEY=""; fi
  fi
  if [[ -z "$CERT" ]]; then
    echo "Сертификат в стандартном каталоге Let's Encrypt не найден или отклонён."
    echo "Можно указать существующие PEM-файлы другого поставщика."
    echo "Если сертификат НЕ покрывает $DOMAIN, режим интеграции не будет применён."
    read -rp "Абсолютный путь к fullchain/cert PEM: " CERT
    read -rp "Абсолютный путь к приватному ключу PEM: " KEY
  fi
  if ! check_cert_pair "$CERT" "$KEY"; then
    echo "Сертификат просрочен/не подходит для домена либо не совпадает с ключом."
    echo "Конфигурация существующего сервера НЕ ИЗМЕНЕНА."
    return 1
  fi
  echo "Сертификат проверен: срок действия, домен и соответствие ключу."
}
make_backup() {
  FILE="$1"
  [[ ! -L "$FILE" ]] || { echo "Ссылка вместо конфигурационного файла: отказ"; exit 1; }
  if [[ -e "$FILE" ]]; then
    HAD_FILE=1
    ORIGINAL="$BKDIR/$SERVICE-$STAMP.conf"
    cp -a "$FILE" "$ORIGINAL"
    chmod 600 "$ORIGINAL"
    echo "Резервная копия: $ORIGINAL"
  fi
}
verify_domain_unclaimed_nginx() {
  local dumped
  dumped="$(mktemp)"
  if ! nginx -T > "$dumped" 2>&1; then cat "$dumped" >&2; rm -f "$dumped"; return 1; fi
  # Никакой новый virtual host не должен перехватить уже заявленный домен.
  if grep -E '^[[:space:]]*server_name[[:space:]]+' "$dumped" | grep -E "(^|[[:space:]])$DOMAIN([[:space:];]|$)" >/dev/null; then
    echo "Домен уже указан в Nginx (возможно, существующий сайт). Автодобавление запрещено."
    rm -f "$dumped"; return 1
  fi
  rm -f "$dumped"
}

case "$TYPE" in
  nginx-existing)
    systemctl is-active --quiet nginx || { echo "Nginx не работает"; exit 1; }
    [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]] || { echo "Нет стандартных каталогов Nginx"; exit 1; }
    FILE="/etc/nginx/sites-available/$SERVICE.conf"
    LINK="/etc/nginx/sites-enabled/$SERVICE.conf"
    [[ ! -e "$FILE" && ! -L "$FILE" && ! -e "$LINK" && ! -L "$LINK" ]] || {
      echo "Конфигурация с этим именем уже существует. Чтобы исключить перезапись, выбери другой режим/имя."; exit 1;
    }
    verify_domain_unclaimed_nginx
    select_certificate
    echo "Будет создан ТОЛЬКО новый Nginx vhost для $DOMAIN."
    read -rp "Подтвердите создание vhost и reload Nginx словом INTEGRATE: " OK
    [[ "$OK" == INTEGRATE ]] || { echo "Отменено"; exit 1; }
    make_backup "$FILE"
    CHANGED=1
    cat > "$FILE" <<CONF
# WhatsApp Translator: отдельный сайт, существующие конфигурации не меняются
server {
  listen 443 ssl;
  server_name $DOMAIN;
  ssl_certificate $CERT;
  ssl_certificate_key $KEY;
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
    ln -s "$FILE" "$LINK"
    nginx -t
    systemctl reload nginx
    ;;
  apache-existing)
    systemctl is-active --quiet apache2 || { echo "Apache2 не работает"; exit 1; }
    [[ -d /etc/apache2/sites-available && -d /etc/apache2/sites-enabled ]] || { echo "Нет стандартных каталогов Apache"; exit 1; }
    FILE="/etc/apache2/sites-available/$SERVICE.conf"
    LINK="/etc/apache2/sites-enabled/$SERVICE.conf"
    [[ ! -e "$FILE" && ! -L "$FILE" && ! -e "$LINK" && ! -L "$LINK" ]] || {
      echo "Сайт с таким именем уже существует. Не перезаписываем."; exit 1;
    }
    for module in ssl_module proxy_module proxy_http_module; do
      apache2ctl -M 2>/dev/null | grep -q "$module" || {
        echo "Apache-модуль $module не загружен. Автоматически менять глобальные модули не будем."; exit 1;
      }
    done
    if apache2ctl -S 2>&1 | grep -F "$DOMAIN" | grep -q .; then
      echo "Домен уже обслуживается Apache. Автоматическое добавление запрещено."; exit 1;
    fi
    select_certificate
    echo "Будет создан только новый Apache VirtualHost для $DOMAIN."
    read -rp "Подтвердите создание VirtualHost и reload Apache словом INTEGRATE: " OK
    [[ "$OK" == INTEGRATE ]] || { echo "Отменено"; exit 1; }
    make_backup "$FILE"
    CHANGED=1
    cat > "$FILE" <<CONF
# WhatsApp Translator: отдельный VirtualHost
<VirtualHost *:443>
  ServerName $DOMAIN
  SSLEngine on
  SSLCertificateFile "$CERT"
  SSLCertificateKeyFile "$KEY"
  ProxyPreserveHost On
  ProxyPass / http://127.0.0.1:$PORT/
  ProxyPassReverse / http://127.0.0.1:$PORT/
  RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
CONF
    # RequestHeader доступен только при mod_headers; убираем строку, если модуль отсутствует.
    if ! apache2ctl -M 2>/dev/null | grep -q headers_module; then
      sed -i '/RequestHeader set X-Forwarded-Proto/d' "$FILE"
    fi
    a2ensite "$SERVICE.conf"
    apache2ctl configtest
    systemctl reload apache2
    ;;
  caddy-existing)
    systemctl is-active --quiet caddy || { echo "Caddy не работает"; exit 1; }
    command -v caddy >/dev/null || exit 1
    FILE="/etc/caddy/Caddyfile"
    # Не меняем Caddyfile, если systemd запускает Caddy с альтернативным конфигом.
    if ! systemctl show -p ExecStart --value caddy | grep -F '/etc/caddy/Caddyfile' >/dev/null; then
      echo "Не удалось подтвердить, что Caddy использует /etc/caddy/Caddyfile: ручной режим."; exit 1
    fi
    [[ -f "$FILE" && ! -L "$FILE" ]] || { echo "Caddyfile отсутствует или является ссылкой"; exit 1; }
    caddy validate --config "$FILE" --adapter caddyfile || exit 1
    if grep -F "$DOMAIN" "$FILE" | grep -q .; then
      echo "Этот домен уже встречается в Caddyfile. Не изменяем существующий сайт."; exit 1;
    fi
    echo "Caddy управляет HTTPS самостоятельно. Добавится отдельный сайт $DOMAIN."
    echo "Новый сертификат при необходимости получает сам Caddy; доступность DNS/ACME обязательна."
    read -rp "Подтвердите добавление в Caddyfile и reload Caddy словом INTEGRATE: " OK
    [[ "$OK" == INTEGRATE ]] || { echo "Отменено"; exit 1; }
    make_backup "$FILE"
    CHANGED=1
    cat >> "$FILE" <<CONF

# BEGIN WhatsApp Translator $SERVICE
$DOMAIN {
  reverse_proxy 127.0.0.1:$PORT
}
# END WhatsApp Translator $SERVICE
CONF
    caddy validate --config "$FILE" --adapter caddyfile
    systemctl reload caddy
    ;;
esac
COMPLETED=1
echo "ИНТЕГРАЦИЯ ЗАВЕРШЕНА: https://$DOMAIN"
echo "Существующие сайты не редактировались. Сделайте запрос к веб-клиенту и проверьте сертификат снаружи."
