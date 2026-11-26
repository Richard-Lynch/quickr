"""Run fold vectors: ``shared/fixtures/run-fold-vectors.json``.

Generated from ``app/services/run_fold.py``: a run's events in arrival order, folded over its
version's timer into its state and (when stopped) its timing (docs/specs/timers.md §4, §2.3,
as changed by timers2.md §3: fold v4). The PWA (``runFold.vectors.test.ts``) and the iOS app
(QuickrCore ``RunFoldVectorTests``) fold the same events with their ports and must reach the
same state, effects and timing (spec test R1); the backend runs them through the real
endpoint (T1, timers2.md T18). ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the
file; otherwise the committed file must match.

The case list of timers2.md §12.1 is read from the spec (``tests/spec_cases.py``) by
:func:`test_vectors_cover_timers2`.
"""

from __future__ import annotations

from typing import Any

from app.schemas.questions import Timer as Timer_v2
from app.services import run_fold
from app.services.run_fold import Event, Frozen, FrozenReason, LapType, Step, Timer
from tests.spec_cases import run_fold_v4_cases
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "run-fold-vectors.json"
GENERATOR_VERSION = 4

RUN = "0a000000-0000-4000-8000-000000000000"
T0 = run_fold.parse_instant("2026-10-23T08:00:00Z")

# timers2.md §3.1: the timers the cases run on, as sent. ``TIMER_SETS`` is each one's normalised
# ``Timer`` v2 output (every list present, ``at_ms`` filled), what a topic version serves; the fold
# reads its steps and lap types.
TIMERS_IN: dict[str, dict[str, list[dict[str, str]]]] = {
    "none": {"steps": [], "laps": []},
    "two": {
        "steps": [{"key": "shower", "label": "Shower"}, {"key": "breakfast", "label": "Breakfast"}],
        "laps": [],
    },
    "three": {
        "steps": [
            {"key": "shower", "label": "Shower"},
            {"key": "breakfast", "label": "Breakfast"},
            {"key": "dress", "label": "Get dressed"},
        ],
        "laps": [],
    },
    "renamed": {"steps": [], "laps": [{"key": "cig", "label": "Cig"}]},
    "tiktok": {"steps": [], "laps": [{"key": "run", "label": "Run"}, {"key": "rest", "label": "Rest"}]},
    "three_types": {
        "steps": [{"key": "warmup", "label": "Warmup"}],
        "laps": [
            {"key": "run", "label": "Run"},
            {"key": "rest", "label": "Rest"},
            {"key": "walk", "label": "Walk"},
        ],
    },
}


