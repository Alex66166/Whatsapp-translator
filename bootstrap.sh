#!/usr/bin/env bash
# Единственная точка входа: загрузка -> аудит (без изменений) -> рекомендации -> согласованная установка.
set -Eeuo pipefail
umask 077
[[ "$(id -u)" -eq 0 ]] || { echo "Запустите от root: sudo bash bootstrap.sh" >&2; exit 1; }
[[ -t 0 ]] || { echo "Нужен интерактивный терминал. Сначала скачайте скрипт в файл, затем sudo bash <файл>." >&2; exit 1; }
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || { echo "Автоустановка предусмотрена для Ubuntu 24.04"; exit 1; }
for bin in curl tar mktemp ss awk grep; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Отсутствует $bin; пакеты до аудита не устанавливаем."; exit 1; }
done
WORK="$(mktemp -d /tmp/wt-bootstrap.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -m 700 "$WORK/project"
echo "WhatsApp Translator | Загрузка из GitHub..."
curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 120 \
  https://codeload.github.com/Alex66166/Whatsapp_translater/tar.gz/refs/heads/main \
  -o "$WORK/project.tar.gz" || { echo "Ошибка: сделайте репозиторий публичным, проверьте сеть."; exit 1; }
tar -tzf "$WORK/project.tar.gz" >/dev/null || { echo "Неверный архив"; exit 1; }
tar -xzf "$WORK/project.tar.gz" --strip-components=1 -C "$WORK/project"
for file in audit.sh deploy.sh integrate-existing.sh backup.sh server.mjs package.json; do
  [[ -f "$WORK/project/$file" ]] || { echo "В архиве нет $file"; exit 1; }
done
for script in audit.sh deploy.sh integrate-existing.sh backup.sh restore.sh; do
  bash -n "$WORK/project/$script" || { echo "Ошибка синтаксиса $script"; exit 1; }
done

REPORT_DIR="/root/whatsapp-translator-audits"
install -d -m 700 "$REPORT_DIR"
REPORT="$REPORT_DIR/audit-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
echo
echo "=== ЭТАП 1: ПОЛНЫЙ АУДИТ VPS (без изменения системы) ==="
bash "$WORK/project/audit.sh" > "$REPORT" 2>&1
chmod 600 "$REPORT"
grep -Fq 'АУДИТ ЗАВЕРШЁН:' "$REPORT" || { echo "Отчёт неполный: $REPORT"; exit 1; }
echo "Отчёт сохранён: $REPORT"
echo
echo "=== РЕСУРСЫ ==="
free -h; df -h /
echo "=== ВЕБ-СЕРВЕРЫ ==="
for service in nginx apache2 caddy; do
  if command -v "$service" >/dev/null 2>&1; then
    printf '%s: ' "$service"
    systemctl is-active "$service" || :
  fi
done
echo "=== СЛУШАЮЩИЕ TCP-ПОРТЫ ==="
ss -H -ltnp || :

# Это рекомендации, не окончательная конфигурация. Любую можно изменить в мастере.
APP_DIR="/opt/whatsapp-translator"
if [[ -e "$APP_DIR" && ! -f "$APP_DIR/server.mjs" ]]; then
  idx=2
  while [[ -e "/opt/whatsapp-translator-$idx" ]]; do idx=$((idx+1)); done
  APP_DIR="/opt/whatsapp-translator-$idx"
fi
SERVICE="whatsapp-translator"
if [[ -e "/etc/systemd/system/$SERVICE.service" ]] &&
  ! grep -Fq "WorkingDirectory=$APP_DIR" "/etc/systemd/system/$SERVICE.service"; then
  idx=2
  while [[ -e "/etc/systemd/system/whatsapp-translator-$idx.service" ]]; do idx=$((idx+1)); done
  SERVICE="whatsapp-translator-$idx"
fi
APPUSER="wttranslator"
if id "$APPUSER" >/dev/null 2>&1 && [[ "$(id -u "$APPUSER")" -eq 0 ]]; then APPUSER="wttranslator2"; fi
PORT=""
if [[ -f "$APP_DIR/.env" ]]; then
  PORT="$(sed -n 's/^PORT=//p' "$APP_DIR/.env" | tail -n 1)"
fi
if [[ -z "$PORT" ]]; then
  for candidate in $(seq 3080 3199); do
    if ! ss -H -ltn "( sport = :$candidate )" | grep -q .; then PORT="$candidate"; break; fi
  done
