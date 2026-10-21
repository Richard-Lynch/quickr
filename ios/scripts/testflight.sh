#!/usr/bin/env bash
# make ios-testflight: archive the app (Release, generic iOS device) and upload it to App Store
# Connect for TestFlight, signed automatically through an App Store Connect API key.
# make ios-testflight-dry-run (--dry-run): the same archive unsigned (CODE_SIGNING_ALLOWED=NO),
# no export and no upload; prints the steps a real run would take. Needs no credentials.
#
# Credentials (ios/README.md, "TestFlight"), from the environment, else from the gitignored
# ios/testflight.env (TESTFLIGHT_ENV_FILE for another file); DEVELOPMENT_TEAM also from
# ios/Local.xcconfig:
#   DEVELOPMENT_TEAM  the Apple Developer Team ID
#   ASC_KEY_ID        the App Store Connect API key's ID
#   ASC_ISSUER_ID     its issuer ID
#   ASC_KEY_PATH      the AuthKey_<id>.p8 file, outside the repo or gitignored
# The IDs are printed redacted only, and xcodebuild's output is filtered for them too.
#
# The build number (CFBundleVersion, every target) is TESTFLIGHT_BUILD_NUMBER, else the UTC
# time as YYYYMMDD.HHMMSS, which increases with the clock; one already archived here is
# refused. Nothing in the repo changes. The marketing version is MARKETING_VERSION in
# project.yml.
source "$(dirname "$0")/common.sh"
# Never traced: `bash -x` would print the credentials as they are read.
{ set +x; } 2>/dev/null

names=(DEVELOPMENT_TEAM ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH)
env_file="${TESTFLIGHT_ENV_FILE:-$IOS_DIR/testflight.env}"