def normalised(timer: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = Timer_v2.model_validate(timer).model_dump(mode="json")
    return out


TIMER_SETS: dict[str, dict[str, Any]] = {name: normalised(t) for name, t in TIMERS_IN.items()}


def eid(n: int) -> str:
    return f"0e000000-0000-4000-8000-{n:012d}"


def at(seconds: float | str) -> str:
    """``T0 + seconds`` as a wire string; a string is taken as given."""
    if isinstance(seconds, str):
        return seconds
    return run_fold.format_instant(T0 + round(seconds * 1000))


def ev(
    n: int | str,
    type_: str,
    seconds: float | str,
    seg: int | None = None,
    step: str | None = None,
    pause: int | str | None = None,
    target: int | str | None = None,
) -> dict[str, Any]:
    """An event as the vectors carry it. ``n`` 0 is the run's start; a string is the id.
    ``target`` (reopen, remove) is an event number or an id."""
    pause_id = eid(pause) if isinstance(pause, int) else pause
    return {
        "id": n if isinstance(n, str) else RUN if n == 0 else eid(n),
        "type": type_,
        "at": at(seconds),
        "seg": seg,
        "step": step,
        "pause_id": pause_id,
        "target": eid(target) if isinstance(target, int) else target,
    }


START = ev(0, "start", 0)
DAY = 24 * 60 * 60
# Two ids whose order differs between raw and lowercase comparison ("B" < "a" < "b").
UPPER_B = "0e000000-0000-4000-8000-00000000000B"
LOWER_A = "0e000000-0000-4000-8000-00000000000a"
# A pause whose id is uppercase, named in lowercase by a resume whose id sorts before it.
UPPER_PAUSE = "0e000000-0000-4000-8000-00000000000D"
LOWER_RESUME = "0e000000-0000-4000-8000-00000000000c"

# name -> (timer set, events in arrival order, frozen as (after, reason) or None)
CASES: dict[str, tuple[str, list[dict[str, Any]], tuple[int, FrozenReason] | None]] = {
    "sub-millisecond-instants-truncated": (
        "none",
        [
            ev(0, "start", "2026-10-23T08:00:00.000999Z"),
            ev(1, "lap", "2026-10-23T08:00:01.001999+00:00", seg=0),
            ev(2, "pause", "2026-10-23T09:00:01.500500+01:00"),
            ev(3, "resume", "2026-10-23T08:00:01.700999Z", pause=2),
            ev(4, "stop", "2026-10-23T03:00:02.002999-05:00"),
        ],
        None,
    ),
    "no-steps-start-stop": ("none", [START, ev(1, "stop", 442)], None),
    "no-steps-open": ("none", [START], None),
    "laps": ("none", [START, ev(1, "lap", 60, seg=0), ev(2, "lap", 130, seg=1), ev(3, "stop", 200)], None),
    "three-steps-all-done": (
        "three",
        [START, ev(1, "next", 252, seg=0), ev(2, "next", 900, seg=1), ev(3, "stop", 1200)],
        None,
    ),
    "three-steps-open-on-second": ("three", [START, ev(1, "next", 252, seg=0)], None),
    "lap-between-steps": (
        "two",
        [START, ev(1, "lap", 100, seg=0), ev(2, "next", 150, seg=1), ev(3, "stop", 400)],
        None,
    ),
    "next-after-last-step": (
        "two",
        [
            START,
            ev(1, "next", 100, seg=0),
            ev(2, "next", 200, seg=1),
            ev(3, "next", 260, seg=2),
            ev(4, "stop", 300),
        ],
        None,
    ),
    "skip-on-a-step": (
        "three",
        [START, ev(1, "skip", 30, seg=0, step="shower"), ev(2, "next", 400, seg=0), ev(3, "stop", 700)],
        None,
    ),
    "skip-last-step-relabels-to-lap": (
        "two",
        [START, ev(1, "next", 100, seg=0), ev(2, "skip", 120, seg=1, step="breakfast")],
        None,
    ),
    "skip-from-a-lap": (
        "three",
        [
            START,
            ev(1, "lap", 50, seg=0),
            ev(2, "skip", 60, seg=1, step="breakfast"),
            ev(3, "next", 90, seg=1),
            ev(4, "stop", 300),
        ],
        None,
    ),
    "skip-from-a-lap-wrong-step-stale": (
        "three",
        [START, ev(1, "lap", 50, seg=0), ev(2, "skip", 60, seg=1, step="dress")],
        None,
    ),
    "skip-from-a-lap-no-step": (
        "none",
        [START, ev(1, "skip", 60, seg=0, step="shower"), ev(2, "stop", 100)],
        None,
    ),
    "skip-stale-seg": (
        "three",
        [START, ev(1, "lap", 50, seg=0), ev(2, "lap", 60, seg=1), ev(3, "skip", 65, seg=1, step="breakfast")],
        None,
    ),
    "double-tapped-skip": (
        "three",
        [
            START,
            ev(1, "skip", 30, seg=0, step="shower"),
            ev(2, "skip", 31, seg=0, step="shower"),
            ev(3, "stop", 100),
        ],
        None,
    ),
    "resume-at-the-pause-instant": (
        "none",
        # The resume's id sorts before its pause's: it still applies after it.
        [START, ev(9, "pause", 60), ev(3, "resume", 60, pause=9), ev(4, "stop", 90)],
        None,
    ),
    "resume-at-the-pause-instant-mixed-case": (
        "none",
        # Ids compare lowercase: the resume names its pause in another case, and still sorts
        # right after it.
        [
            START,
            ev(UPPER_PAUSE, "pause", 60),
            ev(LOWER_RESUME, "resume", 60, pause=UPPER_PAUSE.lower()),
            ev(4, "stop", 90),
        ],
        None,
    ),
    "stopped-before-the-last-step": ("three", [START, ev(1, "next", 100, seg=0), ev(2, "stop", 200)], None),
    "pause-resume": (
        "none",
        [START, ev(1, "pause", 60), ev(2, "resume", 90, pause=1), ev(3, "stop", 120)],
        None,
    ),
    "paused-open-run": ("two", [START, ev(1, "next", 10, seg=0), ev(2, "pause", 20)], None),
    "double-pause-and-stray-resume": (
        "none",
        [
            START,
            ev(1, "resume", 5, pause=9),
            ev(2, "pause", 10),
            ev(3, "pause", 11),
            ev(4, "resume", 20, pause=2),
            ev(5, "stop", 30),
        ],
        None,
    ),
    "resume-naming-an-older-pause": (
        "none",
        [
            START,
            ev(1, "pause", 60),
            ev(2, "resume", 120, pause=1),
            ev(3, "pause", 180),
            ev(5, "resume", 300, pause=3),
            ev(4, "resume", 240, pause=1),  # offline, arrives last
            ev(6, "stop", 360),
        ],
        None,
    ),
    "next-while-paused": (
        "two",
        [
            START,
            ev(1, "pause", 60),
            ev(2, "next", 90, seg=0),
            ev(3, "resume", 150, pause=1),
            ev(4, "stop", 200),
        ],
        None,
    ),
    "next-while-paused-pause-open": (
        "two",
        # The closed segment's paused_ms runs from the open pause to the segment's end.
        [START, ev(1, "pause", 60), ev(2, "next", 90, seg=0)],
        None,
    ),
    "stop-while-paused": (
        "two",
        [START, ev(1, "next", 30, seg=0), ev(2, "pause", 60), ev(3, "stop", 100)],
        None,
    ),
    "double-next-two-devices": (
        "three",
        [START, ev(2, "next", 101, seg=0), ev(1, "next", 100, seg=0), ev(3, "stop", 200)],
        None,
    ),
    "stale-seg": ("three", [START, ev(1, "next", 100, seg=1), ev(2, "lap", 110, seg=4)], None),
    "offline-taps-after-stop": (
        "three",
        [START, ev(1, "stop", 600), ev(2, "next", 200, seg=0), ev(3, "lap", 700, seg=1)],
        None,
    ),
    "late-merge-turns-next-stale": (
        "three",
        [START, ev(1, "next", 300, seg=0), ev(2, "stop", 600), ev(3, "next", 240, seg=0)],
        None,
    ),
    "edited-run-late-taps": (
        "three",
        [START, ev(1, "next", 300, seg=0), ev(2, "stop", 600), ev(3, "next", 240, seg=0), ev(4, "stop", 610)],
        (3, "run_edited"),
    ),
    "entry-deleted-late-taps": (
        "two",
        [START, ev(1, "stop", 600), ev(2, "next", 240, seg=0)],
        (2, "entry_deleted"),
    ),
    "discarded-late-taps": (
        "two",
        [START, ev(1, "next", 100, seg=0), ev(2, "discard", 200), ev(3, "lap", 150, seg=1)],
        (3, "already_closed"),
    ),
    "two-stops": ("none", [START, ev(1, "stop", 100), ev(2, "stop", 90)], None),
    "discard-then-stop": (
        "two",
        [START, ev(1, "next", 50, seg=0), ev(2, "discard", 100), ev(3, "stop", 120)],
        None,
    ),
    "next-at-the-start-instant": (
        "two",
        [START, ev(1, "next", 0, seg=0), ev(2, "stop", 50)],
        None,
    ),
    "uppercase-run-id": (
        "two",
        [
            {**START, "id": RUN.upper()},
            ev(1, "next", 30, seg=0),
            ev(RUN.upper(), "start", 0),
            ev(2, "stop", 60),
        ],
        None,
    ),
    "stop-at-a-next-instant": ("two", [START, ev(1, "next", 100, seg=0), ev(2, "stop", 100)], None),
    "equal-at-tie-break-by-id": (
        "three",
        [START, ev(UPPER_B, "next", 100, seg=0), ev(LOWER_A, "next", 100, seg=0), ev(3, "stop", 200)],
        None,
    ),
    "events-before-start": (
        "two",
        [START, ev(1, "next", -5, seg=0), ev(2, "pause", -1), ev(3, "stop", 50)],
        None,
    ),
    "client-stop-before-start": (
        "none",
        [START, ev(1, "stop", -10), ev(2, "stop", 20), ev(3, "stop", -5)],
        None,
    ),
    "too-long": (
        "none",
        [
            START,
            ev(1, "lap", 7 * DAY, seg=0),
            ev(2, "lap", 7 * DAY + 0.001, seg=1),
            ev(3, "stop", 7 * DAY + 1),
        ],
        None,
    ),
    "merged-start": ("two", [START, ev(1, "start", -60), ev(2, "next", 30, seg=0)], None),
    "replayed-event": (
        "two",
        [START, ev(1, "next", 30, seg=0), ev(1, "next", 30, seg=0), ev(0, "start", 0), ev(2, "stop", 60)],
        None,
    ),
    "finish-has-no-effect": ("none", [START, ev(1, "stop", 60), ev(2, "finish", 70)], None),
    # After a valid stop, after_stop is checked before too_long (the lap is within the server's
    # `now + 24 h` bound in test_api_runs.py's T1 run).
    "after-stop-beyond-the-limit": (
        "none",
        [START, ev(1, "stop", 100), ev(2, "lap", 7 * DAY + 3600, seg=0)],
        None,
    ),
    # The open pause covers the whole second segment: its overlap is clamped to the segment's start.
    "next-twice-while-paused-open": (
        "three",
        [START, ev(1, "pause", 30), ev(2, "next", 60, seg=0), ev(3, "next", 100, seg=1)],
        None,
    ),
    # A discard drops the open pause: no paused_since, and no open-pause overlap in the segments.
    "pause-then-discard": (
        "two",
        [START, ev(1, "pause", 10), ev(2, "next", 20, seg=0), ev(3, "discard", 60)],
        None,
    ),
    "resume-uppercase-pause-id": (
        "two",
        [START, ev(1, "pause", 30), ev(2, "resume", 60, pause=eid(1).upper()), ev(3, "stop", 100)],
        None,
    ),
    # The same id in another case is a replay, not a second event (the server answers a replay
    # with other content 409, so the content is the same).
    "replayed-event-id-case": (
        "two",
        [START, ev(1, "next", 30, seg=0), ev(eid(1).upper(), "next", 30, seg=0), ev(2, "stop", 60)],
        None,
    ),
}


# Fold v4 (timers2.md §12.1): lap types, reopen, remove. Times in seconds from T0.
CASES |= {
    # §3.2 lap labelling
    "renamed-laps": (
        "renamed",
        [START, ev(1, "lap", 60, seg=0), ev(2, "lap", 130, seg=1), ev(3, "stop", 200)],
        None,
    ),
    "tiktok-cycle": (
        "tiktok",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "lap", 120, seg=1),
            ev(3, "lap", 180, seg=2),
            ev(4, "lap", 240, seg=3),
            ev(5, "stop", 300),
        ],
        None,
    ),
    "three-types-with-step": (
        "three_types",
        [
            START,
            ev(1, "next", 60, seg=0),
            ev(2, "lap", 120, seg=1),
            ev(3, "lap", 180, seg=2),
            ev(4, "lap", 240, seg=3),
            ev(5, "lap", 270, seg=4),
            ev(6, "stop", 300),
        ],
        None,
    ),
    # §3.4 reopen
    "reopen-accidental-stop": (  # §6.1
        "none",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "stop", 90),
            ev(10, "finish", 95),
            ev(3, "reopen", 110, target=2),
            ev(4, "lap", 150, seg=1),
            ev(5, "stop", 180),
        ],
        None,
    ),
    "reopen-then-restop-labels": (
        "renamed",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "stop", 90),
            ev(3, "reopen", 110, target=2),
            ev(4, "lap", 150, seg=1),
            ev(5, "stop", 180),
        ],
        None,
    ),
    "reopen-not-terminal": (
        "none",
        [START, ev(1, "stop", 60), ev(2, "stop", 70), ev(3, "reopen", 80, target=2)],
        None,
    ),
    "reopen-unknown-target": ("none", [START, ev(1, "stop", 60), ev(2, "reopen", 80, target=99)], None),
    "reopen-after-discard": (
        "none",
        [START, ev(1, "discard", 60), ev(2, "stop", 70), ev(3, "reopen", 80, target=2)],
        None,
    ),
    "reopen-stale-at": ("none", [START, ev(1, "stop", 60), ev(2, "reopen", 60, target=1)], None),
    "reopen-too-long": (
        "none",
        [START, ev(1, "stop", 7 * DAY - 10), ev(2, "reopen", 7 * DAY + 0.001, target=1)],
        None,
    ),
    "reopen-double-tap": (
        "none",
        [START, ev(1, "stop", 60), ev(2, "reopen", 80, target=1), ev(3, "reopen", 80.3, target=1)],
        None,
    ),
    "reopen-revert-by-discard": (  # §6.2
        "none",
        [
            START,
            ev(1, "stop", 90),
            ev(2, "reopen", 110, target=1),
            ev(3, "lap", 130, seg=0),
            ev(4, "discard", 150),
        ],
        None,
    ),
    "reopen-revert-then-reopen-again": (
        "none",
        [
            START,
            ev(1, "stop", 90),
            ev(2, "reopen", 110, target=1),
            ev(3, "discard", 150),
            ev(4, "reopen", 160, target=1),
            ev(5, "lap", 170, seg=0),
        ],
        None,
    ),
    "reopen-second-stop-new-terminal": (
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 80, target=1),
            ev(3, "lap", 100, seg=0),
            ev(4, "stop", 120),
        ],
        None,
    ),
    "stop-reopen-stop-reopen-discard-discard": (
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 70, target=1),
            ev(3, "stop", 90),
            ev(4, "reopen", 100, target=3),
            ev(5, "discard", 110),  # reverts reopen 4: stop 3 is the terminal again
            ev(6, "discard", 120),  # already_closed, never a revert of reopen 2
        ],
        None,
    ),
    "stop-reopen-remove-gap-revert-reopen-remove-gap-revert": (
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 70, target=1),
            ev(3, "remove", 75, target=1),
            ev(4, "discard", 80),  # revert: stop 1 applied again, remove 3 no_target
            ev(5, "reopen", 90, target=1),
            ev(6, "remove", 95, target=1),  # eligible again: effects are recomputed from scratch
            ev(7, "discard", 100),  # revert: remove 6 no_target in turn
        ],
        None,
    ),
    "reopen-offline-stop-earlier-than-reopen": (
        "none",
        [
            START,
            ev(1, "stop", 10),
            ev(2, "reopen", 30, target=1),
            ev(3, "lap", 35, seg=0),
            ev(4, "stop", 20),  # another device's offline stop: the new terminal
        ],
        None,
    ),
    "reopen-while-paused-ends-pause": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "stop", 60),
            ev(3, "reopen", 90, target=2),
            ev(4, "resume", 100, pause=1),  # the reopen ended the pause: not_paused
            ev(5, "stop", 120),
        ],
        None,
    ),
    "reopen-gap-removed-user-pause-inside-gap": (
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 90, target=1),
            ev(3, "remove", 95, target=1),
            ev(4, "pause", 70),  # offline, inside the (removed) gap
            ev(5, "resume", 100, pause=4),  # the reopen ended it: not_paused
            ev(6, "stop", 120),
        ],
        None,
    ),
    "resume-inside-gap-stale": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "stop", 60),
            ev(3, "reopen", 90, target=2),
            ev(4, "resume", 70, pause=1),  # offline, inside the gap: the gap owns the pause
            ev(5, "stop", 120),
        ],
        None,
    ),
    "gap-pause-equal-time-user-resume": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "stop", 60),
            ev(3, "reopen", 90, target=2),
            ev(4, "resume", 60, pause=1),  # at the stop's instant: the gap pause sorts first
            ev(5, "stop", 120),
        ],
        None,
    ),
    "gap-resume-equal-time-user-pause": (
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 90, target=1),
            ev(3, "pause", 90),  # at the reopen's instant: the gap still owns the pause
            ev(4, "stop", 120),
        ],
        None,
    ),
    "two-gap-pauses-equal-time": (
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 80, target=1),
            ev(3, "stop", 60),  # an offline stop at the same instant: the new terminal
            ev(4, "reopen", 100, target=3),
            ev(5, "stop", 120),
        ],
        None,
    ),
    "reopen-lap-inside-gap": (  # §6.6
        "none",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "stop", 120),
            ev(3, "lap", 130, seg=1),  # device B, offline
            ev(4, "reopen", 150, target=2),
            ev(5, "stop", 180),
        ],
        None,
    ),
    # §3.4 remove
    "remove-pause": (  # §6.3 (a)
        "none",
        [
            START,
            ev(1, "pause", 60),
            ev(2, "resume", 80, pause=1),
            ev(3, "lap", 120, seg=0),
            ev(4, "remove", 130, target=1),
        ],
        None,
    ),
    "remove-pause-resume-deleted": (
        "none",
        [
            START,
            ev(1, "pause", 60),
            ev(2, "remove", 70, target=1),
            ev(3, "resume", 80, pause=1),
            ev(4, "stop", 100),
        ],
        None,
    ),
    "remove-void-pause-noop": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "pause", 40),  # already_paused
            ev(3, "resume", 50, pause=2),  # stale before the remove, deleted after it
            ev(4, "resume", 60, pause=1),
            ev(5, "remove", 70, target=2),
            ev(6, "stop", 100),
        ],
        None,
    ),
    "remove-pause-changes-which-pause-applies": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "pause", 40),  # already_paused under pause 1, applied once it is removed
            ev(3, "resume", 60, pause=2),
            ev(4, "remove", 70, target=1),
            ev(5, "stop", 100),
        ],
        None,
    ),
    "remove-gap-pause": (  # §6.3 (b)
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 90, target=1),
            ev(3, "remove", 100, target=1),
            ev(4, "stop", 120),
        ],
        None,
    ),
    "remove-lap-merges-previous": (
        "none",
        [START, ev(1, "lap", 60, seg=0), ev(2, "remove", 90, target=1), ev(3, "stop", 120)],
        None,
    ),
    "remove-lap-renumbers-types": (  # §6.4
        "tiktok",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "lap", 60.4, seg=1),
            ev(3, "lap", 120, seg=2),
            ev(4, "remove", 125, target=2),
            ev(5, "lap", 150, seg=2),
        ],
        None,
    ),
    "remove-lap-ghost-keeps-later-lap-applied": (
        "none",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "lap", 120, seg=1),  # its device saw lap 1: still applied after the remove
            ev(3, "remove", 130, target=1),
            ev(4, "lap", 150, seg=1),  # after the remove: the renumbered seg
            ev(5, "stop", 180),
        ],
        None,
    ),
    "remove-two-laps-ghosts-stack": (
        "none",
        [
            START,
            ev(1, "lap", 30, seg=0),
            ev(2, "lap", 60, seg=1),
            ev(3, "lap", 90, seg=2),
            ev(4, "remove", 100, target=1),
            ev(5, "remove", 101, target=2),
            ev(6, "stop", 120),
        ],
        None,
    ),
    "remove-stale-lap-no-ghost": (
        "none",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "lap", 61, seg=0),  # a stale double tap
            ev(3, "remove", 70, target=2),
            ev(4, "lap", 90, seg=1),
            ev(5, "stop", 120),
        ],
        None,
    ),
    "remove-lap-after-stop-late-merge": (  # §6.5
        "renamed",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "lap", 65, seg=1),
            ev(3, "stop", 180),
            ev(4, "remove", 220, target=1),
        ],
        None,
    ),
    "remove-lap-after-stop-then-late-lap": (  # §6.5, the late lap from another device
        "renamed",
        [
            START,
            ev(1, "lap", 60, seg=0),
            ev(2, "lap", 65, seg=1),
            ev(3, "stop", 180),
            ev(4, "remove", 220, target=1),
            ev(5, "lap", 120, seg=2),
        ],
        None,
    ),
    "remove-years-later-applies": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "resume", 40, pause=1),
            ev(3, "stop", 60),
            ev(4, "remove", 400 * DAY, target=1),
        ],
        None,
    ),
    "remove-next-is-no-target": (
        "two",
        [START, ev(1, "next", 60, seg=0), ev(2, "remove", 70, target=1)],
        None,
    ),
    "remove-terminal-stop-no-target": (
        "none",
        [START, ev(1, "stop", 60), ev(2, "remove", 70, target=1)],
        None,
    ),
    "remove-twice-no-target": (
        "none",
        [START, ev(1, "pause", 30), ev(2, "remove", 40, target=1), ev(3, "remove", 41, target=1)],
        None,
    ),
    "remove-at-before-target-no-target": (
        "none",
        [START, ev(1, "pause", 30), ev(2, "remove", 30, target=1), ev(3, "remove", 29, target=1)],
        None,
    ),
    "remove-then-revert-restores-stop": (  # §6.3 (b), the discard instead
        "none",
        [
            START,
            ev(1, "stop", 60),
            ev(2, "reopen", 90, target=1),
            ev(3, "remove", 100, target=1),
            ev(4, "discard", 110),
        ],
        None,
    ),
    # §3.3 event ids
    "timing-carries-event-ids": (
        "three_types",
        [
            START,
            ev(1, "next", 30, seg=0),
            ev(2, "pause", 40),
            ev(3, "resume", 50, pause=2),
            ev(4, "lap", 70, seg=1),
            ev(5, "stop", 90),
            ev(6, "reopen", 100, target=5),
            ev(7, "stop", 120),
        ],
        None,
    ),
    # §3.6 late merges: the server's cut-off
    "frozen-reopen-run-edited": (
        "none",
        [START, ev(1, "stop", 60), ev(2, "reopen", 80, target=1)],
        (2, "run_edited"),
    ),
    "frozen-remove-entry-deleted": (
        "none",
        [
            START,
            ev(1, "pause", 30),
            ev(2, "resume", 40, pause=1),
            ev(3, "stop", 60),
            ev(4, "remove", 80, target=1),
        ],
        (4, "entry_deleted"),
    ),
}

