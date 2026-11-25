"""Fold v4 (docs/specs/timers2.md §3): one test per rule of §3.2 to §3.6, the worked examples
of §6.1 to §6.7 as asserts, and the determinism property of §3.4 (arrival orders that keep the
relative order of terminals, reopens and removes with respect to one another and to their
targets give the same state: ``next``, ``lap``, ``skip``, ``pause`` and ``resume`` commute).
``test_run_fold.py`` keeps the v1 rules; everything there still holds."""

from __future__ import annotations

import random
from collections.abc import Sequence

import pytest

from app.services import run_fold
from app.services.run_fold import Event, EventType, Frozen, LapType, Pause, RunState, Step, Timer

RUN = "0a000000-0000-4000-8000-000000000000"
S = 1000  # one second in ms
DAY = 86_400
NONE = Timer()
TWO = Timer(steps=(Step("a", "Alpha"), Step("b", "Beta")))
THREE = Timer(steps=(Step("a", "Alpha"), Step("b", "Beta"), Step("c", "Gamma")))
RENAMED = Timer(laps=(LapType("cig", "Cig"),))
TIKTOK = Timer(laps=(LapType("run", "Run"), LapType("rest", "Rest")))
THREE_TYPES = Timer(
    steps=(Step("warmup", "Warmup"),),
    laps=(LapType("run", "Run"), LapType("rest", "Rest"), LapType("walk", "Walk")),
)


def eid(n: int) -> str:
    return f"0e000000-0000-4000-8000-{n:012d}"


def e(
    n: int,
    type_: EventType,
    sec: float,
    seg: int | None = None,
    step: str | None = None,
    pause: int | None = None,
    target: int | str | None = None,
) -> Event:
    return Event(
        id=RUN if n == 0 else eid(n),
        type=type_,
        at=round(sec * S),
        seg=seg,
        step=step,
        pause_id=None if pause is None else eid(pause),
        target=eid(target) if isinstance(target, int) else target,
    )


START = e(0, "start", 0)


def fold(events: Sequence[Event], timer: Timer = NONE, frozen: Frozen | None = None) -> RunState:
    return run_fold.fold(RUN, timer, [START, *events], frozen=frozen)


def effect(state: RunState, n: int) -> tuple[str, str | None]:
    eff = state.effects[RUN if n == 0 else eid(n)]
    return eff.effect, eff.reason


