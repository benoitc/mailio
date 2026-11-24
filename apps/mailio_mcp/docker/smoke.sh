#!/bin/sh
# Smoke test for the container image: start it over HTTP with the example
# config and talk to it with a signed token. Usage: smoke.sh [image]
set -eu
IMAGE="${1:-mailio-mcp}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=18420
NAME=mailio-mcp-smoke

export WORK_MAIL_PASSWORD=unused
export MAILIO_MCP_JWT_SECRET=$(printf 'j%.0s' $(seq 1 40))
export MAILIO_MCP_STATE_KEY=$(printf 'k%.0s' $(seq 1 40))

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p 127.0.0.1:$PORT:8420 \
  -e WORK_MAIL_PASSWORD -e MAILIO_MCP_JWT_SECRET -e MAILIO_MCP_STATE_KEY \
  -v "$HERE/mail.config:/config/mail.config:ro" "$IMAGE" http >/dev/null
trap 'docker logs "$NAME" 2>&1 | tail -20; docker rm -f "$NAME" >/dev/null 2>&1' EXIT

URL=http://127.0.0.1:$PORT/mcp
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" -H 'Content-Type: application/json' -d '{}')" = 401 ]; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "the server did not start" >&2; exit 1; }
  sleep 1
done
echo "no token: 401"

TOKEN=$(python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
b = lambda x: base64.urlsafe_b64encode(x).rstrip(b'=')
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
p = b(json.dumps({"sub": "assistant", "aud": "mailio-mcp", "exp": int(time.time()) + 600}).encode())
sig = b(hmac.new(os.environ['MAILIO_MCP_JWT_SECRET'].encode(), h + b'.' + p, hashlib.sha256).digest())
print((h + b'.' + p + b'.' + sig).decode())
PY
)

call() { # call SESSION BODY
  curl -s -m15 -X POST "$URL" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' ${1:+-H "Mcp-Session-Id: $1"} -d "$2"
}

curl -s -m15 -D /tmp/smoke-headers -o /dev/null -X POST "$URL" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
SID=$(grep -i '^mcp-session-id' /tmp/smoke-headers | tr -d '\r' | awk '{print $2}')
[ -n "$SID" ] || { echo "no session" >&2; exit 1; }
call "$SID" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

TOOLS=$(call "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
for t in accounts_list mailboxes_list mail_search mail_read mail_changes draft_save draft_send; do
  printf '%s' "$TOOLS" | grep -q "\"name\":\"$t\"" || { echo "missing tool $t" >&2; exit 1; }
done
echo "tools: 7"

ACCOUNTS=$(call "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"accounts_list","arguments":{}}}')
printf '%s' "$ACCOUNTS" | grep -q 'work' || { echo "accounts_list did not show the account" >&2; exit 1; }
echo "accounts_list: ok"

echo "container smoke test passed"
