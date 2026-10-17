# Sourced by the integration-* scripts: this worktree's compose project, ports and env file.
#
# Every worktree gets its own compose project (quickr-it-<dir>-<hash of the worktree path>)
# and its own block of 4 ports in 21000-22999, picked from the same hash and probed so a
# busy block moves to the next one. The main dev stack (:8100, :5433, :8080) is never used.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IT_COMPOSE_FILE="$ROOT_DIR/docker-compose.integration.yml"
IT_ENV_FILE="$BUILD_DIR/integration.env"
IT_PORT_FIRST=21000
IT_SLOTS=500 # blocks of 4 ports: 21000..22999

IT_HASH="$(printf '%s' "$ROOT_DIR" | shasum | cut -c1-6)"
IT_NAME="$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | cut -c1-30)"
IT_PROJECT="quickr-it-${IT_NAME}-${IT_HASH}"
export QUICKR_IT_IMAGE="${IT_PROJECT}-backend:latest"

require_docker() {
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker is not running"
}

# docker compose for this worktree's project. The QUICKR_IT_PORT_* variables must be set
# (it_pick_ports, it_load_env, or placeholders for `down`).
it_compose() {
  docker compose -p "$IT_PROJECT" -f "$IT_COMPOSE_FILE" "$@"
}

_port_busy() {
  nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
}

# Sets QUICKR_IT_PORT_{PROXY,CONTROL,A,B}: the worktree's hashed block, or the next free one.
it_pick_ports() {
  local slot=$(( $(printf '%s' "$ROOT_DIR" | cksum | cut -d' ' -f1) % IT_SLOTS )) tries base p busy
  for (( tries = 0; tries < IT_SLOTS; tries++ )); do
    base=$(( IT_PORT_FIRST + ((slot + tries) % IT_SLOTS) * 4 ))
    busy=0
    for p in $base $((base + 1)) $((base + 2)) $((base + 3)); do
      if _port_busy "$p"; then busy=1; break; fi
    done
    if (( busy == 0 )); then
      export QUICKR_IT_PORT_PROXY=$base QUICKR_IT_PORT_CONTROL=$((base + 1))
      export QUICKR_IT_PORT_A=$((base + 2)) QUICKR_IT_PORT_B=$((base + 3))
      return
    fi
  done
  die "no free port block in $IT_PORT_FIRST..$(( IT_PORT_FIRST + IT_SLOTS * 4 - 1 ))"
}

# Exports everything in ios/build/integration.env (written by integration-up.sh).
it_load_env() {
  [[ -f "$IT_ENV_FILE" ]] || die "$IT_ENV_FILE not found: run ios/scripts/integration-up.sh"
  set -a
  # shellcheck disable=SC1090
  source "$IT_ENV_FILE"
  set +a
}

# Compose interpolates the port variables even for `down`/`ps`; any value will do there.
it_placeholder_ports() {
  export QUICKR_IT_PORT_PROXY="${QUICKR_IT_PORT_PROXY:-0}" QUICKR_IT_PORT_CONTROL="${QUICKR_IT_PORT_CONTROL:-0}"
  export QUICKR_IT_PORT_A="${QUICKR_IT_PORT_A:-0}" QUICKR_IT_PORT_B="${QUICKR_IT_PORT_B:-0}"
}