def spans(state: RunState) -> list[tuple[str, int, int]]:
    """(label, start s, end s) per closed segment."""
    return [(s.label, s.started_at // S, s.ended_at // S) for s in state.segments]


def times(state: RunState) -> list[tuple[int, int]]:
    """(active s, paused s) per closed segment."""
    return [(s.active_ms // S, s.paused_ms // S) for s in state.segments]


def pauses(state: RunState) -> list[tuple[int, int, str | None]]:
    return [(p.start // S, p.end // S, p.id) for p in state.pauses]


# --- §3.2 lap labelling and §3.3 output additions -----------------------------------------


def test_lap_labels_follow_the_lap_types_in_a_cycle() -> None:
    laps = [e(n, "lap", n * 10, seg=n - 1) for n in range(1, 6)]
    assert [s.label for s in fold(laps).segments] == ["Lap 1", "Lap 2", "Lap 3", "Lap 4", "Lap 5"]
    assert [s.lap_type for s in fold(laps).segments] == [None] * 5
    renamed = fold(laps, RENAMED)
    assert [s.label for s in renamed.segments] == ["Cig 1", "Cig 2", "Cig 3", "Cig 4", "Cig 5"]
    assert [s.lap_type for s in renamed.segments] == ["cig"] * 5
    tiktok = fold(laps, TIKTOK)
    assert [s.label for s in tiktok.segments] == ["Run 1", "Rest 1", "Run 2", "Rest 2", "Run 3"]
    assert [s.lap_type for s in tiktok.segments] == ["run", "rest", "run", "rest", "run"]
    assert tiktok.open is not None
    assert (tiktok.open.label, tiktok.open.lap_type) == ("Rest 3", "rest")


def test_a_step_then_typed_laps() -> None:
    state = fold(
        [e(1, "next", 10, seg=0), *[e(n, "lap", n * 10, seg=n - 1) for n in range(2, 7)]], THREE_TYPES
    )
    assert [(s.kind, s.step, s.lap_type, s.label) for s in state.segments] == [
        ("step", "warmup", None, "Warmup"),
        ("lap", None, "run", "Run 1"),
        ("lap", None, "rest", "Rest 1"),
        ("lap", None, "walk", "Walk 1"),
        ("lap", None, "run", "Run 2"),
        ("lap", None, "rest", "Rest 2"),
    ]


def test_next_lap_type_is_the_type_a_lap_tap_would_open() -> None:
    assert fold([], TIKTOK).next_lap_type == "run"  # the first lap
    assert fold([e(1, "lap", 10, seg=0)], TIKTOK).next_lap_type == "run"  # Rest 1 is open: a lap opens Run 2
    assert fold([], THREE_TYPES).next_lap_type == "run"  # a step is open: the lap would be lap 1
    assert fold([e(1, "next", 10, seg=0)], THREE_TYPES).next_lap_type == "rest"  # Run 1 is open
    assert fold([]).next_lap_type is None  # untyped
    assert fold([e(1, "stop", 10)], TIKTOK).next_lap_type is None  # not open
    assert fold([e(1, "discard", 10)], TIKTOK).next_lap_type is None


def test_lap_count_is_the_closed_lap_segments() -> None:
    state = fold([e(1, "next", 10, seg=0), e(2, "lap", 20, seg=1), e(3, "lap", 30, seg=2)], THREE_TYPES)
    assert state.lap_count == 2
    assert fold([e(1, "lap", 10, seg=0), e(2, "stop", 20)]).lap_count == 2  # the stop closes Lap 2


def test_terminal_id_is_the_applied_stop() -> None:
    assert fold([]).terminal_id is None
    assert fold([e(1, "stop", 10)]).terminal_id == eid(1)
    assert fold([e(1, "discard", 10)]).terminal_id is None
    assert fold([e(1, "stop", 10), e(2, "reopen", 20, target=1)]).terminal_id is None


def test_segments_and_pauses_carry_their_opening_events() -> None:
    state = fold(
        [
            e(1, "next", 10, seg=0),
            e(2, "pause", 12),
            e(3, "resume", 14, pause=2),
            e(4, "lap", 20, seg=1),
            e(5, "skip", 25, seg=2, step="c"),
            e(6, "stop", 30),
        ],
        THREE,
    )
    assert [(s.event_id, s.opened_by) for s in state.segments] == [
        (None, "start"),
        (eid(1), "next"),
        (eid(4), "lap"),  # the skip relabelled this segment; it didn't open one
    ]
    assert state.pauses == (Pause(12 * S, 14 * S, id=eid(2)),)
    timing = run_fold.project_timing(state, THREE)
    assert timing.terminal_id == eid(6)
    assert [s.event_id for s in timing.segments] == [None, eid(1), eid(4)]
    assert timing.pauses[0].id == eid(2)


def test_an_edited_timing_nulls_segment_and_pause_ids_and_keeps_the_terminal() -> None:
    made = run_fold.make_timing(
        0,
        [(Step("a", "Alpha"), 10 * S), (None, 20 * S)],
        (),
        [Pause(2 * S, 3 * S, id=eid(9))],
        timer=TIKTOK,
        edited=True,
        terminal_id=eid(7),
    )
    assert made.terminal_id == eid(7)
    assert [(s.event_id, s.opened_by) for s in made.segments] == [(None, None), (None, None)]
    assert made.pauses == (Pause(2 * S, 3 * S, id=None),)
    assert (made.segments[1].lap_type, made.segments[1].label) == ("run", "Run 1")


def test_a_pre_v2_timing_parses_with_null_ids() -> None:
    v1 = {
        "started_at": "2026-10-23T08:00:00Z",
        "ended_at": "2026-10-23T08:00:10Z",
        "active_ms": 10_000,
        "paused_ms": 0,
        "complete": True,
        "edited": False,
        "segments": [
            {
                "kind": "lap",
                "step": None,
                "label": "Lap 1",
                "started_at": "2026-10-23T08:00:00Z",
                "ended_at": "2026-10-23T08:00:10Z",
                "active_ms": 10_000,
                "paused_ms": 0,
            }
        ],
        "skipped": [],
        "pauses": [{"start": "2026-10-23T08:00:01Z", "end": "2026-10-23T08:00:01Z"}],
    }
    t = run_fold.timing_from_json(v1)
    assert t.terminal_id is None
    assert (t.segments[0].lap_type, t.segments[0].event_id, t.segments[0].opened_by) == (None, None, None)
    assert t.pauses[0].id is None
    out = run_fold.timing_json(t)
    assert out["terminal_id"] is None
    assert out["segments"][0]["lap_type"] is None
    assert out["pauses"][0]["id"] is None


# --- §3.4 pass 1: terminals, reopen, revert -----------------------------------------------


def test_a_reopen_clears_the_terminal_and_the_run_is_running_again() -> None:
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1)])
    assert (state.status, state.ended_at, state.terminal_id) == ("running", None, None)
    assert effect(state, 1) == ("applied", None)  # the reopened stop stays applied
    assert effect(state, 2) == ("applied", None)
    assert state.open is not None
    assert state.open.started_at == 0  # the stop did not close the open segment
    assert pauses(state) == [(10, 20, eid(1))]  # the gap is a pause with the stop's id


def test_a_later_stop_is_the_new_terminal_and_ends_the_reopen_transaction() -> None:
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "stop", 30), e(4, "discard", 40)])
    assert (state.status, state.ended_at, state.terminal_id) == ("stopped", 30 * S, eid(3))
    assert effect(state, 4) == ("void", "already_closed")  # not a revert of the older reopen
    assert pauses(state) == [(10, 20, eid(1))]


def test_a_discard_on_a_reopened_run_reverts_the_reopen() -> None:
    state = fold(
        [e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "lap", 25, seg=0), e(4, "discard", 30)]
    )
    assert (state.status, state.ended_at, state.terminal_id) == ("stopped", 10 * S, eid(1))
    assert effect(state, 2) == ("void", "reverted")
    assert effect(state, 3) == ("void", "after_stop")
    assert effect(state, 4) == ("applied", None)
    assert spans(state) == [("Lap 1", 0, 10)]
    assert pauses(state) == []


def test_a_revert_restores_a_removed_stop_and_voids_its_remove() -> None:
    state = fold(
        [e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "remove", 25, target=1), e(4, "discard", 30)]
    )
    assert (state.status, state.ended_at, state.terminal_id) == ("stopped", 10 * S, eid(1))
    assert effect(state, 1) == ("applied", None)
    assert effect(state, 2) == ("void", "reverted")
    assert effect(state, 3) == ("void", "no_target")
    assert effect(state, 4) == ("applied", None)


