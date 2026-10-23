#!/usr/bin/env bash
# Обновление существующей инсталляции без изменения TLS, .env и WhatsApp-сессии.
set -Eeuo pipefail
umask 077
[[ "$(id -u)" -eq 0 ]] || { echo "Запускайте через sudo bash"; exit 1; }
RESET_CONTACTS=0
if [[ "${1:-}" == "--reset-contacts" ]]; then
  RESET_CONTACTS=1
  shift
fi
APP_DIR="/opt/whatsapp-translator"
SERVICE="whatsapp-translator"
if [[ $# -ge 1 ]]; then APP_DIR="$1"; fi
if [[ $# -ge 2 ]]; then SERVICE="$2"; fi
[[ "$APP_DIR" =~ ^/(opt|srv|var/lib)/[a-zA-Z0-9_./-]+$ && "$APP_DIR" != *..* ]] || { echo "Неверный каталог"; exit 1; }
[[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Неверная служба"; exit 1; }
[[ -f "$APP_DIR/server.mjs" && -f "$APP_DIR/package.json" && -f "$APP_DIR/.env" && -d "$APP_DIR/.data" ]] || {
  echo "Не найдена существующая установка"; exit 1;
}
[[ ! -L "$APP_DIR" ]] || { echo "Ссылка в качестве каталога запрещена"; exit 1; }
for tool in curl tar rsync node systemctl; do command -v "$tool" >/dev/null || exit 1; done
SERVICE_USER="$(systemctl show "$SERVICE.service" -p User --value)"
[[ -n "$SERVICE_USER" && "$SERVICE_USER" != root ]] || { echo "Не найден непривилегированный пользователь службы"; exit 1; }
[[ "$(systemctl show "$SERVICE.service" -p WorkingDirectory --value)" == "$APP_DIR" ]] || {
  echo "Имя службы не соответствует выбранному каталогу"; exit 1;
}
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
PORT="$(sed -n 's/^PORT=//p' "$APP_DIR/.env" | tail -n 1)"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Неверный порт приложения"; exit 1; }
NGINX_SITE="/etc/nginx/sites-available/$SERVICE.conf"
NGINX_OWNED=0
CURRENT_PUBLIC_PORT=443
if [[ -f "$NGINX_SITE" ]] &&
   { grep -Fq '# Configured by WhatsApp Translator deploy.sh' "$NGINX_SITE" ||
     grep -Fq '# WhatsApp Translator: отдельный сайт' "$NGINX_SITE"; }; then
  NGINX_OWNED=1
  CURRENT_PUBLIC_PORT="$(sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)[[:space:]]+ssl;.*/\1/p' "$NGINX_SITE" | head -n 1)"
  [[ "$CURRENT_PUBLIC_PORT" =~ ^[0-9]+$ ]] || { echo "Не удалось определить внешний порт Nginx"; exit 1; }
fi
read -rp "Внешний HTTPS-порт [$CURRENT_PUBLIC_PORT]: " NEW_PUBLIC_PORT
NEW_PUBLIC_PORT="${NEW_PUBLIC_PORT:-$CURRENT_PUBLIC_PORT}"
[[ "$NEW_PUBLIC_PORT" =~ ^[0-9]+$ ]] || { echo "Неверный внешний порт"; exit 1; }
(( 10#$NEW_PUBLIC_PORT > 0 && 10#$NEW_PUBLIC_PORT < 65536 )) || { echo "Порт 1–65535"; exit 1; }
NEW_PUBLIC_PORT="$((10#$NEW_PUBLIC_PORT))"
[[ "$NEW_PUBLIC_PORT" != "$PORT" ]] || { echo "Внешний и внутренний порты не должны совпадать"; exit 1; }
[[ "$NEW_PUBLIC_PORT" != 80 ]] || { echo "Внешний HTTPS-порт 80 занят HTTP/ACME"; exit 1; }
if [[ "$NEW_PUBLIC_PORT" != "$CURRENT_PUBLIC_PORT" ]]; then
  [[ "$NGINX_OWNED" -eq 1 ]] || { echo "Автосмена внешнего порта работает только для vhost Nginx установщика"; exit 1; }
  LISTENERS="$(ss -H -ltnp "( sport = :$NEW_PUBLIC_PORT )" || :)"
  if [[ -n "$LISTENERS" ]] && printf '%s\n' "$LISTENERS" | grep -v '"nginx"' | grep -q .; then
    echo "Новый внешний порт занят другим процессом"; exit 1
  fi
  echo "Внешний HTTPS-порт будет изменён на $NEW_PUBLIC_PORT (для доступа откройте TCP-порт в файрволе)."
fi

WORK="$(mktemp -d /root/wa-upgrade.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
install -d -m 700 "$WORK/source" "$WORK/previous"
echo "Загрузка исправленной версии из GitHub..."
curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 120 \
  https://codeload.github.com/Alex66166/Whatsapp-translator/tar.gz/refs/heads/main \
  -o "$WORK/archive.tar.gz"
tar -tzf "$WORK/archive.tar.gz" >/dev/null
tar -xzf "$WORK/archive.tar.gz" --strip-components=1 -C "$WORK/source"
for required in server.mjs public/index.html public/app.js package.json; do
  [[ -f "$WORK/source/$required" ]] || { echo "В архиве отсутствует $required"; exit 1; }
done
node --check "$WORK/source/server.mjs"
node --check "$WORK/source/public/app.js"
node --check "$WORK/source/lib/translate.mjs"
OLD_DEPS="$(node -e 'console.log(JSON.stringify(require(process.argv[1]).dependencies))' "$APP_DIR/package.json")"
NEW_DEPS="$(node -e 'console.log(JSON.stringify(require(process.argv[1]).dependencies))' "$WORK/source/package.json")"
rsync -a --exclude='.env' --exclude='.data/' --exclude='node_modules/' "$APP_DIR/" "$WORK/previous/"
if [[ "$NGINX_OWNED" -eq 1 ]]; then cp -a "$NGINX_SITE" "$WORK/nginx.conf"; fi
WAS_ACTIVE=0
if systemctl is-active --quiet "$SERVICE.service"; then WAS_ACTIVE=1; fi
CHANGED=0
OK=0
rollback() {
  status=$?
  trap - EXIT
  if [[ "$CHANGED" -eq 1 && "$OK" -ne 1 ]]; then
    echo "Обновление не прошло: восстанавливаем прежний код." >&2
    rsync -a --delete --exclude='.env' --exclude='.data/' --exclude='node_modules/' \
      "$WORK/previous/" "$APP_DIR/" || :
    if [[ -f "$WORK/nginx.conf" ]]; then
      cp -a "$WORK/nginx.conf" "$NGINX_SITE" || :
      if command -v nginx >/dev/null 2>&1; then nginx -t && systemctl reload nginx || :; fi
    fi
    if [[ "$WAS_ACTIVE" -eq 1 ]]; then systemctl restart "$SERVICE.service" || :; fi
    echo "Настройки, сессия WhatsApp, база, фотографии и сертификаты не удалялись." >&2
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap rollback EXIT
systemctl stop "$SERVICE.service"
CHANGED=1
rsync -a --chown="$SERVICE_USER:$SERVICE_GROUP" \
  --exclude='.env' --exclude='.data/' --exclude='node_modules/' \
  "$WORK/source/" "$APP_DIR/"
if [[ "$OLD_DEPS" != "$NEW_DEPS" ]]; then
  runuser -u "$SERVICE_USER" -- env HOME="$APP_DIR" sh -c \
    'cd "$1" && npm install --omit=dev --no-audit --no-fund' sh "$APP_DIR"
fi
runuser -u "$SERVICE_USER" -- env HOME="$APP_DIR" sh -c \
  'cd "$1" && npm run check' sh "$APP_DIR"
systemctl start "$SERVICE.service"
if [[ "$NGINX_OWNED" -eq 1 ]] &&
   { [[ "$NEW_PUBLIC_PORT" != "$CURRENT_PUBLIC_PORT" ]] || grep -Fq 'client_max_body_size 32k;' "$NGINX_SITE"; }; then
  python3 "$WORK/source/tools/change-nginx-port.py" "$NGINX_SITE" "$CURRENT_PUBLIC_PORT" "$NEW_PUBLIC_PORT"
  nginx -t
  systemctl reload nginx
fi
for count in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet "$SERVICE.service" &&
    curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    OK=1
    break
  fi
  sleep 2
done
[[ "$OK" -eq 1 ]] || { echo "Приложение не прошло проверку HTTP"; exit 1; }
if [[ "$RESET_CONTACTS" -eq 1 ]]; then
  echo "Применяем однократный сброс старого кэша контактов..."
  bash "$APP_DIR/reset-contacts.sh" "$APP_DIR" "$SERVICE"
fi
if [[ "$NEW_PUBLIC_PORT" -eq 443 ]]; then
  echo "Обновлено. Открой прежний HTTPS-домен и обнови страницу Ctrl+F5."
else
  echo "Обновлено. Новый внешний HTTPS-порт: $NEW_PUBLIC_PORT (https://ваш-домен:$NEW_PUBLIC_PORT)."
fi