# Stored timings decoded as every client decodes ``entries.timing`` (timers2.md §3.3): a pre-v2
# timing has no event ids, no lap types and no terminal id; each reads back null.
PRE_V2_TIMING: dict[str, Any] = {
    "started_at": "2026-10-23T08:00:00Z",
    "ended_at": "2026-10-23T08:01:30Z",
    "active_ms": 80_000,
    "paused_ms": 10_000,
    "complete": True,
    "edited": False,
    "segments": [
        {
            "kind": "lap",
            "step": None,
            "label": "Lap 1",
            "started_at": "2026-10-23T08:00:00Z",
            "ended_at": "2026-10-23T08:01:00Z",
            "active_ms": 50_000,
            "paused_ms": 10_000,
        },
        {
            "kind": "lap",
            "step": None,
            "label": "Lap 2",
            "started_at": "2026-10-23T08:01:00Z",
            "ended_at": "2026-10-23T08:01:30Z",
            "active_ms": 30_000,
            "paused_ms": 0,
        },
    ],
    "skipped": [],
    "pauses": [{"start": "2026-10-23T08:00:20Z", "end": "2026-10-23T08:00:30Z"}],
}
TIMINGS: dict[str, dict[str, Any]] = {"timing-pre-v2-null-ids": PRE_V2_TIMING}