def test_after_a_revert_the_stop_can_be_reopened_again() -> None:
    state = fold(
        [
            e(1, "stop", 10),
            e(2, "reopen", 20, target=1),
            e(3, "discard", 30),
            e(4, "reopen", 40, target=1),
            e(5, "stop", 50),
        ]
    )
    assert effect(state, 4) == ("applied", None)
    assert (state.status, state.ended_at) == ("stopped", 50 * S)
    assert pauses(state) == [(10, 40, eid(1))]  # only the second gap: the first reopen was reverted


def test_effects_are_recomputed_from_scratch_on_every_fold() -> None:
    # stop, reopen, remove the gap, revert, reopen, remove the gap, revert: the second remove is
    # eligible again after the revert restored the stop, and the second revert voids it in turn.
    events = [
        e(1, "stop", 10),
        e(2, "reopen", 20, target=1),
        e(3, "remove", 21, target=1),
        e(4, "discard", 30),
        e(5, "reopen", 40, target=1),
        e(6, "remove", 41, target=1),
        e(7, "discard", 50),
    ]
    state = fold(events)
    assert effect(state, 3) == ("void", "no_target")
    assert effect(state, 6) == ("void", "no_target")
    assert effect(state, 5) == ("void", "reverted")
    assert (state.status, state.ended_at, state.terminal_id) == ("stopped", 10 * S, eid(1))
    before_last = fold(events[:-1])
    assert effect(before_last, 6) == ("applied", None)
    assert effect(before_last, 1) == ("void", "deleted")
    assert before_last.status == "running"
    assert fold(events) == state  # pure: nothing is retained between folds


def test_one_reopen_transaction_at_a_time() -> None:
    state = fold(
        [
            e(1, "stop", 10),
            e(2, "reopen", 20, target=1),
            e(3, "stop", 30),
            e(4, "reopen", 40, target=3),
            e(5, "discard", 50),
            e(6, "discard", 60),
        ]
    )
    assert effect(state, 2) == ("applied", None)
    assert effect(state, 4) == ("void", "reverted")
    assert effect(state, 5) == ("applied", None)
    assert effect(state, 6) == ("void", "already_closed")
    assert (state.status, state.ended_at) == ("stopped", 30 * S)


def test_reopen_needs_a_seen_stop() -> None:
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=99)])
    assert effect(state, 2) == ("void", "no_target")
    state = fold([e(1, "pause", 5), e(2, "stop", 10), e(3, "reopen", 20, target=1)])  # a pause, not a stop
    assert effect(state, 3) == ("void", "no_target")
    state = fold([e(2, "reopen", 20, target=1), e(1, "stop", 10)])  # arrives before its target
    assert effect(state, 2) == ("void", "no_target")
    assert state.status == "stopped"
    assert fold([e(1, "stop", 10), e(2, "reopen", 20)]).effects[eid(2)].reason == "no_target"


def test_reopen_after_a_discard_is_already_closed() -> None:
    state = fold([e(1, "discard", 10), e(2, "stop", 11), e(3, "reopen", 20, target=2)])
    assert effect(state, 3) == ("void", "already_closed")
    assert state.status == "discarded"


def test_reopen_must_name_the_current_terminal() -> None:
    state = fold([e(1, "stop", 10), e(2, "stop", 11), e(3, "reopen", 20, target=2)])
    assert effect(state, 3) == ("void", "not_stopped")
    assert state.status == "stopped"
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "reopen", 21, target=1)])  # double tap
    assert effect(state, 3) == ("void", "not_stopped")
    assert state.status == "running"


def test_reopen_at_or_before_its_stop_is_stale() -> None:
    assert effect(fold([e(1, "stop", 10), e(2, "reopen", 10, target=1)]), 2) == ("void", "stale")
    assert effect(fold([e(1, "stop", 10), e(2, "reopen", 9, target=1)]), 2) == ("void", "stale")


def test_reopen_beyond_seven_days_is_too_long() -> None:
    state = fold([e(1, "stop", 10), e(2, "reopen", 7 * DAY + 1, target=1)])
    assert effect(state, 2) == ("void", "too_long")
    assert state.status == "stopped"
    assert effect(fold([e(1, "stop", 10), e(2, "reopen", 7 * DAY, target=1)]), 2) == ("applied", None)


def test_reopen_checks_in_order_no_target_already_closed_not_stopped_stale_too_long() -> None:
    # A stale and too-long reopen of a non-terminal stop is not_stopped first.
    state = fold([e(1, "stop", 10), e(2, "stop", 11), e(3, "reopen", 8 * DAY, target=2)])
    assert effect(state, 3) == ("void", "not_stopped")
    # A stale reopen beyond seven days: stale first.
    state = fold([e(1, "stop", 7 * DAY), e(2, "reopen", 7 * DAY, target=1)])
    assert effect(state, 2) == ("void", "stale")


# --- §3.4 pass 1: remove -----------------------------------------------------------------


def test_remove_eligibility_is_by_type_and_identity_only() -> None:
    base = [
        e(1, "next", 10, seg=0),
        e(2, "pause", 20),
        e(3, "resume", 25, pause=2),
        e(4, "lap", 30, seg=1),
        e(5, "lap", 30.5, seg=1),  # stale, still a lap
        e(6, "skip", 35, seg=2, step="b"),
    ]
    state = fold(
        [*base, e(7, "remove", 40, target=2), e(8, "remove", 41, target=4), e(9, "remove", 42, target=5)],
        THREE,
    )
    assert effect(state, 7) == ("applied", None)
    assert effect(state, 8) == ("applied", None)
    assert effect(state, 9) == ("applied", None)  # a stale lap: applied, marks it deleted, changes nothing
    for target in (1, 3, 6, 0, 99):  # next, resume, skip, start, unknown
        assert effect(fold([*base, e(7, "remove", 40, target=target)], THREE), 7) == ("void", "no_target"), (
            target
        )
    assert effect(fold([*base, e(7, "remove", 40)], THREE), 7) == ("void", "no_target")
    assert effect(fold([*base, e(7, "remove", 40, target=7)], THREE), 7) == ("void", "no_target")


