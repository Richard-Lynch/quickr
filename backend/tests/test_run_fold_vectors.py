"""Run fold vectors: ``shared/fixtures/run-fold-vectors.json``.

Generated from ``app/services/run_fold.py``: a run's events in arrival order, folded into
its state and (when stopped) its timing (docs/specs/timers.md §4, §2.3). The PWA
(``runFold.vectors.test.ts``) and the iOS app (QuickrCore ``RunFoldVectorTests``) fold the
same events with their ports and must reach the same state, effects and timing (spec test
R1); the backend runs them through the real endpoint (T1). ``QUICKR_UPDATE_VECTORS=1``
(``make vectors``) rewrites the file; otherwise the committed file must match.
"""

from __future__ import annotations

from typing import Any

from app.services import run_fold
from app.services.run_fold import Event, Frozen, FrozenReason, Step
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "run-fold-vectors.json"
GENERATOR_VERSION = 3

RUN = "0a000000-0000-4000-8000-000000000000"
T0 = run_fold.parse_instant("2026-10-23T08:00:00Z")

STEP_SETS: dict[str, list[dict[str, str]]] = {
    "none": [],
    "two": [{"key": "shower", "label": "Shower"}, {"key": "breakfast", "label": "Breakfast"}],
    "three": [
        {"key": "shower", "label": "Shower"},
        {"key": "breakfast", "label": "Breakfast"},
        {"key": "dress", "label": "Get dressed"},
    ],
}


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
) -> dict[str, Any]:
    """An event as the vectors carry it. ``n`` 0 is the run's start; a string is the id."""
    pause_id = eid(pause) if isinstance(pause, int) else pause
    return {
        "id": n if isinstance(n, str) else RUN if n == 0 else eid(n),
        "type": type_,
        "at": at(seconds),
        "seg": seg,
        "step": step,
        "pause_id": pause_id,
    }


START = ev(0, "start", 0)
DAY = 24 * 60 * 60
# Two ids whose order differs between raw and lowercase comparison ("B" < "a" < "b").
UPPER_B = "0e000000-0000-4000-8000-00000000000B"
LOWER_A = "0e000000-0000-4000-8000-00000000000a"
# A pause whose id is uppercase, named in lowercase by a resume whose id sorts before it.
UPPER_PAUSE = "0e000000-0000-4000-8000-00000000000D"
LOWER_RESUME = "0e000000-0000-4000-8000-00000000000c"

# name -> (step set, events in arrival order, frozen as (after, reason) or None)
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


def to_event(d: dict[str, Any]) -> Event:
    return Event(
        id=d["id"],
        type=d["type"],
        at=run_fold.parse_instant(d["at"]),
        seg=d["seg"],
        step=d["step"],
        pause_id=d["pause_id"],
    )


def steps_of(name: str) -> list[Step]:
    return [Step(**s) for s in STEP_SETS[name]]


def fold_case(
    steps: str, events: list[dict[str, Any]], frozen: tuple[int, FrozenReason] | None
) -> run_fold.RunState:
    return run_fold.fold(
        RUN,
        steps_of(steps),
        [to_event(e) for e in events],
        frozen=None if frozen is None else Frozen(*frozen),
    )


def case(
    name: str, steps: str, events: list[dict[str, Any]], frozen: tuple[int, FrozenReason] | None
) -> dict[str, Any]:
    state = fold_case(steps, events, frozen)
    timing = run_fold.project_timing(state, steps_of(steps)) if state.status == "stopped" else None
    return {
        "name": name,
        "steps": steps,
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
                "docs/specs/timers.md §4 (the fold), §2.3 (timing). Parse every `at` to integer epoch "
                "milliseconds, truncating sub-millisecond digits (never rounding, never through a float "
                "or a Date); all arithmetic is integer.",
                "fold(run_id, steps, events, frozen): events are in server arrival order. Pass 1, arrival: "
                "skip an id already seen (ids compared lowercase; the first occurrence wins); `finish` "
                "gets no effect (the server decides it); with `frozen`, every event at arrival index >= "
                "frozen.after is void with frozen.reason and not folded; a `start` is applied if its id is "
                "run_id, else void `merged`; the first `stop`/`discard` is the terminal, later ones void "
                "`already_closed`; a `stop` before the start is void `before_start`, one more than "
                "max_run_ms after it void `too_long`, whenever it arrives (checked before "
                "`already_closed`), and neither closes the run.",
                "Pass 2, by (at, lowercase id) ascending, except that a resume with the same at as the "
                "pause its pause_id names sorts right after that pause (several such resumes by "
                "lowercase id): void `before_start` if at < start; `after_stop` if at > terminal.at; "
                "`too_long` if at > start + max_run_ms; next/lap/skip with seg != the open segment's "
                "index: `stale`. next closes the open segment and opens the next pending step (a lap "
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
                "active_ms = length - paused_ms. Lap labels are 'Lap n', n counting lap segments from 1 "
                "in segment order (the open one included). open.index = closed segment count; "
                "next_step = head of pending while the run is open, else null.",
                "Instants out: UTC, 'Z', six fraction digits only when the millisecond part is not zero "
                "(how the API writes them). Compare by parsing to milliseconds or as strings.",
                "timing (stopped runs only): started_at, ended_at, paused_ms = sum of pauses, active_ms "
                "= ended - started - paused_ms, complete = the version has no steps, or every one of its "
                "steps has a segment and none was skipped; edited = false; and the state's segments, "
                "skipped and pauses.",
            ],
        },
        "step_sets": STEP_SETS,
        "cases": [case(name, *spec) for name, spec in CASES.items()],
    }


def test_run_fold_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def effects(name: str) -> dict[str, tuple[str, str | None]]:
    state = fold_case(*CASES[name])
    return {k: (v.effect, v.reason) for k, v in state.effects.items()}


def reasons(name: str) -> list[str | None]:
    return sorted((r for _, r in effects(name).values() if r is not None), key=str)


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
