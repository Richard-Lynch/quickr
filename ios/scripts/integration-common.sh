# Sourced by the integration-* scripts: this worktree's compose project and env file.
#
# Every worktree gets its own compose project, quickr-it-<dir>-<hash of the canonical
# worktree path>. Host ports are left to Docker (127.0.0.1, ephemeral), so worktrees never
# race for them; integration-up.sh reads them back into ios/build/integration.env.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

IT_COMPOSE_FILE="$ROOT_DIR/docker-compose.integration.yml"
IT_ENV_FILE="$BUILD_DIR/integration.env"

IT_ROOT_REAL="$(cd "$ROOT_DIR" && pwd -P)"
IT_HASH="$(printf '%s' "$IT_ROOT_REAL" | shasum | cut -c1-6)"
IT_NAME="$(basename "$IT_ROOT_REAL" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | cut -c1-30)"
IT_PROJECT="quickr-it-${IT_NAME}-${IT_HASH}"
export QUICKR_IT_IMAGE="${IT_PROJECT}-backend:latest"

require_docker() {
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker is not running"
}

it_compose() {
  docker compose -p "$IT_PROJECT" -f "$IT_COMPOSE_FILE" "$@"
}

# The host port Docker published for <service> <container port>.
it_port() {
  local addr
  addr="$(it_compose port "$1" "$2")" || return 1
  [[ "$addr" =~ ^127\.0\.0\.1:([0-9]+)$ ]] || { echo "unexpected published address '$addr'" >&2; return 1; }
  echo "${BASH_REMATCH[1]}"
}

# Exports everything in ios/build/integration.env (written by integration-up.sh).
it_load_env() {
  [[ -f "$IT_ENV_FILE" ]] || die "$IT_ENV_FILE not found: run ios/scripts/integration-up.sh"
  set -a
  # shellcheck disable=SC1090
  source "$IT_ENV_FILE"
  set +a
}
