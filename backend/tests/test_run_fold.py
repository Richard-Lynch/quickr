"""The run fold (docs/specs/timers.md §4) and the timing projection (§2.3): one test per
rule of §4.2 and §4.4, the T1 to T5 checks, and a seeded property test over random runs."""

from __future__ import annotations

import dataclasses
import random
from collections.abc import Sequence

import pytest

from app.services import run_fold
from app.services.run_fold import Event, EventType, Frozen, Pause, RunState, Step, Timing, TimingError

RUN = "0a000000-0000-4000-8000-000000000000"
STEPS = [Step("a", "Alpha"), Step("b", "Beta"), Step("c", "Gamma")]
S = 1000  # one second in ms


def eid(n: int) -> str:
    return f"0e000000-0000-4000-8000-{n:012d}"


def e(
    n: int,
    type_: EventType,
    sec: float,
    seg: int | None = None,
    step: str | None = None,
    pause: int | None = None,
) -> Event:
    return Event(
        id=RUN if n == 0 else eid(n),
        type=type_,
        at=round(sec * S),
        seg=seg,
        step=step,
        pause_id=None if pause is None else eid(pause),
    )


START = e(0, "start", 0)


def fold(events: Sequence[Event], steps: Sequence[Step] = STEPS, frozen: Frozen | None = None) -> RunState:
    return run_fold.fold(RUN, steps, [START, *events], frozen=frozen)


def effect(state: RunState, n: int) -> tuple[str, str | None]:
    eff = state.effects[RUN if n == 0 else eid(n)]
    return eff.effect, eff.reason


