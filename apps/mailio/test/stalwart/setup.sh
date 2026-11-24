#!/bin/sh
# Recreate the Stalwart test server and provision it through its management
# API: the domain interop.test, the user alice@interop.test, and plain-text
# listeners for IMAP (143), POP3 (110) and submission (587), which Stalwart
# does not open by default. Safe to run again: it always starts from scratch.
set -eu
cd "$(dirname "$0")"

API=http://127.0.0.1:38080
JMAP="$API/jmap/"
USING='"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"]'

docker compose up -d --force-recreate >/dev/null

echo "waiting for the management port"
i=0
until curl -s -o /dev/null -u admin:interop-pass "$API/jmap/session"; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "Stalwart did not start" >&2; exit 1; }
  sleep 1
done

# 1. bootstrap: sets the domain and returns the permanent administrator
BOOT=$(curl -s -u admin:interop-pass -H 'Content-Type: application/json' -X POST "$JMAP" -d "{$USING,\"methodCalls\":[[\"x:Bootstrap/set\",{\"accountId\":\"d333333\",\"update\":{\"singleton\":{\"defaultHostname\":\"mail.interop.test\",\"defaultDomain\":\"interop.test\",\"requestTlsCertificate\":false,\"generateDkimKeys\":false}}},\"a\"]]}")
SECRET=$(printf '%s' "$BOOT" | sed -n 's/.*"secret":"\([^"]*\)".*/\1/p')
[ -n "$SECRET" ] || { echo "bootstrap failed: $BOOT" >&2; exit 1; }
ADMIN="admin@interop.test:$SECRET"

# 2. the server reloads into normal mode on restart
docker compose restart >/dev/null
i=0
until ID=$(curl -s -u "$ADMIN" "$API/jmap/session" | sed -n 's/.*"accounts":{"\([^"]*\)".*/\1/p') && [ -n "$ID" ]; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "Stalwart did not come back" >&2; exit 1; }
  sleep 1
done

call() {
  curl -s -u "$ADMIN" -H 'Content-Type: application/json' -X POST "$JMAP" -d "{$USING,\"methodCalls\":[$1]}"
}

# 3. the user
OUT=$(call "[\"x:Account/set\",{\"accountId\":\"$ID\",\"create\":{\"u\":{\"@type\":\"User\",\"name\":\"alice\",\"domainId\":\"$ID\",\"credentials\":{\"0\":{\"@type\":\"Password\",\"secret\":\"interop-secret\"}}}}},\"a\"]")
case "$OUT" in *'"created"'*) ;; *) echo "creating the user failed: $OUT" >&2; exit 1 ;; esac

# 4. plain-text listeners (STARTTLS and STLS are offered on them)
OUT=$(call "[\"x:NetworkListener/set\",{\"accountId\":\"$ID\",\"create\":{\"a\":{\"name\":\"imap\",\"bind\":{\"[::]:143\":true},\"protocol\":\"imap\",\"implicitTls\":false,\"useTls\":true},\"b\":{\"name\":\"pop3\",\"bind\":{\"[::]:110\":true},\"protocol\":\"pop3\",\"implicitTls\":false,\"useTls\":true},\"c\":{\"name\":\"submission\",\"bind\":{\"[::]:587\":true},\"protocol\":\"smtp\",\"implicitTls\":false,\"useTls\":true}}},\"a\"]")
case "$OUT" in *'"created"'*) ;; *) echo "creating listeners failed: $OUT" >&2; exit 1 ;; esac

# 5. listeners are read at start
docker compose restart >/dev/null
i=0
until nc -z 127.0.0.1 32143 2>/dev/null && [ "$(printf 'a CAPABILITY\r\n' | nc -w2 127.0.0.1 32143 | head -c 4)" = '* OK' ]; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "IMAP did not come up" >&2; exit 1; }
  sleep 1
done
echo "Stalwart is ready: alice@interop.test / interop-secret"
