# Codex review: M0 WP scaffold (round 1)

REQUEST CHANGES

No confirmed Blockers. Two Major gate gaps should be fixed before merging.

- **Major — `.github/workflows/ios.yml:10,13`: Makefile changes bypass iOS CI.** A PR changing only an iOS Make target runs neither job, despite changing the canonical CI/build interface. Add `Makefile` to both path filters. The PR trigger otherwise includes PRs into `feat/ios-app`; draft skipping and `ready_for_review` handling are correct.

- **Major — `ios/scripts/common.sh:29`, `.github/workflows/ios.yml:70`: CI does not enforce the required iOS 26.x runtime.** Looking up `"iPhone 17"` chooses the first matching device across all runtimes. Ordering is assumed, and a future image containing only an iOS 27 device could silently pass the gate, violating PLAN §6a rule 12. Parse `simctl list --json`, select an available device belonging to an iOS 26.x runtime, and fail explicitly when none exists. Keep general simulator selection separate from this CI requirement.

- **Minor — `.gitignore:16`: the Xcode dependency lockfile is ignored.** `git check-ignore` confirms that `ios/quickR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is excluded. Once GRDB arrives, Xcode resolution can drift despite PLAN §2 requiring a committed lockfile. Ignore project contents selectively and allow the workspace lockfile, or maintain a tracked canonical lockfile with explicit restore/update steps. Ensure host SwiftPM and Xcode resolve the same versions.

- **Minor — `ios/scripts/lint.sh:4`: the local gate can pass without linting.** Missing `swift-format` produces success, although PLAN §8 makes lint part of `make check-ios`. Fail with an actionable error when the formatter is unavailable. An optional standalone lint mode can remain separate.

- **Minor — `.github/workflows/ios.yml:42`: host build cache omits toolchain identity.** The same `.build` cache key survives Xcode/compiler and runner-architecture changes. Include architecture and the selected Xcode version, preferably the compiler build identity. The checkout cache at line 67 has less exposure because it stores source checkouts rather than host build products.

- **Minor — `ios/scripts/demo-record.sh:16`: recorder cleanup is missing on failure.** If launch, sleep, or another intervening command fails, `set -e` exits while `simctl recordVideo` remains running. Install an EXIT trap immediately after capturing its PID, terminate/wait for the recorder there, and preserve the original failure status.

The inspected generated project embeds both extensions, and its app/test identifiers match the committed test plans. Bundle IDs, App Group, keychain prefix, deployment target, iPhone family, required Info.plist entries, and Swift 6 language settings look consistent. The package’s UI guard preserves macOS host compilation; adding App Intents later will need the same platform discipline. Adding QuickrData dependencies to the extensions can wait until they consume shared storage.

GitHub’s [macOS 26 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) lists the configured Xcode 26.6 path. Permissions are read-only, no secrets are referenced, and actions use full SHAs. Download checksum enforcement is present, but I could not independently retrieve the release archive to verify the literal digest.

Validation was read-only: shell syntax and `make -n check` passed inspection; `make check` remains Xcode-free. Builds/tests and existing result-bundle inspection were prevented by sandbox write restrictions.