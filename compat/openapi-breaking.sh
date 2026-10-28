#!/usr/bin/env bash
# Fails when openapi.json breaks the API of a supported client in compat/supported-clients.json
# (the openapi.json at its sha), or that of the latest release tag (v*) without bumping
# shared/api-level.json. A break no client notices can instead be approved in
# compat/openapi-break-approvals.txt (docs/ios/specs/compatibility.md §2,
# docs/specs/client-versions.md §7).
#
#   compat/openapi-breaking.sh [<tag> [<client sha>...]]   default: the newest v* tag and every
#                                                          supported client
#
# The tag stands for the deployed PWA and any unlisted build: a break against it passes when this
# change raises api_level and sets both minimums to it (compat/api_level.py bumped), since the
# server then refuses every client built before it. A supported client can only be broken by
# raising the minimum above it, which takes it off the list (compat/client_fixtures.py shas).
#
# Needs oasdiff (OASDIFF, else on PATH); CI installs a pinned, checksummed release.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" # repo-relative paths, for the annotations
oasdiff="${OASDIFF:-oasdiff}"
if (($# == 0)); then
  tag="$(git tag --list 'v*' --sort=-creatordate | head -n 1)"
  [[ -n "$tag" ]] || { echo "compat: no v* tag to compare openapi.json with" >&2; exit 1; }
  # Captured first: a failing command in a process substitution or for-list wouldn't stop the
  # script (set -e ignores it), and would leave no clients to check.
  shas="$(python3 compat/client_fixtures.py shas)"
  clients=()
  while IFS= read -r sha; do if [[ -n "$sha" ]]; then clients+=("$sha"); fi; done <<< "$shas"
  # No listed clients is allowed (compat/supported-clients.json); bash < 4.4 needs the guard.
  set -- "$tag" ${clients[@]+"${clients[@]}"}
fi
tag="$1"

old="$(mktemp)"
trap 'rm -f "$old"' EXIT
rc=0
for base in "$@"; do
  git show "$base:openapi.json" > "$old"
  echo "compat: openapi.json against $base ($(git rev-parse --short "$base^{commit}")), oasdiff $("$oasdiff" --version | awk '{print $NF}')"
  args=(breaking "$old" openapi.json --fail-on ERR --err-ignore compat/openapi-break-approvals.txt)
  # Warnings (an enum value added to a response, say) print but don't fail: clients fall back
  # on unknown values (§1).
  status=0
  "$oasdiff" "${args[@]}" --format text || status=$?
  ((status == 0)) && continue
  # oasdiff exits 1 for breaking changes, and 100 or more when it can't run (an unreadable spec
  # or approvals file, say), which no bump excuses.
  if ((status != 1)); then
    echo "compat: oasdiff failed against $base (exit $status)" >&2
    rc=1
    continue
  fi
  if [[ "$base" == "$tag" ]] && python3 compat/api_level.py bumped "$tag"; then
    echo "compat: so the break passes: the server refuses every client built before it."
    continue
  fi
  # In CI, errors also become annotations on the PR.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then "$oasdiff" "${args[@]}" --format githubactions || true; fi
  if [[ "$base" == "$tag" ]]; then
    echo "compat: openapi.json breaks the API of $tag, which the deployed PWA and unlisted builds speak." >&2
    echo "Make the change additive or bump shared/api-level.json, or approve a break no client notices" >&2
    echo "in compat/openapi-break-approvals.txt (docs/specs/client-versions.md §7)." >&2
  else
    echo "compat: openapi.json breaks the API of supported client $base." >&2
    echo "Make the change additive, or raise min_client_level.ios above its api_level, which stops" >&2
    echo "serving it (docs/specs/client-versions.md §7)." >&2
  fi
  rc=1
done
exit "$rc"
