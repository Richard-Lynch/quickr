#!/usr/bin/env bash
# Start this worktree's integration stacks: Postgres, two independent backends built from
# this worktree's backend/, and the fault proxy in front of them. Waits for health, checks
# the two servers really differ, then writes ios/build/integration.env and prints it.
# Starts clean every time (the previous stack, if any, is removed first). If anything fails
# or the script is interrupted before the env file is written, the stack is removed again.
source "$(dirname "$0")/integration-common.sh"
require_docker
command -v curl >/dev/null || die "curl not found"

it_compose down -v --remove-orphans >/dev/null 2>&1 || true
rm -f "$IT_ENV_FILE"

started=0
cleanup() {
  local status=$?
  if (( started == 0 )); then
    echo "integration: startup failed or interrupted; removing $IT_PROJECT" >&2
    it_compose --progress quiet down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
    rm -f "$IT_ENV_FILE"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "integration: project $IT_PROJECT" >&2
it_compose --progress quiet build backend-a
if ! it_compose --progress quiet up -d --no-build --wait --wait-timeout 180; then
  it_compose ps -a >&2 || true
  it_compose logs --tail 60 >&2 || true
  die "integration stack failed to start"
fi

port_proxy="$(it_port proxy 8080)"
port_control="$(it_port proxy 8081)"
port_a="$(it_port backend-a 8000)"
port_b="$(it_port backend-b 8000)"
echo "integration: ports proxy=$port_proxy control=$port_control a=$port_a b=$port_b" >&2

server_id() {
  curl -fsS -D - -o /dev/null "$1/api/v1/health" | tr -d '\r' \
    | awk 'tolower($1) == "x-quickr-server-id:" { print $2 }'
}
base="http://127.0.0.1"
id_a="$(server_id "$base:$port_a")"
id_b="$(server_id "$base:$port_b")"
id_proxy="$(server_id "$base:$port_proxy")"
[[ -n "$id_a" && -n "$id_b" ]] || die "health responses carry no X-QuickR-Server-Id"
[[ "$id_a" != "$id_b" ]] || die "both servers report server id $id_a"
[[ "$id_proxy" == "$id_a" ]] || die "the proxy reaches server '$id_proxy', expected server a '$id_a'"
[[ "$(curl -fsS "$base:$port_control/health")" == *'"ok": true'* ]] || die "proxy control API not healthy"

mkdir -p "$BUILD_DIR"
tmp="$IT_ENV_FILE.tmp"
{
  put() { printf '%s=%q\n' "$1" "$2"; }
  put QUICKR_IT_PROJECT "$IT_PROJECT"
  put QUICKR_IT_BASE_URL "$base:$port_proxy"
  put QUICKR_IT_BASE_URL_2 "$base:$port_b"
  put QUICKR_IT_DIRECT_URL "$base:$port_a"
  put QUICKR_IT_PROXY_CONTROL_URL "$base:$port_control"
  put QUICKR_IT_SERVER_ID "$id_a"
  put QUICKR_IT_SERVER_ID_2 "$id_b"
  put QUICKR_IT_ROTATE_EPOCH "$IOS_DIR/scripts/integration-rotate-epoch.sh"
  put QUICKR_IT_PORT_PROXY "$port_proxy"
  put QUICKR_IT_PORT_CONTROL "$port_control"
  put QUICKR_IT_PORT_A "$port_a"
  put QUICKR_IT_PORT_B "$port_b"
} >"$tmp"
mv "$tmp" "$IT_ENV_FILE"
started=1
echo "integration: up; wrote $IT_ENV_FILE" >&2
cat "$IT_ENV_FILE"