def test_remove_of_a_terminal_stop_is_no_target_unless_it_was_reopened() -> None:
    state = fold([e(1, "stop", 10), e(2, "remove", 20, target=1)])
    assert effect(state, 2) == ("void", "no_target")
    assert state.status == "stopped"
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "remove", 21, target=1)])
    assert effect(state, 3) == ("applied", None)
    assert effect(state, 1) == ("void", "deleted")  # the gap pause goes
    assert effect(state, 2) == ("applied", None)  # its reopen stays applied
    assert (state.status, state.terminal_id, pauses(state)) == ("running", None, [])


def test_remove_of_a_stop_of_an_ended_transaction_is_still_eligible() -> None:
    state = fold(
        [e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "stop", 30), e(4, "remove", 31, target=1)]
    )
    assert effect(state, 4) == ("applied", None)
    assert (state.status, state.ended_at, pauses(state)) == ("stopped", 30 * S, [])
    assert run_fold.project_timing(state, NONE).paused_ms == 0


def test_remove_needs_at_after_its_target() -> None:
    assert effect(fold([e(1, "lap", 10, seg=0), e(2, "remove", 10, target=1)]), 2) == ("void", "no_target")
    assert effect(fold([e(1, "lap", 10, seg=0), e(2, "remove", 9, target=1)]), 2) == ("void", "no_target")
    assert effect(fold([e(1, "lap", 10, seg=0), e(2, "remove", 10.001, target=1)]), 2) == ("applied", None)


def test_remove_twice_is_no_target() -> None:
    state = fold([e(1, "pause", 10), e(2, "remove", 20, target=1), e(3, "remove", 21, target=1)])
    assert effect(state, 2) == ("applied", None)
    assert effect(state, 3) == ("void", "no_target")


def test_remove_has_no_seven_day_bound() -> None:
    state = fold([e(1, "lap", 10, seg=0), e(2, "stop", 20), e(3, "remove", 2 * 365 * DAY, target=1)])
    assert effect(state, 3) == ("applied", None)
    assert spans(state) == [("Lap 1", 0, 20)]


def test_a_remove_before_its_target_in_arrival_order_is_no_target_for_good() -> None:
    state = fold([e(2, "remove", 20, target=1), e(1, "lap", 10, seg=0)])
    assert effect(state, 2) == ("void", "no_target")
    assert effect(state, 1) == ("applied", None)


def test_frozen_reopen_and_remove_carry_the_frozen_reason() -> None:
    events = [e(1, "stop", 10), e(2, "reopen", 20, target=1)]
    state = fold(events, frozen=Frozen(after=2, reason="run_edited"))  # index 2 is event 2
    assert effect(state, 2) == ("void", "run_edited")
    assert state.status == "stopped"
    events = [e(1, "pause", 5), e(2, "stop", 10), e(3, "remove", 20, target=1)]
    state = fold(events, frozen=Frozen(after=3, reason="entry_deleted"))
    assert effect(state, 3) == ("void", "entry_deleted")
    assert pauses(state) == [(5, 10, eid(1))]


# --- §3.4 pass 2: the gap, roles and equal-time ordering ----------------------------------


def test_a_reopened_stop_does_not_close_the_open_segment() -> None:
    state = fold([e(1, "lap", 5, seg=0), e(2, "stop", 10), e(3, "reopen", 20, target=2), e(4, "stop", 30)])
    assert spans(state) == [("Lap 1", 0, 5), ("Lap 2", 5, 30)]
    assert times(state) == [(5, 0), (15, 10)]
    assert pauses(state) == [(10, 20, eid(2))]


def test_a_reopen_ends_whatever_pause_is_open() -> None:
    # Stop while paused: the user pause continues through the gap and ends at the reopen.
    state = fold([e(1, "pause", 5), e(2, "stop", 10), e(3, "reopen", 20, target=2), e(4, "stop", 30)])
    assert pauses(state) == [(5, 20, eid(2))]  # the gap took the pause over: it carries the stop's id
    assert times(state) == [(15, 15)]


def test_the_gap_owns_the_open_pause() -> None:
    inside = [e(1, "pause", 5), e(2, "stop", 10), e(3, "reopen", 20, target=2), e(4, "resume", 15, pause=1)]
    state = fold(inside)
    assert effect(state, 4) == ("void", "stale")  # stopped time never counts as active
    assert pauses(state) == [(5, 20, eid(2))]
    removed = fold([*inside, e(5, "remove", 25, target=2)])
    assert effect(removed, 4) == ("applied", None)  # no takeover: the user asked for the gap to be active
    assert pauses(removed) == [(5, 15, eid(1))]


def test_gap_removed_a_user_pause_inside_the_gap_ends_at_the_reopen() -> None:
    state = fold(
        [
            e(1, "stop", 10),
            e(2, "reopen", 20, target=1),
            e(3, "remove", 21, target=1),
            e(4, "pause", 12),  # offline, inside the gap
            e(5, "resume", 25, pause=4),  # after the reopen ended it
        ]
    )
    assert effect(state, 4) == ("applied", None)
    assert effect(state, 5) == ("void", "not_paused")
    assert pauses(state) == [(12, 20, eid(4))]
    assert state.status == "running"


