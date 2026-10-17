#!/usr/bin/env bash
# Start this worktree's integration stacks: Postgres, two independent backends built from
# this worktree's backend/, and the fault proxy in front of them. Waits for health, checks
# the two servers really differ, then writes ios/build/integration.env and prints it.
# Starts clean every time (the previous stack, if any, is removed first).
source "$(dirname "$0")/integration-common.sh"
require_docker
command -v curl >/dev/null || die "curl not found"

it_placeholder_ports
it_compose down -v --remove-orphans >/dev/null 2>&1 || true
unset QUICKR_IT_PORT_PROXY QUICKR_IT_PORT_CONTROL QUICKR_IT_PORT_A QUICKR_IT_PORT_B
rm -f "$IT_ENV_FILE"
it_pick_ports

echo "integration: project $IT_PROJECT, ports proxy=$QUICKR_IT_PORT_PROXY control=$QUICKR_IT_PORT_CONTROL" \
  "a=$QUICKR_IT_PORT_A b=$QUICKR_IT_PORT_B" >&2
it_compose --progress quiet build backend-a
if ! it_compose --progress quiet up -d --no-build --wait --wait-timeout 180; then
  it_compose ps -a >&2 || true
  it_compose logs --tail 60 >&2 || true
  it_compose down -v --remove-orphans >/dev/null 2>&1 || true
  die "integration stack failed to start"
fi

server_id() {
  curl -fsS -D - -o /dev/null "$1/api/v1/health" | tr -d '\r' \
    | awk 'tolower($1) == "x-quickr-server-id:" { print $2 }'
}
base="http://127.0.0.1"
id_a="$(server_id "$base:$QUICKR_IT_PORT_A")"
id_b="$(server_id "$base:$QUICKR_IT_PORT_B")"
id_proxy="$(server_id "$base:$QUICKR_IT_PORT_PROXY")"
[[ -n "$id_a" && -n "$id_b" ]] || die "health responses carry no X-QuickR-Server-Id"
[[ "$id_a" != "$id_b" ]] || die "both servers report server id $id_a"
[[ "$id_proxy" == "$id_a" ]] || die "the proxy reaches server '$id_proxy', expected server a '$id_a'"

mkdir -p "$BUILD_DIR"
cat >"$IT_ENV_FILE" <<EOF
QUICKR_IT_PROJECT=$IT_PROJECT
QUICKR_IT_BASE_URL=$base:$QUICKR_IT_PORT_PROXY
QUICKR_IT_BASE_URL_2=$base:$QUICKR_IT_PORT_B
QUICKR_IT_DIRECT_URL=$base:$QUICKR_IT_PORT_A
QUICKR_IT_PROXY_CONTROL_URL=$base:$QUICKR_IT_PORT_CONTROL
QUICKR_IT_SERVER_ID=$id_a
QUICKR_IT_SERVER_ID_2=$id_b
QUICKR_IT_ROTATE_EPOCH=$IOS_DIR/scripts/integration-rotate-epoch.sh
QUICKR_IT_PORT_PROXY=$QUICKR_IT_PORT_PROXY
QUICKR_IT_PORT_CONTROL=$QUICKR_IT_PORT_CONTROL
QUICKR_IT_PORT_A=$QUICKR_IT_PORT_A
QUICKR_IT_PORT_B=$QUICKR_IT_PORT_B
EOF
echo "integration: up; wrote $IT_ENV_FILE" >&2
cat "$IT_ENV_FILE"
