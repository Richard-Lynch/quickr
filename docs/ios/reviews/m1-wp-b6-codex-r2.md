# Codex review: M1 WP B6 (round 2)

**REQUEST CHANGES**

Round-1 findings:

- **Lifespan order — RESOLVED.** `main.py` enters APNs before the scheduler, so scheduler cancellation completes before APNs closes. `_closed` prevents reconnection; shutdown leaves `get_sender()` returning `None`. The new application-level test checks cancellation before connection closure.
- **Tick budget — RESOLVED for bounding delivery.** `push/__init__.py:145–148` wraps semaphore acquisition and sending in `asyncio.timeout_at(deadline)`. Cut-off sends receive no success/failure bookkeeping, and incomplete topics remain unmarked. However, the retry strategy introduces the Major below.
- **Device tokens in logs — RESOLVED for the reported paths.** The `httpx` filter redacts device paths; APNs transport failures redact messages and suppress exception chaining; expected `PushFailed` outcomes are logged without tracebacks. Added tests cover script success and URL-bearing transport failures. Web Push also sanitizes failures and urllib3 request lines.
- **Partial sandbox override — RESOLVED.** `ApnsConfig.from_settings()` rejects ID-only, PEM-only, and file-only overrides; `_load()` logs the configuration error and disables APNs. Tests cover these combinations.

**NEW Major — repeated deadlines can permanently starve targets and later topics.** `scheduler.py:97–107` retries an incomplete topic from the beginning; `deliver()` always schedules targets in the same order. When fan-out consistently exceeds the budget, earlier targets repeatedly succeed while the tail never receives the notification. The topic never gets marked, and subsequent topics also remain blocked.

I reproduced this using the actual `deliver()` with 20 targets, eight concurrent sends, 30 ms/send, and a 75 ms budget: **three consecutive attempts each delivered the first 16; targets 16–19 never received anything**. The added test avoids this condition by increasing the second tick’s budget to 30 seconds.

Persist progress per slot/target, or otherwise guarantee forward progress across bounded ticks; add a repeated-tick test retaining the same insufficient budget.

No additional Blocker/Major identified in deferred outcome flushing, closed-sender behavior, or sanitized diagnostics. ORM changes flush immediately before marking/commit, with deleted targets skipped between topics.

Validation: focused reproduction executed; full test suite inspected, not run.