def test_a_reopens_resume_role_is_silent_when_no_pause_is_open() -> None:
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "remove", 21, target=1)])
    assert effect(state, 2) == ("applied", None)  # not not_paused: the deviation of §3.4
    assert (state.status, pauses(state)) == ("running", [])


def test_a_gap_pause_sorts_before_user_events_at_the_same_instant() -> None:
    state = fold(
        [e(1, "pause", 5), e(2, "stop", 10), e(3, "reopen", 20, target=2), e(4, "resume", 10, pause=1)]
    )
    assert effect(state, 4) == ("void", "stale")  # never not_paused
    assert pauses(state) == [(5, 20, eid(2))]


def test_a_gap_resume_sorts_after_user_events_at_the_same_instant() -> None:
    present = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "pause", 20)])
    assert effect(present, 3) == ("void", "already_paused")
    assert (present.status, pauses(present)) == ("running", [(10, 20, eid(1))])
    removed = fold(
        [e(1, "stop", 10), e(2, "reopen", 20, target=1), e(3, "pause", 20), e(4, "remove", 21, target=1)]
    )
    assert effect(removed, 3) == ("applied", None)
    assert pauses(removed) == [(20, 20, eid(3))]  # a zero-length pause, ended by the gap resume at once
    assert removed.status == "running"


def test_two_gap_pauses_at_the_same_instant_sort_by_stop_id() -> None:
    # S1 reopened; an offline stop S2 at the same instant arrives and becomes the terminal; it is
    # reopened later. The later stop by id takes over the pause; each gap resume ends what is open.
    state = fold(
        [
            e(2, "stop", 10),
            e(3, "reopen", 20, target=2),
            e(1, "stop", 10),
            e(4, "reopen", 30, target=1),
        ]
    )
    assert state.status == "running"
    assert pauses(state) == [(10, 20, eid(2))]  # id eid(2) > eid(1): it took over; R(3) at 20 ended it
    assert all(effect(state, n) == ("applied", None) for n in (1, 2, 3, 4))


OFFLINE_STOP = [
    e(1, "stop", 10),
    e(2, "reopen", 30, target=1),
    e(3, "lap", 35, seg=0),
    e(4, "stop", 20),  # another device, offline
]


def test_an_offline_stop_earlier_than_the_reopen_becomes_the_terminal() -> None:
    state = fold(OFFLINE_STOP)
    assert (state.status, state.ended_at, state.terminal_id) == ("stopped", 20 * S, eid(4))
    assert pauses(state) == [(10, 20, eid(1))]  # the gap is cut by the stop-while-paused rule
    assert effect(state, 3) == ("void", "after_stop")
    recovered = fold([*OFFLINE_STOP, e(5, "reopen", 40, target=4)])  # a reopen of that stop recovers them
    assert effect(recovered, 3) == ("applied", None)
    assert pauses(recovered) == [(10, 20, eid(1)), (20, 40, eid(4))]


def test_roles_outside_the_run_are_skipped_silently() -> None:
    # The gap resume lies after the terminal: no pause is recorded past the end (T3).
    state = fold([e(1, "stop", 10), e(2, "reopen", 30, target=1), e(3, "stop", 20)])
    assert pauses(state) == [(10, 20, eid(1))]
    run_fold.check_timing(run_fold.project_timing(state, NONE), captured_at=20 * S)


# --- §3.4 pass 2: removed pauses and laps -------------------------------------------------


def test_a_removed_pause_and_its_resume_are_deleted() -> None:
    state = fold(
        [
            e(1, "pause", 60),
            e(2, "resume", 80, pause=1),
            e(3, "lap", 120, seg=0),
            e(4, "remove", 130, target=1),
        ]
    )
    assert effect(state, 1) == ("void", "deleted")
    assert effect(state, 2) == ("void", "deleted")
    assert pauses(state) == []
    assert times(state) == [(120, 0)]


def test_removing_a_void_pause_changes_only_its_resumes_reason() -> None:
    events = [
        e(1, "pause", 60),
        e(2, "pause", 61),
        e(3, "resume", 70, pause=2),
        e(4, "resume", 80, pause=1),
    ]
    before = fold(events)
    assert effect(before, 2) == ("void", "already_paused")
    assert effect(before, 3) == ("void", "stale")
    after = fold([*events, e(5, "remove", 90, target=2)])
    assert effect(after, 2) == ("void", "deleted")
    assert effect(after, 3) == ("void", "deleted")
    assert pauses(after) == pauses(before) == [(60, 80, eid(1))]


def test_removing_an_applied_pause_can_change_which_pause_applies() -> None:
    events = [
        e(1, "pause", 60),
        e(2, "pause", 65),
        e(3, "resume", 70, pause=2),
        e(4, "resume", 80, pause=1),
        e(5, "remove", 90, target=1),
    ]
    state = fold(events)
    assert effect(state, 2) == ("applied", None)
    assert effect(state, 3) == ("applied", None)
    assert effect(state, 4) == ("void", "deleted")
    assert pauses(state) == [(65, 70, eid(2))]


def test_a_removed_lap_merges_into_the_previous_segment_and_renumbers() -> None:
    state = fold([e(1, "lap", 60, seg=0), e(2, "lap", 120, seg=1), e(3, "remove", 130, target=1)], TIKTOK)
    assert effect(state, 1) == ("void", "deleted")
    assert effect(state, 2) == ("applied", None)
    assert spans(state) == [("Run 1", 0, 120)]
    assert state.open is not None
    assert (state.open.label, state.next_lap_type, state.lap_count) == ("Rest 1", "run", 1)


