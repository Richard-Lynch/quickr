# Codex review: M1 WP tools (round 2)

**REQUEST CHANGES**

Round-1 findings:

- **HTTP framing — NOT RESOLVED.** Upstream interim responses and HEAD/204/304 body suppression are fixed. However, `Rule.from_json` still accepts synthetic status 100–199; `_serve` sends only that interim response and resumes reading requests, never supplying a final response. Direct probe confirmed a lone `103` with keep-alive. Reject synthetic 1xx or implement a subsequent final response (`faultproxy.py:124–174`, status validation).

- **Hop-by-hop filtering — RESOLVED.** `end_to_end()` excludes fixed headers plus tokens from every Connection header; both forwarding and response encoding use it (`:117–121`).

- **Control validation crashes — NOT RESOLVED.** Missing-action, collection types, and CR/LF cases are fixed. But `{"action":"status","content_type":"😀"}` installs successfully, then raises `UnicodeEncodeError` at `:174`, terminating the affected proxy connection. `retry_after` has the same vulnerability. Validate header values against the actual wire encoding before installation.

- **Port allocation race — RESOLVED.** Docker binds ephemeral loopback ports; read-back occurs after successful `up --wait`. No cross-worktree allocation/read-back race found.

- **Startup leak — RESOLVED.** EXIT cleanup covers build, startup, health checks, and env publication; INT/TERM exit through it. Success is marked after atomic rename. No new Major from interaction with Make found.

- **Simulator basename keying — RESOLVED.** Canonical-path hash distinguishes identical basenames; mkdir lock serializes normal lookup/create/delete (`sim-clone.sh:20–34`).

- **Env quoting minor — RESOLVED.** Assignments use Bash `printf %q`.

- **Parser-hardening minor — RESOLVED** for the reported cases: chunk syntax/terminators, conflicting/negative lengths, body/trailer limits, and request deadlines now have checks.

**NEW Major — unsafe stale-lock takeover:** `sim-clone.sh:27–34` deletes a lock solely by age. A live clone exceeding ten minutes loses exclusion; its eventual EXIT trap can then remove another process’s replacement lock, admitting further concurrent operations. Use owner/liveness checks and ownership-verified cleanup.

No Blockers found. Direct Python probes confirmed both remaining proxy failures. Pytest was blocked by the sandbox’s temporary-file restriction; Docker/simulator behavior was reviewed statically.