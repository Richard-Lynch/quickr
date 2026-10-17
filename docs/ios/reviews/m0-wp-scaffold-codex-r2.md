# Codex review: M0 WP scaffold (round 2)

**APPROVE**

- **Makefile path filter — RESOLVED.** `.github/workflows/ios.yml` includes `Makefile` in both push and pull-request path filters.

- **CI requires iOS 26.x — RESOLVED.** `check-ci.sh` uses `sim-ios26.sh`, which filters runtime identifiers explicitly to iOS 26.x and available iPhones, then passes the selected UDID to testing. Mocked mixed 26/27 inventory selected 26.2; a 27-only inventory failed explicitly.

- **Lockfile — RESOLVED.** The canonical `ios/QuickrKit/Package.resolved` is not ignored. `gen.sh` copies it into the generated workspace; host tests and Xcode conditionally enforce its versions; `resolved-check.sh` compares package identities, versions and revisions. `make ios-resolve` provides the update path. No lockfile is needed for the current dependency-free package.

- **Lint failing when unavailable — RESOLVED.** `check-ios.sh` invokes strict `lint.sh`, which fails if swift-format is missing. Only the explicitly optional standalone `ios-lint` target may skip.

- **Host cache key — RESOLVED.** The key now includes runner architecture and a hash of Xcode/Swift version output, alongside manifest/lockfile hashes.

- **Recorder trap — RESOLVED.** An EXIT trap is installed immediately after capturing the recorder PID; it sends SIGINT, waits, and preserves the original exit status.

**New Blocker/Major: none found.** The suggested first-resolution regression is absent: strict-resolution flags are added only when the canonical lockfile exists (`common.sh:57,69`; `resolve.sh:9`). `ios-resolve` runs unrestricted `swift package update` before copying and enforcing pins. Mocked host invocation confirmed correct argument expansion with and without a lockfile.

Validation: all script syntax checks passed; simulator selection and host argument handling were mocked. Actual Xcode resolution/builds were not run under the read-only sandbox.