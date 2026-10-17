#!/usr/bin/env bash
# Exercise the integration harness with curl: the proxy, its fault rules, both servers and
# epoch rotation. Needs a running stack (integration-up.sh); `make ios-integration` runs it.
source "$(dirname "$0")/integration-common.sh"
it_load_env
command -v python3 >/dev/null || die "python3 not found"

P="$QUICKR_IT_BASE_URL"
C="$QUICKR_IT_PROXY_CONTROL_URL"
A="$QUICKR_IT_DIRECT_URL"
B="$QUICKR_IT_BASE_URL_2"
n=0

ok() { n=$((n + 1)); echo "ok $n - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }
# json <python expression over `d`> < body
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# hdr <name> <url> [curl args...]: one response header's value
hdr() {
  local name="$1" url="$2"; shift 2
  curl -sS -D - -o /dev/null "$@" "$url" | tr -d '\r' \
    | awk -v h="$(echo "$name:" | tr '[:upper:]' '[:lower:]')" 'tolower($1) == h { print $2 }'
}
rule() { curl -fsS -X POST "$C/rules" -H 'Content-Type: application/json' -d "$1" >/dev/null; }
post() { curl -sS -H 'Content-Type: application/json' -X POST "$@"; }

curl -fsS -X POST "$C/reset" >/dev/null

# Health through the proxy reaches server a.
[[ "$(hdr X-QuickR-Server-Id "$P/api/v1/health")" == "$QUICKR_IT_SERVER_ID" ]] || fail "proxy health"
ok "health through the proxy: server $QUICKR_IT_SERVER_ID"

# Unique names, so the script can run again against the same stack.
entry="$(python3 -c 'import uuid; print(uuid.uuid4())')"
topic="$(post "$A/api/v1/topics" \
  -d "{\"name\":\"Smoke ${entry:0:8}\",\"questions\":[{\"key\":\"n\",\"label\":\"N\",\"type\":\"int\"}]}" \
  | json 'd["id"]')" || fail "create topic"
ok "created topic $topic on server a"

# Drop the response after the server committed the create.
rule '{"method":"POST","path":"/api/v1/topics/*/entries","action":"drop_response"}'
if post "$P/api/v1/topics/$topic/entries" -d "{\"id\":\"$entry\",\"answers\":{\"n\":1}}" 2>/dev/null; then
  fail "the create was not dropped"
fi
ok "create $entry through the proxy: connection dropped after the server answered"
[[ "$(curl -fsS "$C/log" | json 'd[-1]["upstream_status"], d[-1]["state"]')" == "201 dropped" ]] \
  || fail "proxy log: $(curl -fsS "$C/log")"
ok "proxy log: upstream 201, client dropped"
[[ "$(curl -fsS "$A/api/v1/entries/$entry" | json 'd["id"]')" == "$entry" ]] || fail "entry missing on server"
ok "the entry exists on server a"

# Garble a 2xx: EntryOut without its revision.
rule '{"method":"GET","path":"/api/v1/entries/*","action":"garble","garble":"drop_field","field":"revision"}'
[[ "$(curl -fsS "$P/api/v1/entries/$entry" | json '"revision" in d')" == False ]] || fail "garble"
[[ "$(curl -fsS "$P/api/v1/entries/$entry" | json '"revision" in d')" == True ]] || fail "one-shot garble"
ok "garble drops revision from one response, then passes"

# The change feed through the proxy has the entry.
[[ "$(curl -fsS "$P/api/v1/changes?after=0" | json "any(i['kind'] == 'entry' and i['entry']['id'] == '$entry' for i in d['items'])")" == True ]] \
  || fail "/changes is missing the entry"
ok "/changes through the proxy lists the entry"

# Injected answers never reach the server.
before="$(curl -fsS "$C/log" | json 'len(d)')"
rule '{"action":"status","status":503}'
[[ "$(curl -sS -o /dev/null -w '%{http_code}' "$P/api/v1/health")" == 503 ]] || fail "503"
rule '{"action":"status","status":429,"retry_after":"1"}'
[[ "$(hdr Retry-After "$P/api/v1/health")" == 1 ]] || fail "429 Retry-After"
rule '{"action":"captive"}'
[[ "$(curl -fsS "$P/api/v1/changes" | head -c 15)" == "<!doctype html>" ]] || fail "captive"
[[ "$(curl -fsS "$C/log" | json "[e['upstream'] for e in d[$before:]]")" == "[None, None, None]" ]] \
  || fail "an injected answer reached the server"
ok "503, 429 + Retry-After and a captive page, without touching the server"
rule '{"action":"strip_identity"}'
[[ -z "$(hdr X-QuickR-Server-Id "$P/api/v1/health")" ]] || fail "strip_identity"
ok "strip_identity removes the identity headers"

# The second server is a different server; the proxy can switch to it.
[[ -n "$QUICKR_IT_SERVER_ID_2" && "$(hdr X-QuickR-Server-Id "$B/api/v1/health")" == "$QUICKR_IT_SERVER_ID_2" ]] \
  || fail "server b"
[[ "$QUICKR_IT_SERVER_ID_2" != "$QUICKR_IT_SERVER_ID" ]] || fail "same server ids"
ok "server b reports a different server id: $QUICKR_IT_SERVER_ID_2"
curl -fsS -X PUT "$C/upstream" -H 'Content-Type: application/json' -d '{"name":"b"}' >/dev/null
[[ "$(hdr X-QuickR-Server-Id "$P/api/v1/health")" == "$QUICKR_IT_SERVER_ID_2" ]] || fail "upstream switch"
code="$(post "$P/api/v1/topics/$topic/entries" -H "X-QuickR-Expect-Server-Id: $QUICKR_IT_SERVER_ID" \
  -d '{"answers":{"n":2}}' | json 'd.get("code")')"
[[ "$code" == server_mismatch ]] || fail "expected 409 server_mismatch from server b, got $code"
ok "proxy switched to server b: a create expecting server a gets server_mismatch"

# Epoch rotation on server a changes the header.
curl -fsS -X POST "$C/reset" >/dev/null
epoch="$(hdr X-QuickR-Epoch "$P/api/v1/health")"
"$QUICKR_IT_ROTATE_EPOCH" a >/dev/null
epoch2="$(hdr X-QuickR-Epoch "$P/api/v1/health")"
[[ -n "$epoch" && "$epoch" != "$epoch2" ]] || fail "epoch did not change ($epoch -> $epoch2)"
ok "rotate-epoch on server a: $epoch -> $epoch2"

curl -fsS -X POST "$C/reset" >/dev/null
echo "integration smoke: $n checks passed"