def spans(state: RunState) -> list[tuple[str | None, int, int]]:
    """(step or None for a lap, start s, end s) per closed segment."""
    return [(s.step, s.started_at // S, s.ended_at // S) for s in state.segments]


# --- instants ---------------------------------------------------------------------------


def test_instants_truncate_to_milliseconds() -> None:
    assert run_fold.parse_instant("2026-10-23T08:00:00.123999Z") % 1000 == 123
    assert run_fold.parse_instant("2026-10-23T09:00:00.5+01:00") == run_fold.parse_instant(
        "2026-10-23T08:00:00.500Z"
    )
    assert run_fold.parse_instant("1999-12-31T23:59:59.9999Z") % 1000 == 999
    with pytest.raises(ValueError, match="naive"):
        run_fold.parse_instant("2026-10-23T08:00:00")


def test_instants_format_like_the_api() -> None:
    ms = run_fold.parse_instant("2026-10-23T08:00:00Z")
    assert run_fold.format_instant(ms) == "2026-10-23T08:00:00Z"
    assert run_fold.format_instant(ms + 7) == "2026-10-23T08:00:00.007000Z"


# --- §4.1 and §4.2 ----------------------------------------------------------------------


def test_the_start_is_required() -> None:
    with pytest.raises(ValueError, match="start"):
        run_fold.fold(RUN, STEPS, [e(1, "next", 1, seg=0)])


def test_unknown_event_types_are_refused() -> None:
    with pytest.raises(ValueError, match="unknown"):
        fold([Event(eid(1), "jump", 1)])  # type: ignore[arg-type]


def test_a_replayed_id_is_ignored() -> None:
    state = fold([e(1, "next", 10, seg=0), e(1, "next", 10, seg=0), START])
    assert spans(state) == [("a", 0, 10)]
    assert effect(state, 1) == ("applied", None)


def test_ids_compare_lowercase() -> None:
    lower = "0e000000-0000-4000-8000-00000000abcd"
    upper = Event(lower.upper(), "next", 10 * S, seg=0)
    again = Event(lower, "next", 11 * S, seg=1)
    state = run_fold.fold(RUN.upper(), STEPS, [START, upper, again])
    assert len(state.segments) == 1  # the second Next is a replay of the first
    assert list(state.effects) == [RUN, lower]


def test_another_start_is_merged() -> None:
    state = fold([e(1, "start", -60), e(2, "next", 10, seg=0)])
    assert effect(state, 1) == ("void", "merged")
    assert state.started_at == 0  # the run keeps its own start, even when the merged one is earlier
    assert spans(state) == [("a", 0, 10)]


def test_the_first_terminal_to_arrive_closes_the_run() -> None:
    state = fold([e(1, "stop", 100), e(2, "stop", 50), e(3, "discard", 20)])
    assert state.status == "stopped"
    assert state.ended_at == 100 * S
    assert effect(state, 2) == ("void", "already_closed")
    assert effect(state, 3) == ("void", "already_closed")


def test_discard_then_stop_stays_discarded() -> None:
    state = fold([e(1, "next", 10, seg=0), e(2, "pause", 20), e(3, "discard", 30), e(4, "stop", 40)])
    assert (state.status, state.open, state.paused_since, state.ended_at) == ("discarded", None, None, None)
    assert effect(state, 4) == ("void", "already_closed")


def test_finish_gets_no_effect() -> None:
    state = fold([e(1, "stop", 10), e(2, "finish", 11)])
    assert eid(2) not in state.effects


def test_a_stop_before_the_start_or_too_late_does_not_close() -> None:
    state = fold([e(1, "stop", -1), e(2, "stop", 7 * 86400 + 1)])
    assert state.status == "running"
    assert effect(state, 1) == ("void", "before_start")
    assert effect(state, 2) == ("void", "too_long")


def test_non_terminal_events_replay_in_time_order() -> None:
    # An offline Next tapped at 10 s that arrives after a Next at 20 s lands first.
    state = fold([e(2, "next", 20, seg=1), e(1, "next", 10, seg=0)])
    assert spans(state) == [("a", 0, 10), ("b", 10, 20)]


def test_equal_instants_order_by_lowercase_id() -> None:
    b = Event("0e000000-0000-4000-8000-00000000000B", "next", 10 * S, seg=0)
    a = Event("0e000000-0000-4000-8000-00000000000a", "next", 10 * S, seg=0)
    state = fold([b, a])
    assert state.effects[a.id.lower()].effect == "applied"
    assert state.effects[b.id.lower()].reason == "stale"


def test_a_resume_at_its_pause_instant_applies_after_it() -> None:
    pause = Event("0e000000-0000-4000-8000-00000000ffff", "pause", 10 * S)
    resume = Event("0e000000-0000-4000-8000-000000000001", "resume", 10 * S, pause_id=pause.id)
    state = fold([pause, resume])
    assert state.effects[resume.id].effect == "applied"
    assert (state.status, state.pauses) == ("running", (Pause(10 * S, 10 * S),))


def test_events_before_the_start_are_void() -> None:
    state = fold([e(1, "next", -1, seg=0)])
    assert effect(state, 1) == ("void", "before_start")


def test_events_after_the_stop_are_void() -> None:
    state = fold([e(1, "stop", 10), e(2, "lap", 10.001, seg=0)])
    assert effect(state, 2) == ("void", "after_stop")


def test_an_event_at_the_stop_instant_applies() -> None:
    state = fold([e(1, "stop", 10), e(2, "next", 10, seg=0)])
    assert spans(state) == [("a", 0, 10), ("b", 10, 10)]


def test_events_after_the_discard_instant_are_void() -> None:
    state = fold([e(1, "discard", 10), e(2, "lap", 11, seg=0)])
    assert effect(state, 2) == ("void", "after_stop")


def test_events_more_than_seven_days_in_are_void() -> None:
    week = 7 * 86400
    state = fold([e(1, "lap", week, seg=0), e(2, "lap", week + 0.001, seg=1)], steps=[])
    assert effect(state, 1) == ("applied", None)
    assert effect(state, 2) == ("void", "too_long")


def test_next_and_lap_must_name_the_open_segment() -> None:
    state = fold([e(1, "next", 10, seg=1), e(2, "lap", 11, seg=0), e(3, "next", 12, seg=0)])
    assert effect(state, 1) == ("void", "stale")
    assert effect(state, 3) == ("void", "stale")
    assert spans(state) == [("a", 0, 11)]


def test_next_opens_the_next_step_then_laps() -> None:
    state = fold(
        [e(1, "next", 1, seg=0), e(2, "next", 2, seg=1), e(3, "next", 3, seg=2), e(4, "next", 4, seg=3)]
    )
    assert [s.step for s in state.segments] == ["a", "b", "c", None]
    assert state.open is not None
    assert (state.open.kind, state.open.label, state.next_step) == ("lap", "Lap 2", None)


def test_a_lap_opens_an_unnamed_segment_and_next_resumes_the_steps() -> None:
    state = fold([e(1, "lap", 5, seg=0), e(2, "next", 8, seg=1)])
    assert spans(state) == [("a", 0, 5), (None, 5, 8)]
    assert state.open is not None
    assert (state.open.step, state.open.index, state.next_step) == ("b", 2, "c")
    assert state.segments[1].label == "Lap 1"


def test_no_steps_is_a_stopwatch_of_laps() -> None:
    state = fold([e(1, "next", 5, seg=0), e(2, "lap", 7, seg=1), e(3, "stop", 9)], steps=[])
    assert [(s.kind, s.label) for s in state.segments] == [
        ("lap", "Lap 1"),
        ("lap", "Lap 2"),
        ("lap", "Lap 3"),
    ]


def test_skip_on_a_step_relabels_the_open_segment() -> None:
    state = fold([e(1, "skip", 5, seg=0, step="a"), e(2, "next", 9, seg=0)])
    assert state.skipped == ("a",)
    assert spans(state) == [("b", 0, 9)]  # no time is lost or created
    assert state.open is not None
    assert state.open.step == "c"


def test_skip_on_a_step_must_name_it() -> None:
    state = fold([e(1, "skip", 5, seg=0, step="b"), e(2, "skip", 6, seg=0)])
    assert effect(state, 1) == ("void", "stale")
    assert effect(state, 2) == ("void", "stale")
    assert state.skipped == ()


def test_skip_must_name_the_open_segment() -> None:
    state = fold([e(1, "lap", 5, seg=0), e(2, "lap", 6, seg=1), e(3, "skip", 6.5, seg=1, step="b")])
    assert effect(state, 3) == ("void", "stale")
    assert state.skipped == ()


def test_a_double_tapped_skip_skips_once() -> None:
    state = fold([e(1, "skip", 5, seg=0, step="a"), e(2, "skip", 5.5, seg=0, step="a")])
    assert state.skipped == ("a",)
    assert effect(state, 2) == ("void", "stale")


def test_skipping_the_last_step_turns_the_segment_into_a_lap() -> None:
    state = fold([e(1, "next", 1, seg=0), e(2, "next", 2, seg=1), e(3, "skip", 3, seg=2, step="c")])
    assert state.open is not None
    assert (state.open.kind, state.open.label) == ("lap", "Lap 1")


def test_skip_on_a_lap_skips_the_head_of_pending() -> None:
    state = fold([e(1, "lap", 1, seg=0), e(2, "skip", 2, seg=1, step="c"), e(3, "skip", 3, seg=1, step="b")])
    assert effect(state, 2) == ("void", "stale")
    assert state.skipped == ("b",)
    assert state.open is not None
    assert (state.open.kind, state.next_step) == ("lap", "c")


def test_skip_on_a_lap_with_no_step_left_is_void() -> None:
    state = fold([e(1, "skip", 2, seg=0, step="a")], steps=[])
    assert effect(state, 1) == ("void", "no_step")


def test_pause_twice_is_void() -> None:
    state = fold([e(1, "pause", 1), e(2, "pause", 2)])
    assert effect(state, 2) == ("void", "already_paused")
    assert state.status == "paused"
    assert state.paused_since == 1 * S


def test_resume_when_not_paused_is_void() -> None:
    state = fold([e(1, "resume", 1, pause=9)])
    assert effect(state, 1) == ("void", "not_paused")


def test_resume_must_name_the_open_pause() -> None:
    state = fold([e(1, "pause", 1), e(2, "resume", 2, pause=1), e(3, "pause", 3), e(4, "resume", 4, pause=1)])
    assert effect(state, 4) == ("void", "stale")
    assert state.pauses == (Pause(1 * S, 2 * S),)
    assert state.status == "paused"


def test_next_while_paused_starts_the_new_segment_paused() -> None:
    state = fold([e(1, "pause", 10), e(2, "next", 20, seg=0), e(3, "resume", 50, pause=1), e(4, "stop", 60)])
    first, second = state.segments
    assert (first.active_ms, first.paused_ms) == (10 * S, 10 * S)
    assert (second.active_ms, second.paused_ms) == (10 * S, 30 * S)


def test_an_open_pause_counts_in_closed_segments() -> None:
    state = fold([e(1, "pause", 10), e(2, "next", 20, seg=0)])
    assert state.segments[0].paused_ms == 10 * S
    assert state.pauses == ()
    assert state.paused_since == 10 * S


def test_stop_while_paused_ends_the_pause() -> None:
    state = fold([e(1, "pause", 10), e(2, "stop", 25)])
    assert state.pauses == (Pause(10 * S, 25 * S),)
    assert state.paused_since is None
    assert run_fold.project_timing(state, STEPS).active_ms == 10 * S


def test_open_run_state() -> None:
    state = fold([e(1, "next", 10, seg=0)])
    assert state.status == "running"
    assert state.ended_at is None
    assert state.open == run_fold.OpenSegment(index=1, kind="step", step="b", label="Beta", started_at=10 * S)
    assert state.next_step == "c"


# --- §4.4: events after the close -------------------------------------------------------


def test_a_late_tap_before_the_stop_merges() -> None:
    state = fold([e(1, "stop", 100), e(2, "next", 40, seg=0)])
    assert effect(state, 2) == ("applied", None)
    assert spans(state) == [("a", 0, 40), ("b", 40, 100)]


def test_a_late_tap_after_the_stop_is_void() -> None:
    state = fold([e(1, "stop", 100), e(2, "next", 140, seg=0)])
    assert effect(state, 2) == ("void", "after_stop")
    assert spans(state) == [("a", 0, 100)]


def test_a_late_merge_can_turn_an_earlier_next_stale() -> None:
    state = fold([e(1, "next", 50, seg=0), e(2, "stop", 100), e(3, "next", 40, seg=0)])
    assert effect(state, 1) == ("void", "stale")
    assert effect(state, 3) == ("applied", None)


def test_a_late_stop_is_already_closed() -> None:
    state = fold([e(1, "stop", 100), e(2, "stop", 50)])
    assert effect(state, 2) == ("void", "already_closed")


@pytest.mark.parametrize("reason", ["run_edited", "entry_deleted", "already_closed"])
def test_frozen_runs_void_later_arrivals_without_refolding(reason: run_fold.FrozenReason) -> None:
    events = [e(1, "next", 50, seg=0), e(2, "stop", 100), e(3, "next", 40, seg=0), e(4, "discard", 101)]
    state = fold(events, frozen=Frozen(after=3, reason=reason))  # index 3 is event 3 (START is 0)
    assert effect(state, 1) == ("applied", None)  # kept: the late Next didn't refold
    assert effect(state, 3) == ("void", reason)
    assert effect(state, 4) == ("void", reason)
    assert spans(state) == [("a", 0, 50), ("b", 50, 100)]


def test_a_replay_after_the_freeze_keeps_its_effect() -> None:
    state = fold(
        [e(1, "next", 50, seg=0), e(2, "stop", 100), e(1, "next", 50, seg=0)], frozen=Frozen(3, "run_edited")
    )
    assert effect(state, 1) == ("applied", None)


# --- timing -----------------------------------------------------------------------------


def test_project_timing_needs_a_stopped_run() -> None:
    with pytest.raises(ValueError, match="stopped"):
        run_fold.project_timing(fold([]), STEPS)


def complete(events: list[Event], steps: Sequence[Step] = STEPS) -> bool:
    return run_fold.project_timing(fold(events, steps=steps), steps).complete


def test_complete_means_every_step_timed_and_none_skipped() -> None:
    assert complete([e(1, "stop", 1)], steps=[])  # no steps: always complete
    assert complete([e(1, "next", 1, seg=0), e(2, "next", 2, seg=1), e(3, "stop", 3)])
    assert complete([e(1, "next", 1, seg=0), e(2, "lap", 2, seg=1), e(3, "next", 3, seg=2), e(4, "stop", 4)])
    assert not complete([e(1, "stop", 1)])  # stopped on the first step
    assert not complete([e(1, "next", 1, seg=0), e(2, "stop", 2)])  # stopped before the last step
    assert not complete(
        [e(1, "skip", 0, seg=0, step="a"), e(2, "next", 1, seg=0), e(3, "next", 2, seg=1), e(4, "stop", 3)]
    )


def test_an_edited_timing_is_complete_against_the_version_steps() -> None:
    parts = [(STEPS[0], S), (STEPS[1], 2 * S)]
    assert not run_fold.make_timing(0, parts, (), [], steps=STEPS, edited=True).complete
    assert run_fold.make_timing(0, parts, (), [], steps=STEPS[:2], edited=True).complete


def test_make_timing_matches_the_projection() -> None:
    state = fold(
        [
            e(1, "pause", 5),
            e(2, "next", 10, seg=0),
            e(3, "resume", 12, pause=1),
            e(4, "lap", 20, seg=1),
            e(5, "stop", 30),
        ]
    )
    made = run_fold.make_timing(
        0, [(STEPS[0], 10 * S), (STEPS[1], 20 * S), (None, 30 * S)], (), [Pause(5 * S, 12 * S)], steps=STEPS
    )
    assert made == run_fold.project_timing(state, STEPS)
    assert run_fold.make_timing(0, [(None, S)], (), [], steps=[], edited=True).edited


def good_timing() -> Timing:
    return run_fold.project_timing(
        fold([e(1, "pause", 5), e(2, "next", 10, seg=0), e(3, "resume", 12, pause=1), e(4, "stop", 30)]),
        STEPS,
    )


def test_check_timing_accepts_a_fold() -> None:
    t = good_timing()
    run_fold.check_timing(t, captured_at=t.ended_at)


def broken(t: Timing, invariant: str) -> Timing:
    first, second = t.segments
    match invariant:
        case "T1":
            return t
        case "T2":
            return dataclasses.replace(
                t, segments=(first, dataclasses.replace(second, started_at=second.started_at + 1))
            )
        case "T3":
            return dataclasses.replace(t, pauses=(Pause(t.ended_at, t.ended_at + 1),))
        case "T4":
            return dataclasses.replace(t, skipped=("a",))
        case _:
            return dataclasses.replace(t, active_ms=t.active_ms + 1)


@pytest.mark.parametrize("invariant", ["T1", "T2", "T3", "T4", "T5"])
def test_check_timing_names_the_broken_invariant(invariant: str) -> None:
    t = good_timing()
    with pytest.raises(TimingError) as caught:
        run_fold.check_timing(broken(t, invariant), captured_at=t.ended_at - 1 if invariant == "T1" else None)
    assert caught.value.invariant == invariant


def test_check_timing_t3_refuses_unsorted_overlapping_and_early_pauses() -> None:
    t = make_paused([(10, 12), (20, 25)])
    run_fold.check_timing(t)
    for pauses in ([(20, 25), (10, 12)], [(10, 22), (20, 25)], [(-1, 2)], [(28, 31)], [(5, 4)]):
        bad = dataclasses.replace(t, pauses=tuple(Pause(a * S, b * S) for a, b in pauses))
        with pytest.raises(TimingError) as caught:
            run_fold.check_timing(bad)
        assert caught.value.invariant == "T3", pauses


def make_paused(pauses: list[tuple[int, int]]) -> Timing:
    return run_fold.make_timing(
        0, [(None, 15 * S), (None, 30 * S)], (), [Pause(a * S, b * S) for a, b in pauses], steps=[]
    )


def test_check_timing_refuses_negative_segments_and_unsplit_pauses() -> None:
    t = good_timing()
    first, second = t.segments
    with pytest.raises(TimingError, match="negative"):
        run_fold.check_timing(
            dataclasses.replace(t, segments=(dataclasses.replace(first, ended_at=-1), second))
        )
    moved = (dataclasses.replace(first, paused_ms=0, active_ms=10 * S), second)
    with pytest.raises(TimingError, match="overlap"):
        run_fold.check_timing(dataclasses.replace(t, segments=moved))


# --- the property test ------------------------------------------------------------------

TYPES: list[EventType] = [
    "next",
    "next",
    "lap",
    "skip",
    "pause",
    "resume",
    "stop",
    "discard",
    "start",
    "finish",
]


def random_run(rng: random.Random) -> tuple[list[Step], list[Event]]:
    steps = STEPS[: rng.randint(0, 3)]
    events: list[Event] = [START]
    pauses: list[int] = []
    for n in range(1, rng.randint(1, 16)):
        type_ = rng.choice(TYPES)
        at = rng.randint(-3, 120) * S + rng.choice([0, 0, 1, 999])
        if rng.random() < 0.05:
            at = run_fold.MAX_RUN_MS + rng.choice([0, 1])  # at, or just past, the 7-day limit
        pause = rng.choice(pauses) if pauses and type_ == "resume" else None
        if type_ == "pause":
            pauses.append(n)
        events.append(
            Event(
                id=eid(n),
                type=type_,
                at=at,
                seg=rng.randint(0, 3) if type_ in ("next", "lap", "skip") else None,
                step=rng.choice(["a", "b", "c", None]) if type_ == "skip" else None,
                pause_id=None if pause is None else eid(pause),
            )
        )
        if rng.random() < 0.1:
            events.append(events[-1])  # a replay
    return steps, events


def check_sums(state: RunState, steps: Sequence[Step]) -> None:
    """Segments tile the run, and durations add up exactly."""
    previous = state.started_at
    for s in state.segments:
        assert s.started_at == previous
        assert s.active_ms + s.paused_ms == s.ended_at - s.started_at
        assert s.active_ms >= 0
        assert s.paused_ms >= 0
        previous = s.ended_at
    if state.open is not None:
        assert state.open.started_at == previous
        assert state.open.index == len(state.segments)
    if state.status == "stopped":
        t = run_fold.project_timing(state, steps)
        run_fold.check_timing(t, captured_at=state.ended_at)
        assert sum(s.active_ms for s in t.segments) == t.active_ms
        assert sum(s.paused_ms for s in t.segments) == t.paused_ms
        assert t.active_ms + t.paused_ms == t.ended_at - t.started_at


def reorder(
    rng: random.Random, events: list[Event], first: Event | None, frozen: Frozen | None
) -> list[Event]:
    """A random arrival order in which ``first`` is still the first terminal to arrive, and the
    events before the ``frozen`` cut-off stay before it."""
    if frozen is not None:
        tail = events[frozen.after :]
        rng.shuffle(tail)
        return [*reorder(rng, events[: frozen.after], first, None), *tail]
    rest = list(events)
    if first is not None:
        rest.remove(first)  # one copy: a replay of it stays, so the frozen cut-off doesn't move
    rng.shuffle(rest)
    if first is None:
        return rest
    terminals = [x for x in rest if x.type in ("stop", "discard")]
    others = [x for x in rest if x.type not in ("stop", "discard")]
    cut = rng.randint(0, len(others))
    return [*others[:cut], first, *others[cut:], *terminals]


def first_terminal(state: RunState, events: list[Event]) -> Event | None:
    return next(
        (x for x in events if x.type in ("stop", "discard") and state.effects[x.id].effect == "applied"),
        None,
    )


def test_every_arrival_order_with_the_same_first_terminal_gives_the_same_state() -> None:
    rng = random.Random(20261023)
    stopped = 0
    for _ in range(1500):
        steps, events = random_run(rng)
        frozen = None
        if rng.random() < 0.25:
            frozen = Frozen(
                rng.randint(1, len(events)), rng.choice(["run_edited", "entry_deleted", "already_closed"])
            )
        state = run_fold.fold(RUN, steps, events, frozen=frozen)
        check_sums(state, steps)
        stopped += state.status == "stopped"
        first = first_terminal(state, events)
        for _ in range(6):
            again = run_fold.fold(RUN, steps, reorder(rng, events, first, frozen), frozen=frozen)
            assert again == state
    assert stopped > 300  # the generator reaches stopped runs often
