#!/usr/bin/env bash
# Зашифрованная копия настроек, сессии WhatsApp, БД и фотографий.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Нужно запустить от root"; exit 1; }
if [[ "$#" -ge 1 ]]; then SOURCE_DIR="$1"; else read -rp "Полный путь установленного приложения: " SOURCE_DIR; fi
if [[ "$#" -ge 2 ]]; then BACKUP_DIR="$2"; else read -rp "Каталог для резервных копий (ВНЕ каталога приложения): " BACKUP_DIR; fi
[[ "$SOURCE_DIR" = /* && "$BACKUP_DIR" = /* ]] || { echo "Нужны абсолютные пути"; exit 1; }
SOURCE_DIR="$(readlink -f "$SOURCE_DIR")"
mkdir -p -m 700 "$BACKUP_DIR"
BACKUP_DIR="$(readlink -f "$BACKUP_DIR")"
[[ "$BACKUP_DIR/" != "$SOURCE_DIR/"* && "$SOURCE_DIR/" != "$BACKUP_DIR/"* ]] || { echo "Каталог копий не должен находиться внутри приложения"; exit 1; }
[[ -f "$SOURCE_DIR/.env" && -d "$SOURCE_DIR/.data" ]] || { echo "Отсутствует .env или .data — сохранять нечего"; exit 1; }
if [[ "$#" -ge 3 ]]; then SERVICE_NAME="$3"; else read -rp "Имя systemd-службы (Enter = пропустить остановку; не рекомендуется при активной БД): " SERVICE_NAME; fi
[[ -z "$SERVICE_NAME" || "$SERVICE_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { echo "Недопустимое имя службы"; exit 1; }
umask 077
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="$BACKUP_DIR/wa-backup-$STAMP.tar.gz.enc"
[[ ! -e "$ARCHIVE" ]] || { echo "Копия с такой датой уже существует"; exit 1; }
echo "Резервная копия: $ARCHIVE"
echo "Будут включены .env, авторизация WhatsApp, SQLite и фотографии."
echo "Пароль шифрования нельзя восстановить. Не храните единственную копию на том же VPS."
read -rsp "Пароль шифрования (не менее 12 символов): " PASSWORD; echo
[[ "$(printf '%s' "$PASSWORD" | wc -c)" -ge 12 ]] || { echo "Пароль слишком короткий"; exit 1; }
read -rsp "Повторите пароль: " CHECK; echo
[[ "$PASSWORD" == "$CHECK" ]] || { echo "Пароли не совпадают"; exit 1; }
unset CHECK
STOPPED=0
restart_if_stopped() {
  if [[ "$STOPPED" -eq 1 ]]; then
    echo "Перезапуск службы после резервного копирования..."
    systemctl start "$SERVICE_NAME.service" || :
  fi
}
trap restart_if_stopped EXIT
if [[ -n "$SERVICE_NAME" ]] && systemctl is-active --quiet "$SERVICE_NAME.service"; then
  echo "Временная остановка службы для согласованной копии SQLite"
  systemctl stop "$SERVICE_NAME.service"
  STOPPED=1
fi
# Потоковое шифрование без создания открытого tar на диске.
# fd 3 передаёт пароль, stdin содержит поток архива.
if tar -C "$SOURCE_DIR" -czf - .env .data | openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -pass fd:3 -out "$ARCHIVE" 3<<<"$PASSWORD"; then
  chmod 600 "$ARCHIVE"
else
  rm -f "$ARCHIVE"
  echo "Ошибка создания копии" >&2
  exit 1
fi
# Проверка целостности только что созданной копии.
if openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -pass fd:3 -in "$ARCHIVE" 3<<<"$PASSWORD" | tar -tzf - >/dev/null; then
  echo "OK: архив зашифрован и проверен: $ARCHIVE"
  du -h "$ARCHIVE"
else
  rm -f "$ARCHIVE"
  echo "Верификация копии не прошла" >&2
  exit 1
fi
unset PASSWORD