def test_the_seg_guard_counts_removed_boundaries_the_tapping_device_saw() -> None:
    # §6.4: a double tap removed later; the lap tapped between it and its removal keeps its seg.
    events = [
        e(1, "lap", 60, seg=0),
        e(2, "lap", 60.4, seg=1),
        e(3, "lap", 120, seg=2),
        e(4, "remove", 125, target=2),
    ]
    state = fold(events, TIKTOK)
    assert effect(state, 3) == ("applied", None)
    assert spans(state) == [("Run 1", 0, 60), ("Rest 1", 60, 120)]
    assert state.open is not None
    assert (state.open.label, state.next_lap_type, state.lap_count) == ("Run 2", "rest", 2)
    after = fold([*events, e(5, "lap", 150, seg=2)], TIKTOK)  # the device saw two closed laps
    assert effect(after, 5) == ("applied", None)
    assert after.open is not None
    assert after.open.label == "Rest 2"
    # Product contract: a device that had not seen the remove, tapping after remove.at with the
    # boundary counted, is stale and re-taps.
    stale = fold([*events, e(5, "lap", 150, seg=3)], TIKTOK)
    assert effect(stale, 5) == ("void", "stale")


def test_ghosts_stack() -> None:
    state = fold(
        [
            e(1, "lap", 60, seg=0),
            e(2, "lap", 90, seg=1),
            e(3, "lap", 120, seg=2),
            e(4, "remove", 130, target=1),
            e(5, "remove", 131, target=2),
        ]
    )
    assert effect(state, 3) == ("applied", None)
    assert spans(state) == [("Lap 1", 0, 120)]


def test_a_removed_lap_that_was_stale_is_no_ghost() -> None:
    state = fold(
        [
            e(1, "lap", 60, seg=0),
            e(2, "lap", 61, seg=0),  # a double tap with the same seg: stale
            e(3, "lap", 120, seg=1),
            e(4, "remove", 130, target=2),
        ]
    )
    assert effect(state, 2) == ("void", "deleted")
    assert effect(state, 3) == ("applied", None)  # expected 1 + 0 ghosts
    assert spans(state) == [("Lap 1", 0, 60), ("Lap 2", 60, 120)]


def test_a_ghost_only_counts_between_the_lap_and_its_removal() -> None:
    state = fold(
        [
            e(1, "lap", 60, seg=0),
            e(2, "lap", 120, seg=1),
            e(3, "remove", 125, target=1),
            e(4, "lap", 140, seg=1),  # after the remove: one closed lap, no ghost
        ]
    )
    assert effect(state, 4) == ("applied", None)
    assert spans(state) == [("Lap 1", 0, 120), ("Lap 2", 120, 140)]


# --- §3.6 late merges, at fold level -------------------------------------------------------


def test_a_remove_on_a_stopped_run_is_a_late_merge_and_the_timing_stays_unedited() -> None:
    state = fold(
        [e(1, "lap", 60, seg=0), e(2, "lap", 65, seg=1), e(3, "stop", 180), e(4, "remove", 220, target=1)],
        RENAMED,
    )
    assert effect(state, 4) == ("applied", None)  # exempt from after_stop
    timing = run_fold.project_timing(state, RENAMED)
    assert timing.edited is False
    assert [(s.label, s.active_ms) for s in timing.segments] == [("Cig 1", 65 * S), ("Cig 2", 115 * S)]
    assert timing.ended_at == 180 * S


def test_a_reopen_is_exempt_from_after_stop() -> None:
    state = fold([e(1, "stop", 10), e(2, "reopen", 20, target=1)])
    assert effect(state, 2) == ("applied", None)
    assert fold([e(1, "stop", 10), e(2, "lap", 20, seg=0)]).effects[eid(2)].reason == "after_stop"


# --- §6 worked examples -------------------------------------------------------------------


def test_6_1_accidental_stop_reopen_restop() -> None:
    events = [
        e(1, "lap", 60, seg=0),
        e(2, "stop", 90),
        e(99, "finish", 95),
        e(3, "reopen", 110, target=2),
        e(4, "lap", 150, seg=1),
        e(5, "stop", 180),
    ]
    after_3 = fold(events[:2])
    assert spans(after_3) == [("Lap 1", 0, 60), ("Lap 2", 60, 90)]
    assert run_fold.project_timing(after_3, NONE).active_ms == 90_000
    after_5 = fold(events[:4])
    assert (after_5.status, after_5.paused_since, after_5.terminal_id) == ("running", None, None)
    assert after_5.open is not None
    assert (after_5.open.label, after_5.open.index, after_5.open.started_at) == ("Lap 2", 1, 60 * S)
    assert pauses(after_5) == [(90, 110, eid(2))]
    after_7 = fold(events)
    assert spans(after_7) == [("Lap 1", 0, 60), ("Lap 2", 60, 150), ("Lap 3", 150, 180)]
    assert times(after_7) == [(60, 0), (70, 20), (30, 0)]
    timing = run_fold.project_timing(after_7, NONE)
    assert (timing.active_ms, timing.paused_ms, timing.ended_at) == (160_000, 20_000, 180 * S)
    assert eid(99) not in after_7.effects
    assert [s.label for s in fold(events, RENAMED).segments] == ["Cig 1", "Cig 2", "Cig 3"]


def test_6_2_reopen_then_revert_by_discard() -> None:
    state = fold(
        [e(1, "stop", 90), e(2, "reopen", 110, target=1), e(3, "lap", 130, seg=0), e(4, "discard", 150)]
    )
    assert (state.status, state.ended_at, state.terminal_id) == ("stopped", 90 * S, eid(1))
    assert spans(state) == [("Lap 1", 0, 90)]
    assert effect(state, 2) == ("void", "reverted")
    assert effect(state, 3) == ("void", "after_stop")
    assert effect(state, 4) == ("applied", None)