fi
[[ -n "$PORT" ]] || { echo "Нет свободного порта в рекомендованном диапазоне; требуется ручной анализ."; exit 1; }
PROXY="nginx"
WHY="Не обнаружено занятого HTTP/HTTPS-сервера: возможна новая установка Nginx."
RUNNING=()
for service in nginx apache2 caddy; do
  if systemctl is-active --quiet "$service" 2>/dev/null; then RUNNING+=("$service"); fi
done
LISTENERS="$(ss -H -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null || :)"
if [[ "${#RUNNING[@]}" -eq 1 ]]; then
  case "${RUNNING[0]}" in
    nginx) PROXY="nginx-existing" ;;
    apache2) PROXY="apache-existing" ;;
    caddy) PROXY="caddy-existing" ;;
  esac
  WHY="Найден работающий ${RUNNING[0]}. Предлагается отдельный HTTPS-сайт через этот сервер с проверкой и откатом."
  if [[ -n "$LISTENERS" ]]; then
    if printf '%s\n' "$LISTENERS" | grep -v "\"${RUNNING[0]}\"" | grep -q .; then
      PROXY="manual"; WHY="На HTTP/HTTPS обнаружены слушатели, не принадлежащие выбранному веб-серверу."
    fi
  fi
elif [[ "${#RUNNING[@]}" -gt 1 ]]; then
  PROXY="manual"; WHY="Несколько работающих веб-серверов: нужен ручной выбор."
elif [[ -n "$LISTENERS" ]]; then
  PROXY="manual"; WHY="HTTP/HTTPS-порты заняты неизвестным приложением."
fi
if [[ -f "$APP_DIR/.env" ]]; then
  PROXY="manual"; WHY="Найдена прежняя установка: автоматически переподключать TLS нельзя."
fi
if [[ "$PROXY" == nginx ]] && [[ -d /etc/nginx/sites-enabled ]] &&
  find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 | grep -q .; then
  PROXY="manual"; WHY="Есть конфигурация Nginx, но сервер не запущен: нужен ручной анализ."
fi
echo
echo "=== РЕКОМЕНДУЕМАЯ КОНФИГУРАЦИЯ ==="
printf 'Каталог: %s\nСлужба: %s\nПользователь: %s\nПорт: %s\nВеб-сервер: %s\n' "$APP_DIR" "$SERVICE" "$APPUSER" "$PORT" "$PROXY"
echo "$WHY"
echo "В следующем меню Enter = принять рекомендацию; можно ввести любое другое допустимое значение."
echo "Домен, пароль и Groq API-ключ необходимо будет указать."
echo "До финального подтверждения INSTALL ничего не изменится."
read -rp "Перейти к настройке? [y/N]: " ANSWER
[[ "$ANSWER" =~ ^([yY]|[Дд])$ ]] || { echo "Отменено. Отчёт остался в $REPORT"; exit 0; }

export WA_AUDIT_REPORT="$REPORT"
export WA_REC_APP_DIR="$APP_DIR" WA_REC_SERVICE="$SERVICE" WA_REC_APPUSER="$APPUSER" WA_REC_PORT="$PORT"
EXTERNAL_PORT=443
NGINX_SITE="/etc/nginx/sites-available/$SERVICE.conf"
if [[ -f "$NGINX_SITE" ]]; then
  SAVED_TLS_PORT="$(sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)[[:space:]]+ssl;.*$/\1/p' "$NGINX_SITE" | head -n1)"
  if [[ "$SAVED_TLS_PORT" =~ ^[0-9]+$ ]]; then EXTERNAL_PORT="$SAVED_TLS_PORT"; fi
fi
export WA_REC_EXTERNAL_PORT="$EXTERNAL_PORT"
export WA_REC_PROXY_MODE="$PROXY" WA_REC_ACME_DIR="/var/www/letsencrypt"
export WA_REC_MODEL="openai/gpt-oss-120b" WA_REC_LANGUAGE="Montenegrin (Latin script, Ijekavian)"
export WA_REC_MAX_IMAGE="8" WA_REC_MEDIA_TOTAL="512" WA_REC_BACKUP_DIR="/root/whatsapp-translator-backups"
echo "=== ЭТАП 2: согласование и установка ==="
bash "$WORK/project/deploy.sh"
