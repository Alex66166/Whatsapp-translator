#!/usr/bin/env bash
# Clear cached WhatsApp contact names/recency, without touching credentials,
# locally translated messages or photos. Run after upgrading the app.
set -Eeuo pipefail
umask 077
APP_DIR="${1:-/opt/whatsapp-translator}"
SERVICE="${2:-whatsapp-translator}"

[[ "$(id -u)" -eq 0 ]] || { echo "Запустите через sudo bash"; exit 1; }
[[ "$APP_DIR" =~ ^/(opt|srv|var/lib)/[a-zA-Z0-9_./-]+$ && "$APP_DIR" != *..* && ! -L "$APP_DIR" ]] || {
  echo "Недопустимый каталог установки"; exit 1;
}
[[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Недопустимое имя службы"; exit 1; }
[[ -f "$APP_DIR/.env" && -f "$APP_DIR/tools/reset-contact-cache.mjs" ]] || {
  echo "Не найден обновлённый WhatsApp Translator с функцией сброса контактов"; exit 1;
}
[[ "$(systemctl show "$SERVICE.service" -p WorkingDirectory --value)" == "$APP_DIR" ]] || {
  echo "Служба не соответствует каталогу приложения"; exit 1;
}
SERVICE_USER="$(systemctl show "$SERVICE.service" -p User --value)"
[[ -n "$SERVICE_USER" && "$SERVICE_USER" != root ]] || {
  echo "Служба не имеет безопасного непривилегированного пользователя"; exit 1;
}
WAS_ACTIVE=0
if systemctl is-active --quiet "$SERVICE.service"; then WAS_ACTIVE=1; fi
restart() {
  result=$?
  trap - EXIT
  if [[ "$WAS_ACTIVE" -eq 1 ]]; then systemctl start "$SERVICE.service" || result=1; fi
  exit "$result"
}
trap restart EXIT

# Stop writes and release the SQLite WAL before changing stored metadata.
systemctl stop "$SERVICE.service"
echo "Очищаем кэш контактов; WhatsApp-авторизацию и тексты сообщений не трогаем..."
runuser -u "$SERVICE_USER" -- env HOME="$APP_DIR" sh -c   'cd "$1" && node tools/reset-contact-cache.mjs' sh "$APP_DIR"
echo "Готово. После запуска службы экран начнётся с пустого списка."
echo "Внимание: повторная передача метаданных последних 20 чатов зависит от WhatsApp."