def to_event(d: dict[str, Any]) -> Event:
    return Event(
        id=d["id"],
        type=d["type"],
        at=run_fold.parse_instant(d["at"]),
        seg=d["seg"],
        step=d["step"],
        pause_id=d["pause_id"],
        target=d["target"],
    )


def to_timer(d: dict[str, Any]) -> Timer:
    """The fold's view of a served timer: steps and lap types (alerts and variables aren't
    fold inputs)."""
    return Timer(
        steps=[Step(s["key"], s["label"]) for s in d["steps"]],
        laps=[LapType(t["key"], t["label"]) for t in d["laps"]],
    )


def timer_of(name: str) -> Timer:
    return to_timer(TIMER_SETS[name])


def fold_case(
    timer: str, events: list[dict[str, Any]], frozen: tuple[int, FrozenReason] | None
) -> run_fold.RunState:
    return run_fold.fold(
        RUN,
        timer_of(timer),
        [to_event(e) for e in events],
        frozen=None if frozen is None else Frozen(*frozen),
    )


def case(
    name: str, timer: str, events: list[dict[str, Any]], frozen: tuple[int, FrozenReason] | None
) -> dict[str, Any]:
    state = fold_case(timer, events, frozen)
    timing = run_fold.project_timing(state, timer_of(timer)) if state.status == "stopped" else None
    return {
        "name": name,
        "timer": timer,
        "events": events,
        "frozen": None if frozen is None else {"after": frozen[0], "reason": frozen[1]},
        "expected": {
            "state": run_fold.state_json(state),
            "timing": None if timing is None else run_fold.timing_json(timing),
        },
    }


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_run_fold_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "run_id": RUN,
            "max_run_ms": run_fold.MAX_RUN_MS,
            "semantics": [
                "docs/specs/timers.md §4 (the fold), §2.3 (timing), as changed by docs/specs/timers2.md "
                "§3 (fold v4; its §3.4 pseudocode is normative). Parse every `at` to integer epoch "
                "milliseconds, truncating sub-millisecond digits (never rounding, never through a float "
                "or a Date); all arithmetic is integer.",
                "fold(run_id, timer, events, frozen): `timer` is timer_sets[case.timer], a normalised "
                "Timer v2 (timers2.md §1); the fold reads its steps and lap types only. "
                "Events are in server arrival order. "
                "Pass 1, arrival: "
                "skip an id already seen (ids compared lowercase; the first occurrence wins); `finish` "
                "gets no effect (the server decides it); with `frozen`, every event at arrival index >= "
                "frozen.after is void with frozen.reason and not folded; a `start` is applied if its id is "
                "run_id, else void `merged`; the first `stop`/`discard` is the terminal, later ones void "
                "`already_closed`; a `stop` before the start is void `before_start`, one more than "
                "max_run_ms after it void `too_long`, whenever it arrives (checked before "
                "`already_closed`), and neither closes the run. A stop ends the open reopen transaction.",
                "Pass 1, reopen (target = a stop): `no_target` unless that stop was seen; `already_closed` "
                "when the terminal is a discard; `not_stopped` unless the target is the current terminal; "
                "`stale` if at <= the stop's at; `too_long` past max_run_ms; else applied: the terminal "
                "clears, (stop, reopen) is the open transaction and a role pair. A discard while a "
                "transaction is open reverts it: the reopen becomes void `reverted`, the stop is the "
                "terminal again (re-applied if it had been removed, that remove void `no_target`), the "
                "pair is no longer a role, and the discard is applied. remove: `no_target` unless the "
                "target was seen, isn't removed yet, at > target.at, and it is a pause, a lap, or a stop "
                "of a current role pair (that stop becomes void `deleted`; its reopen stays applied). No "
                "7-day bound on remove. Effects are recomputed from scratch on every fold.",
                "Pass 2, by (at, rank, lowercase id) ascending: each role pair's stop is a gap pause "
                "(rank 0, id = the stop's; left out when the stop is removed) and its reopen a gap resume "
                "(rank 2, id = the reopen's); user events rank 1, where a resume with the same at as the "
                "pause its pause_id names sorts right after that pause (several such resumes by "
                "lowercase id). Roles outside [start, terminal.at] are skipped; they get no effect. A gap "
                "pause opens a pause if none is open and takes it over (pause id = the stop's); a gap "
                "resume ends whatever pause is open. User events: void `before_start` if at < start; "
                "`after_stop` if at > terminal.at; `too_long` if at > start + max_run_ms; a removed event "
                "is `deleted` (a removed lap whose seg matched becomes a ghost (lap.at, remove.at)); a "
                "resume naming a removed pause is `deleted`; next/lap/skip with seg != expected: `stale`, "
                "where expected = closed segments + ghosts with ghost.at < at < ghost.removed_at. next "
                "closes the open segment and opens the next pending step (a lap "
                "when none is left); lap closes it and opens a lap (pending unchanged). skip on a step "
                "segment must name that step (else `stale`): it joins `skipped` and the open segment is "
                "relabelled to the next pending step (or a lap); skip on a lap: `no_step` if nothing is "
                "pending, `stale` unless it names the head of pending, which joins `skipped`. pause: "
                "`already_paused` if paused. resume: `not_paused` if not paused, `stale` unless pause_id "
                "is the open pause's id; else the pause [paused_since, at) closes.",
                "Terminal stop: an open pause ends at the stop, the open segment closes at it, status "
                "`stopped` (the server says `finishing` while required answers are missing). Discard: "
                "status `discarded`, no open segment or pause. Otherwise `paused` or `running`.",
                "Segments: pauses stay whole; a segment's paused_ms is its overlap with them (an open "
                "pause covers up to the segment's end: measure it to that end, not to a large sentinel), "
                "active_ms = length - paused_ms. Lap n (n counting lap segments from 1 in segment order, "
                "the open one included) has lap_type = laps[(n-1) mod |laps|].key and label "
                "'{that label} {(n-1) div |laps| + 1}', or lap_type null and 'Lap n' with no lap types; "
                "steps have lap_type null. open.index = closed segment count; next_step = head of pending "
                "while the run is open, else null. A segment's event_id/opened_by name the event that "
                "opened it (null/'start' for the first); a pause's id is its pause event's (a gap pause's "
                "is its stop's). terminal_id = the terminal stop's id (null unless stopped); lap_count = "
                "closed lap segments; next_lap_type = the type of lap number lap_count + (open is a lap ? "
                "1 : 0) + 1 while open and typed, else null.",
                "Instants out: UTC, 'Z', six fraction digits only when the millisecond part is not zero "
                "(how the API writes them). Compare by parsing to milliseconds or as strings.",
                "timing (stopped runs only): started_at, ended_at, paused_ms = sum of pauses, active_ms "
                "= ended - started - paused_ms, complete = the version has no steps, or every one of its "
                "steps has a segment and none was skipped; edited = false; and the state's segments, "
                "skipped, pauses and terminal_id.",
                "timings: stored entry timings as clients decode them; `expected` is the timing as "
                "served. A pre-v2 timing's terminal_id, lap_type, event_id, opened_by and pause ids read "
                "null.",
            ],
        },
        "timer_sets": TIMER_SETS,
        "cases": [case(name, *spec) for name, spec in CASES.items()],
        "timings": [
            {
                "name": name,
                "stored": stored,
                "expected": run_fold.timing_json(run_fold.timing_from_json(stored)),
            }
            for name, stored in TIMINGS.items()
        ],
    }


