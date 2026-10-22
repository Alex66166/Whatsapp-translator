#!/usr/bin/env bash
# Аудит только для чтения. Не изменяет систему.
set -u
export LC_ALL=C
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Для полного аудита нужны права root: sudo bash audit.sh" >&2
  exit 1
fi
section() { printf '\n\n===== %s =====\n' "$*"; }
cmd() {
  printf '\n$'; printf ' %q' "$@"; printf '\n'
  "$@" 2>&1 || echo "[Команда завершилась с ошибкой либо отсутствует]"
}
section "Дата, имя сервера, ОС, ядро"
date -Is
hostnamectl status --no-pager 2>&1 || true
grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' /etc/os-release 2>/dev/null || :
uname -a
section "ОЗУ / SWAP / диски"
cmd free -h
cmd swapon --show
cmd df -hT
cmd df -i
cmd lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
cmd uptime
section "Полный перечень установленных пакетов (названия и версии)"
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='\x24{binary:Package} \x24{Version}\n' 2>/dev/null || :
fi
if command -v snap >/dev/null 2>&1; then snap list 2>&1 || :; fi
if command -v flatpak >/dev/null 2>&1; then flatpak list --columns=application,version 2>&1 || :; fi
section "Каталоги пользовательских приложений (метаданные, без содержимого)"
for rootdir in /opt /srv /var/www /usr/local/bin /etc/systemd/system; do
  if [[ -d "$rootdir" ]]; then
    find "$rootdir" -mindepth 1 -maxdepth 1 -printf '%y %p\n' 2>/dev/null | sort || :
  fi
done
section "Systemd timers и socket activation"
cmd systemctl list-timers --all --no-pager
cmd systemctl list-sockets --all --no-pager
section "Планировщик cron: только имена системных задач"
for crondir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
  if [[ -d "$crondir" ]]; then find "$crondir" -maxdepth 1 -type f -printf '%p\n' 2>/dev/null | sort; fi
done
section "Сетевые интерфейсы, адреса, маршруты"
cmd ip -brief address
cmd ip route
cmd ip -6 route
section "Слушающие TCP/UDP порты, PID, процесс"
cmd ss -tulpn
section "Активные службы и автозапуск"
cmd systemctl list-units --type=service --state=running --no-pager --plain
cmd systemctl list-unit-files --type=service --state=enabled --no-pager --plain
section "Веб-серверы / базы / контейнеры / версии"
for binary in nginx apache2 httpd caddy traefik node npm docker podman php php-fpm mysql mariadb postgres psql redis-server certbot; do
  if command -v "$binary" >/dev/null 2>&1; then
    printf '%s: %s\n' "$binary" "$(command -v "$binary")"
    case "$binary" in
      nginx) nginx -v 2>&1 ;;
      apache2|httpd) "$binary" -v 2>&1 | head -n 2 ;;
      node|npm|docker|podman|certbot) "$binary" --version 2>&1 | head -n 2 ;;
    esac
  fi
done
cmd dpkg -l nginx apache2 caddy certbot nodejs docker.io docker-ce podman mariadb-server postgresql redis-server
cmd ps -eo pid,comm,rss --sort=-rss
section "Nginx vhost: только server_name/listen (без закрытых ключей и паролей)"
if [[ -d /etc/nginx ]]; then
  find /etc/nginx/sites-enabled /etc/nginx/conf.d -maxdepth 2 \( -type f -o -type l \) 2>/dev/null | sort || :
  grep -R -n -E '^[[:space:]]*(server_name|listen)[[:space:]]' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null || :
fi
section "Apache vhost"
if command -v apache2ctl >/dev/null 2>&1; then apache2ctl -S 2>&1 || :; fi
section "Caddy: пути конфигураций"
if [[ -d /etc/caddy ]]; then find /etc/caddy -maxdepth 2 -type f -printf '%p\n' 2>/dev/null || :; fi
section "Контейнеры: имена, образы и порты БЕЗ переменных окружения"
if command -v docker >/dev/null 2>&1; then docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>&1 || :; fi
if command -v podman >/dev/null 2>&1; then podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>&1 || :; fi
section "Файрвол и Fail2ban"
if command -v ufw >/dev/null 2>&1; then ufw status verbose || :; fi
if command -v nft >/dev/null 2>&1; then nft list ruleset || :; fi
if command -v iptables >/dev/null 2>&1; then iptables -S || :; fi
if command -v fail2ban-client >/dev/null 2>&1; then fail2ban-client status || :; fi
section "TLS сертификаты: имена и сроки (без закрытых ключей)"
if command -v certbot >/dev/null 2>&1; then certbot certificates 2>&1 || :; fi
section "Следы существующих установок"
for p in /opt/whatsapp-translator /etc/systemd/system/whatsapp-translator.service /var/lib/whatsapp-translator; do
  if [[ -e "$p" ]]; then
    stat -c '%n : %F, mode=%a, owner=%U:%G' "$p" 2>/dev/null || :
    du -sh "$p" 2>/dev/null || :
  fi
done
section "Результат"
echo "Оценить RAM, swap, диски, порты, веб-серверы/vhost, домены, TLS, правила сети, контейнеры, резервное копирование и риск для работающих служб."
echo "Отчёт содержит IP-адреса и сетевую конфигурацию: не публикуйте его."
echo "АУДИТ ЗАВЕРШЁН: ПАКЕТЫ, СЛУЖБЫ, ПОРТЫ И НАСТРОЙКИ НЕ ИЗМЕНЕНЫ."
