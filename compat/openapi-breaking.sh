#!/usr/bin/env bash
# Fails when openapi.json breaks the API of the latest release tag (v*), unless every breaking
# change is approved in compat/openapi-break-approvals.txt (docs/ios/specs/compatibility.md §2).
#
#   compat/openapi-breaking.sh [<base ref>]     default: the newest v* tag
#
# Needs oasdiff (OASDIFF, else on PATH); CI installs a pinned, checksummed release.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
oasdiff="${OASDIFF:-oasdiff}"
base="${1:-$(git -C "$root" tag --list 'v*' --sort=-creatordate | head -n 1)}"
[[ -n "$base" ]] || { echo "compat: no v* tag to compare openapi.json with" >&2; exit 1; }

old="$(mktemp)"
trap 'rm -f "$old"' EXIT
git -C "$root" show "$base:openapi.json" > "$old"

echo "compat: openapi.json against $base ($(git -C "$root" rev-parse --short "$base^{commit}")), oasdiff $("$oasdiff" --version | awk '{print $NF}')"
args=(breaking "$old" "$root/openapi.json" --fail-on ERR --err-ignore "$root/compat/openapi-break-approvals.txt")
# Warnings (an enum value added to a response, say) print but don't fail: clients fall back on
# unknown values (§1). In CI, errors also become annotations on the PR.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then "$oasdiff" "${args[@]}" --format githubactions || true; fi
if ! "$oasdiff" "${args[@]}" --format text; then
  echo "compat: openapi.json breaks the API of $base, which supported clients may still call." >&2
  echo "Make the change additive, or approve each break in compat/openapi-break-approvals.txt" >&2
  echo "(docs/ios/specs/compatibility.md §2)." >&2
  exit 1
fi