def test_6_3_remove_a_pause_and_remove_the_gap_pause() -> None:
    a = fold(
        [
            e(1, "pause", 60),
            e(2, "resume", 80, pause=1),
            e(3, "lap", 120, seg=0),
            e(4, "remove", 130, target=1),
        ]
    )
    assert (effect(a, 1), effect(a, 2)) == (("void", "deleted"), ("void", "deleted"))
    assert (pauses(a), times(a)) == ([], [(120, 0)])
    b = [e(1, "stop", 60), e(2, "reopen", 90, target=1), e(3, "remove", 100, target=1)]
    state = fold(b)
    assert effect(state, 1) == ("void", "deleted")
    assert effect(state, 2) == ("applied", None)
    assert (state.terminal_id, pauses(state), state.open is not None and state.open.started_at) == (
        None,
        [],
        0,
    )
    stopped = fold([*b, e(4, "stop", 120)])
    assert (spans(stopped), times(stopped), pauses(stopped)) == ([("Lap 1", 0, 120)], [(120, 0)], [])
    reverted = fold([*b, e(4, "discard", 110)])
    assert effect(reverted, 1) == ("applied", None)
    assert effect(reverted, 3) == ("void", "no_target")
    assert (reverted.status, reverted.ended_at) == ("stopped", 60 * S)


def test_6_4_remove_a_double_tapped_lap_in_a_run_rest_cycle() -> None:
    events = [e(1, "lap", 60, seg=0), e(2, "lap", 60.4, seg=1), e(3, "lap", 120, seg=2)]
    before = fold(events, TIKTOK)
    assert spans(before) == [("Run 1", 0, 60), ("Rest 1", 60, 60), ("Run 2", 60, 120)]
    assert before.open is not None
    assert before.open.label == "Rest 2"
    after = fold([*events, e(4, "remove", 125, target=2)], TIKTOK)
    assert effect(after, 2) == ("void", "deleted")
    assert effect(after, 3) == ("applied", None)
    assert spans(after) == [("Run 1", 0, 60), ("Rest 1", 60, 120)]
    assert after.open is not None
    assert (after.open.label, after.next_lap_type, after.lap_count) == ("Run 2", "rest", 2)
    final = fold([*events, e(4, "remove", 125, target=2), e(5, "lap", 150, seg=2)], TIKTOK)
    assert effect(final, 5) == ("applied", None)
    assert final.open is not None
    assert final.open.label == "Rest 2"


def test_6_5_remove_a_lap_on_a_stopped_run_then_a_late_lap() -> None:
    events = [e(1, "lap", 60, seg=0), e(2, "lap", 65, seg=1), e(3, "stop", 180)]
    before = fold(events, RENAMED)
    assert spans(before) == [("Cig 1", 0, 60), ("Cig 2", 60, 65), ("Cig 3", 65, 180)]
    merged = fold([*events, e(4, "remove", 220, target=1)], RENAMED)
    assert spans(merged) == [("Cig 1", 0, 65), ("Cig 2", 65, 180)]
    assert run_fold.project_timing(merged, RENAMED).edited is False
    late = fold([*events, e(4, "remove", 220, target=1), e(5, "lap", 120, seg=2)], RENAMED)
    assert effect(late, 5) == ("applied", None)  # expected = 1 closed + the ghost (60 < 120 < 220)
    assert spans(late) == [("Cig 1", 0, 65), ("Cig 2", 65, 120), ("Cig 3", 120, 180)]
    assert [s.active_ms for s in late.segments] == [65_000, 55_000, 60_000]
    into_next = fold([*events, e(4, "remove", 220, target=2)], RENAMED)
    assert spans(into_next) == [("Cig 1", 0, 60), ("Cig 2", 60, 180)]


def test_6_6_two_devices_offline_lap_inside_the_gap() -> None:
    events = [e(1, "lap", 60, seg=0), e(2, "stop", 120), e(3, "lap", 130, seg=1)]
    closed = fold(events)
    assert effect(closed, 3) == ("void", "after_stop")
    reopened = fold([*events, e(4, "reopen", 150, target=2)])
    assert effect(reopened, 3) == ("applied", None)
    assert spans(reopened) == [("Lap 1", 0, 60), ("Lap 2", 60, 130)]
    assert reopened.open is not None
    assert (reopened.open.label, reopened.open.started_at) == ("Lap 3", 130 * S)
    restopped = fold([*events, e(4, "reopen", 150, target=2), e(5, "stop", 180)])
    assert spans(restopped) == [("Lap 1", 0, 60), ("Lap 2", 60, 130), ("Lap 3", 130, 180)]
    assert times(restopped) == [(60, 0), (60, 10), (30, 20)]
    assert pauses(restopped) == [(120, 150, eid(2))]


def test_6_7_offline_replay_reopen_behind_a_blocked_start() -> None:
    local = fold([e(1, "stop", 60), e(2, "reopen", 80, target=1), e(3, "lap", 100, seg=0)])
    assert (local.status, pauses(local)) == ("running", [(60, 80, eid(1))])
    assert effect(local, 3) == ("applied", None)
    # (c) the stop was refused: the reopen is no_target, the run is open since 0:00 with no gap.
    server = fold([e(2, "reopen", 80, target=1), e(3, "lap", 100, seg=0)])
    assert effect(server, 2) == ("void", "no_target")
    assert (server.status, pauses(server)) == ("running", [])
    assert spans(server) == [("Lap 1", 0, 100)]


# --- the property test ----------------------------------------------------------------------

