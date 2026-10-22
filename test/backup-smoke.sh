#!/usr/bin/env bash
# Runs in an isolated temporary folder, no WhatsApp/network/systemd changes.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Test requires root"; exit 1; }
ROOT="$(mktemp -d /tmp/wt-backup-test.XXXXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
APP="$ROOT/app"
BACKUP="$ROOT/backups"
mkdir -p "$APP/.data/auth" "$APP/.data/media"
echo 'GROQ_API_KEY=test_secret_value' > "$APP/.env"
echo 'sensitive-session-token' > "$APP/.data/auth/creds.json"
echo 'database-sample-text' > "$APP/.data/messages.sqlite"
echo 'test-image' > "$APP/.data/media/photo.image"
echo 'fake-app' > "$APP/server.mjs"
PASSWORD='a-test-very-long-backup-password'
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | bash backup.sh "$APP" "$BACKUP" "" >/dev/null
ARCHIVE="$(find "$BACKUP" -name '*.tar.gz.enc' -type f -print -quit)"
[[ -s "$ARCHIVE" ]] || { echo "Backup missing"; exit 1; }
[[ "$(stat -c '%a' "$ARCHIVE")" == 600 ]] || { echo "Bad backup permissions"; exit 1; }
if grep -aF 'sensitive-session-token' "$ARCHIVE" >/dev/null; then
  echo "Secret was visible in encrypted backup" >&2; exit 1
fi
openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -pass "pass:$PASSWORD" -in "$ARCHIVE" |
  tar -tzf - | grep -qF '.data/auth/creds.json' || {
    echo "Backup archive does not contain WhatsApp session"; exit 1;
  }

# Simulate systemd commands so restoration cannot modify real services in CI.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == show ]]; then
  id -un
fi
exit 0
MOCK
chmod 755 "$ROOT/bin/systemctl"
echo 'damaged config' > "$APP/.env"
echo 'damaged auth' > "$APP/.data/auth/creds.json"
printf '%s\n%s\n%s\n%s\n%s\n' "$APP" "wa-test" "$ARCHIVE" "$PASSWORD" "RESTORE" |
  env PATH="$ROOT/bin:$PATH" bash restore.sh >/dev/null
grep -qF 'GROQ_API_KEY=test_secret_value' "$APP/.env"
grep -qF 'sensitive-session-token' "$APP/.data/auth/creds.json"
grep -qF 'database-sample-text' "$APP/.data/messages.sqlite"
grep -qF 'test-image' "$APP/.data/media/photo.image"
echo 'Encrypted backup and restore: OK'