# The last two characters only, so a log never carries a whole ID.
redact() {
  local value="$1"
  (( ${#value} > 4 )) || { echo "****"; return; }
  printf '%s%s\n' "$(printf '%*s' $(( ${#value} - 2 )) '' | tr ' ' '*')" "${value: -2}"
}

# A credential for printing: redacted, or <NAME> when unset.
shown() {
  if [[ -n "${!1:-}" ]]; then redact "${!1}"; else echo "<$1>"; fi
}

# KEY=VALUE lines of the env file, for the four names only. Read, never sourced: the file
# runs no code. Quotes around a value are dropped; the environment wins over the file.
load_env_file() {
  [[ -f "$env_file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
    # shellcheck disable=SC2088 # a literal ~/ in the file, expanded here
    [[ "$value" == "~/"* ]] && value="$HOME/${value#"~/"}"
    case " ${names[*]} " in *" $key "*) ;; *) continue ;; esac
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
  done <"$env_file"
}

# DEVELOPMENT_TEAM from ios/Local.xcconfig, where device builds already take it.
load_local_xcconfig() {
  [[ -z "${DEVELOPMENT_TEAM:-}" && -f "$IOS_DIR/Local.xcconfig" ]] || return 0
  DEVELOPMENT_TEAM="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]*).*/\1/p' \
    "$IOS_DIR/Local.xcconfig" | tail -1)"
}

# Every problem with the credentials, one per line (none when they are usable).
credential_problems() {
  local name
  for name in "${names[@]}"; do
    [[ -n "${!name:-}" ]] || echo "$name is not set"
  done
  [[ -z "${DEVELOPMENT_TEAM:-}" || "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] \
    || echo "DEVELOPMENT_TEAM is not a 10-character Team ID"
  [[ -z "${ASC_KEY_ID:-}" || "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || echo "ASC_KEY_ID is not a 10-character key ID"
  [[ -z "${ASC_ISSUER_ID:-}" || "$ASC_ISSUER_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] \
    || echo "ASC_ISSUER_ID is not an issuer ID (a UUID)"
  if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    if [[ ! -r "$ASC_KEY_PATH" ]]; then
      echo "ASC_KEY_PATH: no readable file there"
    elif ! grep -q "BEGIN PRIVATE KEY" "$ASC_KEY_PATH"; then
      echo "ASC_KEY_PATH: not a .p8 private key"
    elif git -C "$ROOT_DIR" ls-files --error-unmatch -- "$ASC_KEY_PATH" >/dev/null 2>&1; then
      echo "ASC_KEY_PATH: the key is tracked by git; remove it from the repo (git rm --cached) and rotate it"
    elif key_in_repo && ! git -C "$ROOT_DIR" check-ignore -q -- "$ASC_KEY_PATH"; then
      echo "ASC_KEY_PATH: the key is inside the repo and not gitignored; move it out (~/.appstoreconnect/private_keys)"
    fi
  fi
}

key_in_repo() {
  local dir
  dir="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)"
  [[ "$dir/" == "$(cd "$ROOT_DIR" && pwd -P)/"* ]]
}

# Replaces the IDs in xcodebuild's output with their redacted forms.
scrub() {
  local args=() name value
  for name in DEVELOPMENT_TEAM ASC_KEY_ID ASC_ISSUER_ID; do
    value="${!name:-}"
    [[ -n "$value" ]] && args+=(-e "s/$value/$(redact "$value")/g")
  done
  if (( ${#args[@]} )); then sed -l "${args[@]}"; else cat; fi
}

load_env_file
load_local_xcconfig

# Called back as the xcodebuild the watchdog runs (QUICKR_TF_SCRUB=1): xcodebuild with the
# IDs filtered out, so nothing unfiltered reaches the watchdog's log files either.
if [[ "${QUICKR_TF_SCRUB:-}" == 1 ]]; then
  xcodebuild "$@" 2>&1 | scrub
  exit "${PIPESTATUS[0]}"
fi

dry_run=0
case "${1:-}" in
--dry-run) dry_run=1 ;;
"") ;;
*) die "usage: testflight.sh [--dry-run]" ;;
esac

marketing="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' "$IOS_DIR/project.yml" | head -1)"
[[ -n "$marketing" ]] || die "no MARKETING_VERSION in ios/project.yml"
build="${TESTFLIGHT_BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M%S)}"
[[ "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
  || die "TESTFLIGHT_BUILD_NUMBER '$build' must be one to three period-separated integers (CFBundleVersion)"
(( ${#build} <= 18 )) || die "TESTFLIGHT_BUILD_NUMBER '$build' is longer than 18 characters"

problems="$(credential_problems)"
if (( !dry_run )) && [[ -n "$problems" ]]; then
  die "can't upload to TestFlight:
$(sed 's/^/  - /' <<<"$problems")
Set them in the environment or in $env_file (copy ios/testflight.env.example);
ios/README.md \"TestFlight\" lists what to get from App Store Connect.
make ios-testflight-dry-run archives without them."
fi
[[ -d "$PROJECT" ]] || die "no $PROJECT: run make ios-gen first"
require_xcodebuild

out="$BUILD_DIR/testflight/$marketing-$build"
archive="$out/QuickR.xcarchive"
options="$out/ExportOptions.plist"
# A build number is used once: App Store Connect refuses it again for the same version, and
# its directory holds that build's archive.
[[ ! -e "$out" ]] || die "build $marketing ($build) was already archived here (${out#"$IOS_DIR/"}); set another TESTFLIGHT_BUILD_NUMBER"
mkdir -p "$out"

echo "ios: TestFlight $( (( dry_run )) && echo "dry run" || echo upload ): version $marketing ($build)"
for name in DEVELOPMENT_TEAM ASC_KEY_ID ASC_ISSUER_ID; do
  if [[ -n "${!name:-}" ]]; then echo "  $name = $(shown "$name")"; else echo "  $name: not set"; fi
done
if [[ -n "${ASC_KEY_PATH:-}" ]]; then echo "  ASC_KEY_PATH: set"; else echo "  ASC_KEY_PATH: not set"; fi
if [[ -n "$problems" ]]; then
  echo "  a real run would stop here:"
  sed 's/^/    - /' <<<"$problems"
fi

# The export options: App Store Connect, uploaded straight from the export, signed
# automatically with the team; the build number is ours, not Xcode's.
team="${DEVELOPMENT_TEAM:-TEAMID}"  # a placeholder in a dry run without one
cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
plutil -lint "$options" >/dev/null || die "the export options $options are not a valid plist"

auth=()
if (( !dry_run )); then
  auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "ios: 1/3 archive (Release, generic/platform=iOS) -> ${archive#"$IOS_DIR/"}"
# Every xcodebuild runs as this script called back, which filters the IDs from its output.
export QUICKR_TF_SCRUB=1
XCODEBUILD="$IOS_DIR/scripts/testflight.sh"
if (( dry_run )); then
  xcb -configuration Release -destination "generic/platform=iOS" -archivePath "$archive" \
    CURRENT_PROJECT_VERSION="$build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
else
  xcb -configuration Release -destination "generic/platform=iOS" -archivePath "$archive" "${auth[@]}" \
    CURRENT_PROJECT_VERSION="$build" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic archive
fi

# Every bundle in the archive carries the build number (the extensions must match the app's).
app="$archive/Products/Applications/QuickR.app"
[[ -d "$app" ]] || die "the archive has no QuickR.app ($archive)"
while IFS= read -r plist; do
  got="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || true)"
  [[ "$got" == "$build" ]] || die "${plist#"$archive/"} has CFBundleVersion '$got', not $build"
done < <(find "$app" -name Info.plist -path "*.app/Info.plist" -o -name Info.plist -path "*.appex/Info.plist")
echo "ios: archive ok: every bundle is $marketing ($build)"

if (( dry_run )); then
  echo "ios: 2/3 export with ${options#"$IOS_DIR/"} (method app-store-connect, destination upload, team $(shown DEVELOPMENT_TEAM)): skipped"
  echo "ios: 3/3 upload: skipped; a real run's export uploads to App Store Connect itself:"
  echo "  xcodebuild -exportArchive -archivePath ${archive#"$IOS_DIR/"} -exportOptionsPlist ${options#"$IOS_DIR/"} \\"
  echo "    -exportPath ${out#"$IOS_DIR/"}/export -allowProvisioningUpdates -authenticationKeyPath <ASC_KEY_PATH> \\"
  echo "    -authenticationKeyID $(shown ASC_KEY_ID) \\"
  echo "    -authenticationKeyIssuerID $(shown ASC_ISSUER_ID)"
  echo "ios: dry run done (unsigned archive; nothing exported or uploaded)"
  exit 0
fi

echo "ios: 2/3 export and 3/3 upload to App Store Connect"
watchdog "$XCODEBUILD" -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
  -exportPath "$out/export" "${auth[@]}"
echo "ios: uploaded $marketing ($build). It shows in App Store Connect > TestFlight once processed (minutes);"
echo "  testers get it after the export-compliance question is answered there (ios/README.md, TestFlight)."
