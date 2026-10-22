# Codex review: M1 WP TOOLS (round 4, approved with minors)

**APPROVE WITH MINORS.** The takeover race is **RESOLVED**. The persistent lock file is never unlinked, so delayed contenders cannot remove a replacement owner’s lock.

**No new Blocker/Major found.** macOS supports this fd-only invocation: `lockf` acquires `flock(LOCK_EX)` on inherited fd 9 and exits without unlocking it; the shell’s reference keeps the lock alive. All simulator lookup/create/delete operations remain inside its scope. Timeout failure stops execution before simulator operations. [Apple implementation](https://github.com/apple-oss-distributions/shell_cmds/blob/main/lockf/lockf.c)

Two minors:

- **Lifetime wording:** release occurs when the **last reference** closes. Children inherit fd 9, so a surviving child can retain the lock after the shell dies. Foreground `simctl` execution makes this reasonable; no demonstrated persistent leak. Update the comment/README’s unconditional “holder exits or dies” claim.
- **Error reporting:** every acquisition failure is labelled “timed out,” including invalid timeout values and descriptor errors. Preserve or distinguish the underlying failure.

The default scope remains callers sharing the same `TMPDIR`/override path; different paths do not serialize.

Validation: commit and Apple source review; no simulator execution.