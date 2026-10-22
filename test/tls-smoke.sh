#!/usr/bin/env bash
# Offline simulation for existing Nginx TLS integration and rollback.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Run with sudo"; exit 1; }
ROOT="$(mktemp -d /tmp/wt-tls-smoke.XXXXXXXX)"
SERVICE="wa-tls-smoke-$$"
DOMAIN="chat-tls-smoke.example.test"
SITE="/etc/nginx/sites-available/$SERVICE.conf"
LINK="/etc/nginx/sites-enabled/$SERVICE.conf"
finish() {
  rm -f "$SITE" "$LINK"
  rm -rf "$ROOT"
}
trap finish EXIT
mkdir -p -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled "$ROOT/bin"
CERT="$ROOT/fullchain.pem"
KEY="$ROOT/privkey.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 5 -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN" -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
cat > "$ROOT/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  is-active) exit 0 ;;
  reload)
    if [[ "${WT_FAIL_RELOAD:-0}" == 1 ]]; then exit 1; fi
    exit 0;;
  *) exit 0;;
esac
MOCK
cat > "$ROOT/bin/nginx" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -T) printf '%s\n' "server_name ${WT_TEST_EXISTING_DOMAIN:-other.example.test};"; exit 0 ;;
  -t) exit 0 ;;
  *) exit 1;;
esac
MOCK
chmod +x "$ROOT/bin/nginx" "$ROOT/bin/systemctl"
export PATH="$ROOT/bin:$PATH"
if printf '%s\n%s\n%s\n' "$CERT" "$KEY" INTEGRATE |
  WT_FAIL_RELOAD=1 bash integrate-existing.sh nginx-existing "$DOMAIN" 3099 "$SERVICE" >/dev/null 2>&1; then
  echo "Expected forced reload error, got success"; exit 1
fi
[[ ! -e "$SITE" && ! -e "$LINK" ]] || { echo "Rollback left Nginx files"; exit 1; }
printf '%s\n%s\n%s\n' "$CERT" "$KEY" INTEGRATE |
  bash integrate-existing.sh nginx-existing "$DOMAIN" 3099 "$SERVICE" >/dev/null
[[ -f "$SITE" && -L "$LINK" ]] || { echo "Valid vhost not created"; exit 1; }
grep -Fq "proxy_pass http://127.0.0.1:3099;" "$SITE"
rm -f "$SITE" "$LINK"
if printf '%s\n%s\n%s\n' "$CERT" "$KEY" INTEGRATE |
  WT_TEST_EXISTING_DOMAIN="$DOMAIN" bash integrate-existing.sh nginx-existing "$DOMAIN" 3099 "$SERVICE" >/dev/null 2>&1; then
  echo "Domain conflict was not detected"; exit 1
fi
[[ ! -e "$SITE" && ! -e "$LINK" ]] || { echo "Domain-conflict handling left files"; exit 1; }
echo "Nginx TLS simulation: rollback, valid creation, domain conflict OK"