TIMERS = [NONE, TWO, THREE, RENAMED, TIKTOK, THREE_TYPES]
TYPES: list[EventType] = [
    "next",
    "next",
    "lap",
    "lap",
    "skip",
    "pause",
    "resume",
    "stop",
    "stop",
    "discard",
    "reopen",
    "reopen",
    "remove",
    "remove",
    "start",
    "finish",
]
ORDERED: frozenset[str] = frozenset({"stop", "discard", "reopen", "remove"})


def random_run(rng: random.Random) -> tuple[Timer, list[Event]]:
    timer = rng.choice(TIMERS)
    events: list[Event] = [START]
    pauses_: list[int] = []
    stops: list[Event] = []
    for n in range(1, rng.randint(1, 18)):
        type_ = rng.choice(TYPES)
        at = rng.randint(-3, 120) * S + rng.choice([0, 0, 1, 999])
        if rng.random() < 0.05:
            at = run_fold.MAX_RUN_MS + rng.choice([0, 1])  # at, or just past, the 7-day limit
        pause = rng.choice(pauses_) if pauses_ and type_ == "resume" else None
        target: str | None = None
        if type_ == "reopen":
            if stops and rng.random() < 0.85:
                stop = rng.choice(stops)
                target = stop.id
                if rng.random() < 0.8:  # after the stop, mostly: an applied reopen is the point
                    at = stop.at + rng.randint(0, 40) * S
            else:
                target = rng.choice([None, eid(99)])
        elif type_ == "remove":
            if len(events) > 1 and rng.random() < 0.9:
                victim = rng.choice(events[1:])
                target = victim.id
                if rng.random() < 0.8:
                    at = victim.at + rng.choice([0, 1, 1000, 5 * S, 400 * DAY * S])
            else:
                target = rng.choice([None, eid(99)])
        if type_ == "pause":
            pauses_.append(n)
        event = Event(
            id=eid(n),
            type=type_,
            at=at,
            seg=rng.randint(0, 4) if type_ in ("next", "lap", "skip") else None,
            step=rng.choice(["a", "b", "c", "warmup", None]) if type_ == "skip" else None,
            pause_id=None if pause is None else eid(pause),
            target=target,
        )
        if type_ == "stop":
            stops.append(event)
        events.append(event)
        if rng.random() < 0.1:
            events.append(events[-1])  # a replay
    return timer, events


def check_sums(state: RunState, timer: Timer) -> None:
    """Segments tile the run, durations add up exactly, and a stopped run's timing passes T1 to T5."""
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
    assert state.lap_count == sum(s.kind == "lap" for s in state.segments)
    assert (state.terminal_id is not None) == (state.status == "stopped")
    if state.status == "stopped":
        t = run_fold.project_timing(state, timer)
        run_fold.check_timing(t, captured_at=state.ended_at)
        assert sum(s.active_ms for s in t.segments) == t.active_ms
        assert sum(s.paused_ms for s in t.segments) == t.paused_ms
        assert t.active_ms + t.paused_ms == t.ended_at - t.started_at
        assert t.terminal_id == state.terminal_id


def fixed_ids(events: Sequence[Event]) -> set[str]:
    """The events whose relative arrival order the property keeps: terminals, reopens, removes
    and their targets (by id, so a replay stays with its original)."""
    ordered = [x for x in events if x.type in ORDERED]
    return {x.id for x in ordered} | {x.target for x in ordered if x.target is not None}


def reorder(rng: random.Random, events: list[Event], frozen: Frozen | None) -> list[Event]:
    """A random arrival order that keeps the fixed events as a subsequence, and the events before
    the ``frozen`` cut-off before it (those after it are void whatever their order)."""
    if frozen is not None:
        tail = events[frozen.after :]
        rng.shuffle(tail)
        return [*reorder(rng, events[: frozen.after], None), *tail]
    keep = fixed_ids(events)
    fixed = [x for x in events if x.id in keep]
    free = [x for x in events if x.id not in keep]
    rng.shuffle(free)
    slots = ["fixed"] * len(fixed) + ["free"] * len(free)
    rng.shuffle(slots)
    out: list[Event] = []
    for slot in slots:
        out.append(fixed.pop(0) if slot == "fixed" else free.pop(0))
    return out


def test_arrival_orders_that_keep_terminals_reopens_and_removes_in_order_give_the_same_state() -> None:
    rng = random.Random(20261125)
    reopened = removed = stopped = 0
    for _ in range(2000):
        timer, events = random_run(rng)
        frozen = None
        if rng.random() < 0.2:
            frozen = Frozen(
                rng.randint(1, len(events)), rng.choice(["run_edited", "entry_deleted", "already_closed"])
            )
        state = run_fold.fold(RUN, timer, events, frozen=frozen)
        check_sums(state, timer)
        stopped += state.status == "stopped"
        reopened += any(x.type == "reopen" and state.effects[x.id].effect == "applied" for x in events)
        removed += any(x.type == "remove" and state.effects[x.id].effect == "applied" for x in events)
        for _ in range(6):
            again = run_fold.fold(RUN, timer, reorder(rng, events, frozen), frozen=frozen)
            assert again == state
    assert stopped > 400  # the generator reaches stopped runs often
    assert reopened > 300  # and applied reopens
    assert removed > 300  # and applied removes


@pytest.mark.parametrize("timer", TIMERS, ids=lambda t: f"{len(t.steps)}s{len(t.laps)}l")
def test_a_fold_is_pure(timer: Timer) -> None:
    rng = random.Random(7)
    _, events = random_run(rng)
    assert run_fold.fold(RUN, timer, events) == run_fold.fold(RUN, timer, events)
