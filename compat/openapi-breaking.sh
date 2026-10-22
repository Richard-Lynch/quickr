#!/usr/bin/env bash
# Fails when openapi.json breaks the API of the latest release tag (v*) or of any client in
# compat/supported-clients.json (the openapi.json at its sha), unless every breaking change is
# approved in compat/openapi-break-approvals.txt (docs/ios/specs/compatibility.md §2).
#
#   compat/openapi-breaking.sh [<base ref>...]     default: the newest v* tag and every client
#
# Needs oasdiff (OASDIFF, else on PATH); CI installs a pinned, checksummed release.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" # repo-relative paths, for the annotations
oasdiff="${OASDIFF:-oasdiff}"
if (($# == 0)); then
  tag="$(git tag --list 'v*' --sort=-creatordate | head -n 1)"
  [[ -n "$tag" ]] || { echo "compat: no v* tag to compare openapi.json with" >&2; exit 1; }
  clients=()
  while IFS= read -r sha; do clients+=("$sha"); done < <(python3 compat/client_fixtures.py shas)
  set -- "$tag" "${clients[@]}"
fi

old="$(mktemp)"
trap 'rm -f "$old"' EXIT
rc=0
for base in "$@"; do
  git show "$base:openapi.json" > "$old"
  echo "compat: openapi.json against $base ($(git rev-parse --short "$base^{commit}")), oasdiff $("$oasdiff" --version | awk '{print $NF}')"
  args=(breaking "$old" openapi.json --fail-on ERR --err-ignore compat/openapi-break-approvals.txt)
  # Warnings (an enum value added to a response, say) print but don't fail: clients fall back
  # on unknown values (§1). In CI, errors also become annotations on the PR.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then "$oasdiff" "${args[@]}" --format githubactions || true; fi
  if ! "$oasdiff" "${args[@]}" --format text; then
    echo "compat: openapi.json breaks the API of $base, which supported clients may still call." >&2
    echo "Make the change additive, or approve each break in compat/openapi-break-approvals.txt" >&2
    echo "(docs/ios/specs/compatibility.md §2)." >&2
    rc=1
  fi
done
exit "$rc"
