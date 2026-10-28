#!/usr/bin/env bash
# Old clients' requests vs this server: replays each supported build's request goldens
# (shared/fixtures/requests at its sha) through this PR's backend, which must accept them as
# it did (docs/ios/specs/compatibility.md §3). Catches what the schema check can't: validation
# and rules that live in the code, not in openapi.json. Each build replays at its own API level
# (QUICKR_REPLAY_CLIENT_LEVEL, docs/specs/client-versions.md §6), so a server that refuses it
# fails here.
#
#   compat/old-requests.sh            every supported client in compat/supported-clients.json
#
# Needs the backend's test database (QUICKR_TEST_DATABASE_URL, as for `make test`).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Captured first: a failing command in a for-list doesn't stop the script (set -e ignores it),
# and would leave nothing to replay.
shas="$(python3 "$root/compat/client_fixtures.py" shas)"
rc=0
for sha in $shas; do
  mkdir -p "$work/$sha"
  git -C "$root" archive "$sha" shared/fixtures/requests | tar -x -C "$work/$sha"
  level="$(python3 "$root/compat/client_fixtures.py" level "$sha")"
  echo "compat: requests of ${sha:0:7} (level $level) against this backend"
  if ! (cd "$root/backend" && QUICKR_REQUEST_GOLDENS_DIR="$work/$sha/shared/fixtures/requests" \
    QUICKR_REPLAY_CLIENT_LEVEL="$level" uv run pytest -q tests/test_request_goldens.py -k "matches_the_contract or replays"); then
    message="the requests of ${sha:0:7} fail against this backend, so this change breaks a build users still run (docs/ios/specs/compatibility.md §3)"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::error title=old client requests::$message"; fi
    echo "compat: $message" >&2
    rc=1
  fi
done
exit "$rc"