def test_run_fold_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def effects(name: str) -> dict[str, tuple[str, str | None]]:
    state = fold_case(*CASES[name])
    return {k: (v.effect, v.reason) for k, v in state.effects.items()}


def reasons(name: str) -> list[str | None]:
    return sorted((r for _, r in effects(name).values() if r is not None), key=str)


def test_vectors_cover_timers2() -> None:
    """timers2.md §12.1: every v4 case the spec names is present (the list is read from the
    spec), the generator is at version 4 and the timer sets are §3.1's."""
    built = build()
    names = {c["name"] for c in built["cases"]} | {t["name"] for t in built.get("timings", [])}
    missing = [name for name in run_fold_v4_cases() if name not in names]
    assert not missing, missing
    assert built["meta"]["generator_version"] == 4
    assert list(built["timer_sets"]) == ["none", "two", "three", "renamed", "tiktok", "three_types"]


def test_vectors_cover_the_spec() -> None:
    """timers.md §13.1: every named case is present and does what its name says."""
    built = {c["name"]: c["expected"] for c in build()["cases"]}
    trunc = built["sub-millisecond-instants-truncated"]["timing"]
    assert trunc["started_at"] == "2026-10-23T08:00:00Z"
    assert trunc["ended_at"] == "2026-10-23T08:00:02.002000Z"
    assert trunc["active_ms"] + trunc["paused_ms"] == 2002
    assert sum(s["active_ms"] for s in trunc["segments"]) == trunc["active_ms"]
    assert built["no-steps-start-stop"]["timing"]["active_ms"] == 442_000
    assert [s["label"] for s in built["laps"]["timing"]["segments"]] == ["Lap 1", "Lap 2", "Lap 3"]
    assert [s["step"] for s in built["three-steps-all-done"]["timing"]["segments"]] == [
        "shower",
        "breakfast",
        "dress",
    ]
    assert [s["kind"] for s in built["next-after-last-step"]["timing"]["segments"]] == [
        "step",
        "step",
        "lap",
        "lap",
    ]
    assert built["skip-on-a-step"]["timing"]["skipped"] == ["shower"]
    assert built["skip-from-a-lap"]["timing"]["skipped"] == ["breakfast"]
    assert reasons("double-tapped-skip") == ["stale"]
    assert effects("skip-stale-seg")[eid(3)] == ("void", "stale")
    assert effects("client-stop-before-start")[eid(3)] == ("void", "before_start")
    assert effects("resume-at-the-pause-instant")[eid(3)] == ("applied", None)
    assert built["resume-at-the-pause-instant"]["timing"]["paused_ms"] == 0
    assert built["stopped-before-the-last-step"]["timing"]["complete"] is False
    assert effects("resume-at-the-pause-instant-mixed-case")[LOWER_RESUME.lower()] == ("applied", None)
    assert built["resume-at-the-pause-instant-mixed-case"]["timing"]["paused_ms"] == 0
    assert [s["active_ms"] for s in built["next-at-the-start-instant"]["timing"]["segments"]] == [0, 50_000]
    open_pause = built["next-while-paused-pause-open"]["state"]
    assert (open_pause["status"], open_pause["paused_since"]) == ("paused", at(60))
    assert [(s["active_ms"], s["paused_ms"]) for s in open_pause["segments"]] == [(60_000, 30_000)]
    assert effects("uppercase-run-id")[RUN] == ("applied", None)
    assert built["uppercase-run-id"]["timing"]["active_ms"] == 60_000
    assert built["three-steps-all-done"]["timing"]["complete"] is True
    assert built["pause-resume"]["timing"]["paused_ms"] == 30_000
    assert reasons("resume-naming-an-older-pause") == ["stale"]
    assert built["next-while-paused"]["timing"]["segments"][1]["paused_ms"] == 60_000
    assert built["stop-while-paused"]["timing"]["pauses"][-1]["end"] == at(100)
    assert reasons("double-next-two-devices") == ["stale"]
    assert effects("double-next-two-devices")[eid(1)] == ("applied", None)
    assert reasons("offline-taps-after-stop") == ["after_stop"]
    assert effects("offline-taps-after-stop")[eid(2)] == ("applied", None)
    assert effects("late-merge-turns-next-stale")[eid(1)] == ("void", "stale")
    assert effects("edited-run-late-taps")[eid(3)] == ("void", "run_edited")
    assert effects("edited-run-late-taps")[eid(1)] == ("applied", None)
    assert reasons("two-stops") == ["already_closed"]
    assert built["discard-then-stop"]["state"]["status"] == "discarded"
    assert reasons("discard-then-stop") == ["already_closed"]
    assert effects("equal-at-tie-break-by-id")[LOWER_A.lower()] == ("applied", None)
    assert effects("equal-at-tie-break-by-id")[UPPER_B.lower()] == ("void", "stale")
    assert reasons("events-before-start") == ["before_start", "before_start"]
    assert reasons("too-long") == ["too_long", "too_long"]
    assert reasons("merged-start") == ["merged"]
    assert reasons("skip-from-a-lap-no-step") == ["no_step"]
    assert reasons("double-pause-and-stray-resume") == ["already_paused", "not_paused"]
    assert effects("after-stop-beyond-the-limit")[eid(2)] == ("void", "after_stop")
    paused_open = built["next-twice-while-paused-open"]["state"]
    segments = [(s["active_ms"], s["paused_ms"]) for s in paused_open["segments"]]
    assert segments == [(30_000, 30_000), (0, 40_000)]
    discarded = built["pause-then-discard"]["state"]
    assert (discarded["status"], discarded["paused_since"]) == ("discarded", None)
    assert [s["paused_ms"] for s in discarded["segments"]] == [0]
    assert effects("resume-uppercase-pause-id")[eid(2)] == ("applied", None)
    assert built["resume-uppercase-pause-id"]["timing"]["paused_ms"] == 30_000
    assert effects("replayed-event-id-case") == dict.fromkeys((RUN, eid(1), eid(2)), ("applied", None))
    assert len(built["replayed-event-id-case"]["timing"]["segments"]) == 2


