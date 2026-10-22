#!/usr/bin/env bash
# Восстановление из проверенной шифрованной копии.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Нужно запустить от root"; exit 1; }
read -rp "Полный путь установленного приложения: " APP_DIR
read -rp "Имя systemd-службы приложения: " SERVICE
read -rp "Полный путь к файлу .tar.gz.enc: " ARCHIVE
[[ "$APP_DIR" = /* && "$ARCHIVE" = /* ]] || { echo "Нужны абсолютные пути"; exit 1; }
[[ "$SERVICE" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { echo "Неверное имя службы"; exit 1; }
[[ -d "$APP_DIR" && -f "$APP_DIR/server.mjs" && -f "$ARCHIVE" ]] || { echo "Не найдено приложение или архив"; exit 1; }
APP_DIR="$(readlink -f "$APP_DIR")"
ARCHIVE="$(readlink -f "$ARCHIVE")"
umask 077
STAGE="$(mktemp -d /root/wa-restore.XXXXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
read -rsp "Пароль шифрования резервной копии: " PASSWORD; echo
echo "Проверяем архив перед остановкой приложения..."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -pass fd:3 -in "$ARCHIVE" -out "$STAGE/restore.tar.gz" 3<<<"$PASSWORD"
unset PASSWORD
# Не позволяем архиву содержать неожиданные пути и симлинки.
while IFS= read -r NAME; do
  case "$NAME" in
    .env|.data|.data/*) ;;
    *) echo "Неожиданный путь в архиве: $NAME"; exit 1;;
  esac
  [[ "$NAME" != *".."* && "$NAME" != *"//"* && "$NAME" != /* ]] || { echo "Недопустимый путь в архиве"; exit 1; }
done < <(tar -tzf "$STAGE/restore.tar.gz")
if tar -tvzf "$STAGE/restore.tar.gz" | grep -Eq '^[lbcps]'; then
  echo "Архив содержит ссылки или спецфайлы; восстановление запрещено"
  exit 1
fi
tar -xzf "$STAGE/restore.tar.gz" -C "$STAGE" --no-same-owner --no-same-permissions
[[ -f "$STAGE/.env" && -d "$STAGE/.data" ]] || { echo "Неполная резервная копия"; exit 1; }
echo "ВНИМАНИЕ: текущие .env, SQLite, ключи WhatsApp и изображения будут заменены."
echo "Рекомендуется сначала отдельно создать резервную копию текущего состояния."
read -rp "Для продолжения наберите RESTORE: " APPROVE
[[ "$APPROVE" == "RESTORE" ]] || { echo "Отменено"; exit 1; }
RUN_USER="$(systemctl show "$SERVICE.service" --property=User --value)"
[[ -n "$RUN_USER" ]] || { echo "У службы нет системного пользователя"; exit 1; }
systemctl stop "$SERVICE.service"
install -m 600 "$STAGE/.env" "$APP_DIR/.env"
mkdir -p -m 700 "$APP_DIR/.data"
rsync -a --delete "$STAGE/.data/" "$APP_DIR/.data/"
chown -R "$RUN_USER" "$APP_DIR/.data" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
systemctl start "$SERVICE.service"
systemctl --no-pager status "$SERVICE.service" || :
echo "Восстановление выполнено. Проверьте подключение WhatsApp в браузере."