def eff(name: str, n: int) -> tuple[str, str | None]:
    return effects(name)[eid(n)]


def labels(name: str) -> list[str]:
    return [s.label for s in fold_case(*CASES[name]).segments]


def spans(name: str) -> list[tuple[float, float, int, int]]:
    """(start s, end s, active s, paused s) per closed segment."""
    return [
        ((s.started_at - T0) / 1000, (s.ended_at - T0) / 1000, s.active_ms // 1000, s.paused_ms // 1000)
        for s in fold_case(*CASES[name]).segments
    ]


def gaps(name: str) -> list[tuple[float, float, str | None]]:
    return [((p.start - T0) / 1000, (p.end - T0) / 1000, p.id) for p in fold_case(*CASES[name]).pauses]


def test_v4_vectors_do_what_their_names_say() -> None:
    """timers2.md §3 and the worked examples of §6, one assert group per §12.1 case."""
    assert labels("renamed-laps") == ["Cig 1", "Cig 2", "Cig 3"]
    assert labels("tiktok-cycle") == ["Run 1", "Rest 1", "Run 2", "Rest 2", "Run 3"]
    assert labels("three-types-with-step") == ["Warmup", "Run 1", "Rest 1", "Walk 1", "Run 2", "Rest 2"]
    assert [s.lap_type for s in fold_case(*CASES["three-types-with-step"]).segments] == [
        None, "run", "rest", "walk", "run", "rest"
    ]  # fmt: skip
    # §6.1
    accidental = fold_case(*CASES["reopen-accidental-stop"])
    assert spans("reopen-accidental-stop") == [(0, 60, 60, 0), (60, 150, 70, 20), (150, 180, 30, 0)]
    assert gaps("reopen-accidental-stop") == [(90, 110, eid(2))]
    assert (accidental.terminal_id, accidental.lap_count) == (eid(5), 3)
    assert labels("reopen-then-restop-labels") == ["Cig 1", "Cig 2", "Cig 3"]
    assert eff("reopen-not-terminal", 3) == ("void", "not_stopped")
    assert eff("reopen-unknown-target", 2) == ("void", "no_target")
    assert eff("reopen-after-discard", 3) == ("void", "already_closed")
    assert eff("reopen-stale-at", 2) == ("void", "stale")
    assert eff("reopen-too-long", 2) == ("void", "too_long")
    assert (eff("reopen-double-tap", 2), eff("reopen-double-tap", 3)) == (
        ("applied", None),
        ("void", "not_stopped"),
    )
    # §6.2
    reverted = fold_case(*CASES["reopen-revert-by-discard"])
    assert (reverted.status, reverted.terminal_id, spans("reopen-revert-by-discard")) == (
        "stopped", eid(1), [(0, 90, 90, 0)]
    )  # fmt: skip
    assert [eff("reopen-revert-by-discard", n) for n in (2, 3, 4)] == [
        ("void", "reverted"), ("void", "after_stop"), ("applied", None)
    ]  # fmt: skip
    again = fold_case(*CASES["reopen-revert-then-reopen-again"])
    assert (again.status, eff("reopen-revert-then-reopen-again", 4)) == ("running", ("applied", None))
    assert gaps("reopen-revert-then-reopen-again") == [(90, 160, eid(1))]
    second = fold_case(*CASES["reopen-second-stop-new-terminal"])
    assert (second.terminal_id, second.ended_at) == (eid(4), T0 + 120_000)
    nested = "stop-reopen-stop-reopen-discard-discard"
    assert [eff(nested, n) for n in (2, 4, 5, 6)] == [
        ("applied", None), ("void", "reverted"), ("applied", None), ("void", "already_closed")
    ]  # fmt: skip
    assert fold_case(*CASES[nested]).terminal_id == eid(3)
    twice = "stop-reopen-remove-gap-revert-reopen-remove-gap-revert"
    assert [eff(twice, n) for n in range(1, 8)] == [
        ("applied", None),
        ("void", "reverted"),
        ("void", "no_target"),
        ("applied", None),
        ("void", "reverted"),
        ("void", "no_target"),
        ("applied", None),
    ]
    offline = fold_case(*CASES["reopen-offline-stop-earlier-than-reopen"])
    assert (offline.terminal_id, eff("reopen-offline-stop-earlier-than-reopen", 3)) == (
        eid(4),
        ("void", "after_stop"),
    )
    assert gaps("reopen-offline-stop-earlier-than-reopen") == [(10, 20, eid(1))]
    assert gaps("reopen-while-paused-ends-pause") == [(30, 90, eid(2))]
    assert eff("reopen-while-paused-ends-pause", 4) == ("void", "not_paused")
    inside = "reopen-gap-removed-user-pause-inside-gap"
    assert (gaps(inside), eff(inside, 5)) == ([(70, 90, eid(4))], ("void", "not_paused"))
    assert eff("resume-inside-gap-stale", 4) == ("void", "stale")
    assert gaps("resume-inside-gap-stale") == [(30, 90, eid(2))]
    assert eff("gap-pause-equal-time-user-resume", 4) == ("void", "stale")
    assert eff("gap-resume-equal-time-user-pause", 3) == ("void", "already_paused")
    assert gaps("two-gap-pauses-equal-time") == [(60, 80, eid(3))]  # the later stop id takes over
    # §6.6
    assert eff("reopen-lap-inside-gap", 3) == ("applied", None)
    assert spans("reopen-lap-inside-gap") == [(0, 60, 60, 0), (60, 130, 60, 10), (130, 180, 30, 20)]
    assert gaps("reopen-lap-inside-gap") == [(120, 150, eid(2))]
    # §6.3 (a)
    assert [eff("remove-pause", n) for n in (1, 2)] == [("void", "deleted")] * 2
    assert (spans("remove-pause"), gaps("remove-pause")) == ([(0, 120, 120, 0)], [])
    assert eff("remove-pause-resume-deleted", 3) == ("void", "deleted")
    noop = "remove-void-pause-noop"
    assert (eff(noop, 3), gaps(noop)) == (("void", "deleted"), [(30, 60, eid(1))])
    which = "remove-pause-changes-which-pause-applies"
    assert ([eff(which, n) for n in (2, 3)], gaps(which)) == ([("applied", None)] * 2, [(40, 60, eid(2))])
    # §6.3 (b)
    assert (eff("remove-gap-pause", 1), eff("remove-gap-pause", 2)) == (
        ("void", "deleted"),
        ("applied", None),
    )
    assert (spans("remove-gap-pause"), gaps("remove-gap-pause")) == ([(0, 120, 120, 0)], [])
    assert spans("remove-lap-merges-previous") == [(0, 120, 120, 0)]
    # §6.4
    renumbered = fold_case(*CASES["remove-lap-renumbers-types"])
    assert labels("remove-lap-renumbers-types") == ["Run 1", "Rest 1", "Run 2"]
    assert renumbered.open is not None
    assert (renumbered.open.label, renumbered.open.lap_type) == ("Rest 2", "rest")
    assert (renumbered.next_lap_type, renumbered.lap_count) == ("run", 3)
    ghost = "remove-lap-ghost-keeps-later-lap-applied"
    assert [eff(ghost, n) for n in (2, 4)] == [("applied", None)] * 2
    assert spans("remove-two-laps-ghosts-stack") == [(0, 90, 90, 0), (90, 120, 30, 0)]
    assert eff("remove-two-laps-ghosts-stack", 3) == ("applied", None)
    assert eff("remove-stale-lap-no-ghost", 4) == ("applied", None)
    assert spans("remove-stale-lap-no-ghost") == [(0, 60, 60, 0), (60, 90, 30, 0), (90, 120, 30, 0)]
    # §6.5
    assert labels("remove-lap-after-stop-late-merge") == ["Cig 1", "Cig 2"]
    assert spans("remove-lap-after-stop-late-merge") == [(0, 65, 65, 0), (65, 180, 115, 0)]
    assert spans("remove-lap-after-stop-then-late-lap") == [
        (0, 65, 65, 0),
        (65, 120, 55, 0),
        (120, 180, 60, 0),
    ]
    assert eff("remove-years-later-applies", 4) == ("applied", None)
    assert eff("remove-next-is-no-target", 2) == ("void", "no_target")
    assert eff("remove-terminal-stop-no-target", 2) == ("void", "no_target")
    assert eff("remove-twice-no-target", 3) == ("void", "no_target")
    assert [eff("remove-at-before-target-no-target", n) for n in (2, 3)] == [("void", "no_target")] * 2
    restored = fold_case(*CASES["remove-then-revert-restores-stop"])
    assert (restored.terminal_id, eff("remove-then-revert-restores-stop", 1)) == (eid(1), ("applied", None))
    assert eff("remove-then-revert-restores-stop", 3) == ("void", "no_target")
    # §3.3 event ids
    ids = run_fold.project_timing(fold_case(*CASES["timing-carries-event-ids"]), timer_of("three_types"))
    assert ids.terminal_id == eid(7)
    assert [(s.event_id, s.opened_by) for s in ids.segments] == [
        (None, "start"),
        (eid(1), "next"),
        (eid(4), "lap"),
    ]
    assert [p.id for p in ids.pauses] == [eid(2), eid(5)]  # a gap pause carries its stop's id
    pre_v2 = next(t for t in build()["timings"] if t["name"] == "timing-pre-v2-null-ids")["expected"]
    assert pre_v2["terminal_id"] is None
    assert {(s["lap_type"], s["event_id"], s["opened_by"]) for s in pre_v2["segments"]} == {
        (None, None, None)
    }
    assert [p["id"] for p in pre_v2["pauses"]] == [None]
    assert eff("frozen-reopen-run-edited", 2) == ("void", "run_edited")
    assert eff("frozen-remove-entry-deleted", 4) == ("void", "entry_deleted")
