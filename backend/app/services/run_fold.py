"""The run fold: a run's events in, its state and timing out.

Pure functions (no DB, no clock), mirrored by the PWA (``lib/runs/fold.ts``) and the iOS app
(QuickrCore ``RunFold``): ``shared/fixtures/run-fold-vectors.json`` (generated from this
module) is the contract all three check. The rules are docs/specs/timers.md §4 (the fold),
§2.3 (the ``Timing`` projection and its invariants T1 to T5) and §11.1 (the duration format).

Every instant is an integer count of milliseconds since the Unix epoch, so every duration is
an exact integer difference and segment sums equal the totals exactly (§2.3). Wire strings
are truncated to the millisecond by :func:`parse_instant`, never rounded, and never go
through a float.

- :func:`fold` replays a run's events (in server arrival order) into a :class:`RunState`:
  terminal events by arrival, everything else by ``(at, id)`` (§4.1, §4.2).
- :func:`project_timing` turns a stopped run's state into the entry's :class:`Timing`, and
  :func:`make_timing` builds one from segment boundaries and pauses (a fold, or an edit).
  :func:`check_timing` enforces T1 to T5.
- :func:`fmt_duration` is the ``m:ss`` / ``h:mm:ss`` duration format of every client.

Decided outside the fold, by the server (§3.6, §3.7, §4.4): ``finish`` (it gets no effect
here), the discard of a finishing run, ``finishing`` versus ``stopped`` (the fold says
``stopped``), and the void reasons ``run_edited``, ``entry_deleted`` and ``already_closed``
for events that arrive once the run is edited, its entry deleted or the run discarded. The
server passes that cut-off as ``frozen``: later arrivals are void and the run isn't refolded
past it.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

type EventType = Literal["start", "next", "lap", "skip", "pause", "resume", "stop", "finish", "discard"]
type VoidReason = Literal[
    "merged",
    "already_closed",
    "run_edited",
    "entry_deleted",
    "before_start",
    "after_stop",
    "too_long",
    "stale",
    "no_step",
    "already_paused",
    "not_paused",
]
type FrozenReason = Literal["run_edited", "entry_deleted", "already_closed"]
type Status = Literal["running", "paused", "stopped", "discarded"]
type SegmentKind = Literal["step", "lap"]

EVENT_TYPES: frozenset[str] = frozenset(
    {"start", "next", "lap", "skip", "pause", "resume", "stop", "finish", "discard"}
)
MAX_RUN_MS = 7 * 24 * 60 * 60 * 1000  # §5: at most 7 days from started_at
_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)
_MS = timedelta(milliseconds=1)


# --- instants ---------------------------------------------------------------------------


def to_ms(at: datetime) -> int:
    """An aware datetime as epoch milliseconds, truncated (sub-millisecond digits dropped)."""
    if at.tzinfo is None:
        raise ValueError("naive datetime")
    return (at - _EPOCH) // _MS


def parse_instant(text: str) -> int:
    """A wire date-time (sync-protocol.md §1.5) as epoch milliseconds, truncated."""
    return to_ms(datetime.fromisoformat(text))


def from_ms(ms: int) -> datetime:
    return _EPOCH + ms * _MS


def format_instant(ms: int) -> str:
    """Epoch milliseconds as the server writes an instant: UTC, ``Z``, and six fraction
    digits only when the millisecond part isn't zero (pydantic's form)."""
    at = from_ms(ms)
    head = at.strftime("%Y-%m-%dT%H:%M:%S")
    return f"{head}.{at.microsecond:06d}Z" if at.microsecond else f"{head}Z"


# --- inputs and outputs -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Step:
    key: str
    label: str


@dataclass(frozen=True, slots=True)
class Event:
    """One stored tap. ``at`` is epoch milliseconds; ``seg`` is set for next, lap and skip,
    ``step`` for skip, ``pause_id`` for resume (§3.2)."""

    id: str
    type: EventType
    at: int
    seg: int | None = None
    step: str | None = None
    pause_id: str | None = None


@dataclass(frozen=True, slots=True)
class Frozen:
    """Events from arrival index ``after`` on are void with ``reason`` and not folded."""

    after: int
    reason: FrozenReason


@dataclass(frozen=True, slots=True)
class Effect:
    effect: Literal["applied", "void"]
    reason: VoidReason | None = None


APPLIED = Effect("applied")


@dataclass(frozen=True, slots=True)
class Pause:
    start: int
    end: int


@dataclass(frozen=True, slots=True)
class Segment:
    kind: SegmentKind
    step: str | None
    label: str
    started_at: int
    ended_at: int
    active_ms: int
    paused_ms: int


@dataclass(frozen=True, slots=True)
class OpenSegment:
    index: int
    kind: SegmentKind
    step: str | None
    label: str
    started_at: int


@dataclass(frozen=True, slots=True)
class RunState:
    """The fold's output (§4.3), plus the run's start and (when stopped) end.

    ``segments``, ``skipped`` and ``pauses`` are the closed ones; an open pause is
    ``paused_since``. ``effects`` maps each event id (lowercase) to its effect; ``finish``
    events are left out (the server decides them).
    """

    status: Status
    started_at: int
    ended_at: int | None
    open: OpenSegment | None
    next_step: str | None
    paused_since: int | None
    segments: tuple[Segment, ...]
    skipped: tuple[str, ...]
    pauses: tuple[Pause, ...]
    effects: Mapping[str, Effect]


@dataclass(frozen=True, slots=True)
class Timing:
    """``entries.timing`` (§2.3)."""

    started_at: int
    ended_at: int
    active_ms: int
    paused_ms: int
    complete: bool
    edited: bool
    segments: tuple[Segment, ...]
    skipped: tuple[str, ...]
    pauses: tuple[Pause, ...]


# --- the fold ---------------------------------------------------------------------------


def lap_label(n: int) -> str:
    """The label of the run's ``n``-th lap segment (1-based)."""
    return f"Lap {n}"


def fold(
    run_id: str, steps: Sequence[Step], events: Sequence[Event], *, frozen: Frozen | None = None
) -> RunState:
    """Replay ``events`` (in arrival order) of run ``run_id`` over its version's ``steps``.

    The run's own start (the event whose id is ``run_id``) must be among them. A stop
    before the start or more than 7 days after it is void (``before_start``,
    ``too_long``) and doesn't close the run: the server refuses such a stop and never
    stores it (§3.5, §5), so only a client's queued one can reach the fold.
    """
    run_id = run_id.lower()
    start = next((e for e in events if e.id.lower() == run_id and e.type == "start"), None)
    if start is None:
        raise ValueError("the run's start event is missing")
    effects: dict[str, Effect] = {}
    terminal, accepted = _arrival_pass(run_id, start, events, frozen, effects)

    clock = _Clock(steps, start.at)
    end = terminal.at if terminal is not None else None
    for e in sorted(accepted, key=_time_order(accepted)):
        if e.at < start.at:
            reason: VoidReason | None = "before_start"
        elif end is not None and e.at > end:
            reason = "after_stop"
        elif e.at > start.at + MAX_RUN_MS:
            reason = "too_long"
        else:
            reason = clock.apply(e)
        effects[e.id.lower()] = APPLIED if reason is None else Effect("void", reason)

    return clock.state(start.at, terminal, effects)


def _time_order(accepted: Sequence[Event]) -> Callable[[Event], tuple[int, str, int, str]]:
    """Pass 2's order: ``(at, id)`` ascending, ids lowercase, except that a resume at the same
    instant as the pause it names comes right after that pause."""
    pauses = {e.id.lower(): e.at for e in accepted if e.type == "pause"}

    def key(e: Event) -> tuple[int, str, int, str]:
        named = (e.pause_id or "").lower()
        if e.type == "resume" and pauses.get(named) == e.at:
            return (e.at, named, 1, e.id.lower())
        return (e.at, e.id.lower(), 0, "")

    return key


def _arrival_pass(
    run_id: str, start: Event, events: Sequence[Event], frozen: Frozen | None, effects: dict[str, Effect]
) -> tuple[Event | None, list[Event]]:
    """Pass 1, arrival order (§4.2): duplicates, starts, terminals and the frozen cut-off.
    Records their effects; returns the terminal and the events left for pass 2."""
    seen: set[str] = set()
    terminal: Event | None = None
    accepted: list[Event] = []
    for i, e in enumerate(events):
        if e.type not in EVENT_TYPES:
            raise ValueError(f"unknown event type {e.type!r}")
        eid = e.id.lower()
        if eid in seen:
            continue
        seen.add(eid)
        if e.type == "finish":
            continue
        reason: VoidReason | None = None
        if frozen is not None and i >= frozen.after:
            reason = frozen.reason
        elif e.type == "start":
            reason = None if eid == run_id else "merged"
        elif e.type in ("stop", "discard"):
            # An out-of-range stop is never a terminal, whenever it arrives (the server refuses it).
            if e.type == "stop" and e.at < start.at:
                reason = "before_start"
            elif e.type == "stop" and e.at > start.at + MAX_RUN_MS:
                reason = "too_long"
            elif terminal is not None:
                reason = "already_closed"
            else:
                terminal = e
        else:
            accepted.append(e)
            continue
        effects[eid] = APPLIED if reason is None else Effect("void", reason)
    return terminal, accepted


class _Clock:
    """Pass 2's state: the open segment, the steps still to come, and what has closed."""

    def __init__(self, steps: Sequence[Step], started_at: int) -> None:
        self.pending: deque[Step] = deque(steps)
        self.open_step: Step | None = self.pending.popleft() if self.pending else None  # None: a lap
        self.open_start = started_at
        self.closed: list[tuple[Step | None, int, int]] = []  # (step or lap, started_at, ended_at)
        self.skipped: list[str] = []
        self.pauses: list[Pause] = []
        self.paused_since: int | None = None
        self.pause_id: str | None = None

    def pop(self) -> Step | None:
        """The next step, or a lap once the steps run out."""
        return self.pending.popleft() if self.pending else None

    def close(self, at: int, then: Step | None) -> None:
        self.closed.append((self.open_step, self.open_start, at))
        self.open_step, self.open_start = then, at

    def apply(self, e: Event) -> VoidReason | None:
        """Apply one in-range event; its void reason, or None when it applied."""
        if e.type in ("next", "lap", "skip") and e.seg != len(self.closed):
            return "stale"
        match e.type:
            case "next":
                self.close(e.at, self.pop())
            case "lap":
                self.close(e.at, None)
            case "skip":
                return self.skip(e.step)
            case "pause":
                if self.paused_since is not None:
                    return "already_paused"
                self.paused_since, self.pause_id = e.at, e.id.lower()
            case "resume":
                if self.paused_since is None:
                    return "not_paused"
                if (e.pause_id or "").lower() != self.pause_id:
                    return "stale"  # it ends an older pause
                self.pauses.append(Pause(self.paused_since, e.at))
                self.paused_since = self.pause_id = None
            case _:  # start, stop, discard and finish never reach pass 2
                raise AssertionError(e.type)
        return None

    def skip(self, step: str | None) -> VoidReason | None:
        if self.open_step is not None:
            if step != self.open_step.key:
                return "stale"
            self.skipped.append(self.open_step.key)
            self.open_step = self.pop()  # relabel the open segment: no time moves
            return None
        if not self.pending:
            return "no_step"
        if step != self.pending[0].key:
            return "stale"
        self.skipped.append(self.pending.popleft().key)
        return None

    def state(self, started_at: int, terminal: Event | None, effects: Mapping[str, Effect]) -> RunState:
        status: Status
        ended_at: int | None = None
        if terminal is not None and terminal.type == "stop":
            if self.paused_since is not None:  # stop while paused ends the pause
                self.pauses.append(Pause(self.paused_since, terminal.at))
                self.paused_since = None
            self.close(terminal.at, None)
            status, ended_at = "stopped", terminal.at
        elif terminal is not None:
            status, self.paused_since = "discarded", None
        else:
            status = "paused" if self.paused_since is not None else "running"

        segments = _segments(self.closed, self.pauses, open_pause=self.paused_since)
        open_seg: OpenSegment | None = None
        if status in ("running", "paused"):
            laps = sum(s.kind == "lap" for s in segments)
            step = self.open_step
            open_seg = OpenSegment(
                index=len(self.closed),
                kind="lap" if step is None else "step",
                step=None if step is None else step.key,
                label=lap_label(laps + 1) if step is None else step.label,
                started_at=self.open_start,
            )
        return RunState(
            status=status,
            started_at=started_at,
            ended_at=ended_at,
            open=open_seg,
            next_step=self.pending[0].key if open_seg is not None and self.pending else None,
            paused_since=self.paused_since,
            segments=tuple(segments),
            skipped=tuple(self.skipped),
            pauses=tuple(self.pauses),
            effects=dict(effects),
        )


def _overlap(start: int, end: int, pauses: Sequence[Pause], open_pause: int | None = None) -> int:
    """How much of ``[start, end)`` the pauses cover; ``open_pause`` is the start of a pause
    not resumed yet, which covers up to ``end``."""
    paused = sum(max(0, min(end, p.end) - max(start, p.start)) for p in pauses)
    return paused if open_pause is None else paused + max(0, end - max(start, open_pause))


def _segments(
    closed: Sequence[tuple[Step | None, int, int]], pauses: Sequence[Pause], *, open_pause: int | None = None
) -> list[Segment]:
    """Closed segments with their labels. Pauses stay whole; each segment's paused_ms is its
    overlap with them (T5)."""
    out: list[Segment] = []
    laps = 0
    for step, started_at, ended_at in closed:
        if step is None:
            laps += 1
        paused = _overlap(started_at, ended_at, pauses, open_pause)
        out.append(
            Segment(
                kind="lap" if step is None else "step",
                step=None if step is None else step.key,
                label=lap_label(laps) if step is None else step.label,
                started_at=started_at,
                ended_at=ended_at,
                active_ms=ended_at - started_at - paused,
                paused_ms=paused,
            )
        )
    return out


# --- timing -----------------------------------------------------------------------------


def make_timing(
    started_at: int,
    parts: Sequence[tuple[Step | None, int]],
    skipped: Sequence[str],
    pauses: Sequence[Pause],
    *,
    steps: Sequence[Step],
    edited: bool = False,
) -> Timing:
    """A ``Timing`` from its boundaries: ``parts`` is each segment's step (None for a lap)
    and end, in order; the last end is the run's end. ``steps`` are the run version's steps,
    for ``complete`` (:func:`is_complete`)."""
    if not parts:
        raise ValueError("a timing has at least one segment")
    closed: list[tuple[Step | None, int, int]] = []
    previous = started_at
    for step, ended_at in parts:
        closed.append((step, previous, ended_at))
        previous = ended_at
    segments = _segments(closed, pauses)
    paused = sum(p.end - p.start for p in pauses)
    return Timing(
        started_at=started_at,
        ended_at=previous,
        active_ms=previous - started_at - paused,
        paused_ms=paused,
        complete=is_complete(steps, segments, skipped),
        edited=edited,
        segments=tuple(segments),
        skipped=tuple(skipped),
        pauses=tuple(pauses),
    )


def is_complete(steps: Sequence[Step], segments: Sequence[Segment], skipped: Sequence[str]) -> bool:
    """§9.1: the version has no steps, or every one of its steps has a segment and none was
    skipped. A run stopped before it reached its last step is not complete."""
    done = {s.step for s in segments}
    return not skipped and all(step.key in done for step in steps)


def project_timing(state: RunState, steps: Sequence[Step]) -> Timing:
    """A stopped run's ``Timing``: exactly its fold state (§4.3). ``steps`` are the run
    version's steps, the ones it was folded over."""
    if state.status != "stopped" or state.ended_at is None:
        raise ValueError("only a stopped run has a timing")
    paused = sum(p.end - p.start for p in state.pauses)
    return Timing(
        started_at=state.started_at,
        ended_at=state.ended_at,
        active_ms=state.ended_at - state.started_at - paused,
        paused_ms=paused,
        complete=is_complete(steps, state.segments, state.skipped),
        edited=False,
        segments=state.segments,
        skipped=state.skipped,
        pauses=state.pauses,
    )


class TimingError(ValueError):
    def __init__(self, invariant: str, message: str) -> None:
        super().__init__(f"{invariant}: {message}")
        self.invariant = invariant


def check_timing(t: Timing, *, captured_at: int | None = None) -> None:
    """Raise :class:`TimingError` unless ``t`` satisfies T1 (when ``captured_at`` is given)
    to T5 (§2.3)."""
    if captured_at is not None and captured_at != t.ended_at:
        raise TimingError("T1", "captured_at must equal timing.ended_at")
    if not t.segments:
        raise TimingError("T2", "a timing has at least one segment")
    previous = t.started_at
    for i, s in enumerate(t.segments):
        if s.started_at != previous:
            raise TimingError("T2", f"segment {i} must start where the previous one ended")
        if s.ended_at < s.started_at:
            raise TimingError("T2", f"segment {i} has a negative length")
        if (s.kind == "step") != (s.step is not None):
            raise TimingError("T2", f"segment {i}: a step segment names its step, a lap doesn't")
        previous = s.ended_at
    if previous != t.ended_at:
        raise TimingError("T2", "the last segment must end at ended_at")
    previous = t.started_at
    for i, p in enumerate(t.pauses):
        if p.start < previous or p.end < p.start or p.end > t.ended_at:
            raise TimingError("T3", f"pause {i} is out of order, overlaps, or lies outside the run")
        previous = p.end
    keys = [s.step for s in t.segments if s.step is not None] + list(t.skipped)
    if len(keys) != len(set(keys)):
        raise TimingError("T4", "a step key appears more than once")
    for i, s in enumerate(t.segments):
        if s.paused_ms != _overlap(s.started_at, s.ended_at, t.pauses):
            raise TimingError("T5", f"segment {i}: paused_ms must be its overlap with the pauses")
        if s.active_ms + s.paused_ms != s.ended_at - s.started_at:
            raise TimingError("T5", f"segment {i}: active_ms + paused_ms must be its length")
    if t.paused_ms != sum(p.end - p.start for p in t.pauses) or t.paused_ms != sum(
        s.paused_ms for s in t.segments
    ):
        raise TimingError("T5", "paused_ms must add up over pauses and segments")
    if t.active_ms != t.ended_at - t.started_at - t.paused_ms or t.active_ms != sum(
        s.active_ms for s in t.segments
    ):
        raise TimingError("T5", "active_ms must add up over segments")


# --- JSON -------------------------------------------------------------------------------


def segment_json(s: Segment) -> dict[str, Any]:
    return {
        "kind": s.kind,
        "step": s.step,
        "label": s.label,
        "started_at": format_instant(s.started_at),
        "ended_at": format_instant(s.ended_at),
        "active_ms": s.active_ms,
        "paused_ms": s.paused_ms,
    }


def pause_json(p: Pause) -> dict[str, Any]:
    return {"start": format_instant(p.start), "end": format_instant(p.end)}


def state_json(state: RunState) -> dict[str, Any]:
    """``RunState`` as the API carries it (§4.3), plus ``started_at`` and ``ended_at``."""
    o = state.open
    return {
        "status": state.status,
        "started_at": format_instant(state.started_at),
        "ended_at": None if state.ended_at is None else format_instant(state.ended_at),
        "open": None
        if o is None
        else {
            "index": o.index,
            "kind": o.kind,
            "step": o.step,
            "label": o.label,
            "started_at": format_instant(o.started_at),
        },
        "next_step": state.next_step,
        "paused_since": None if state.paused_since is None else format_instant(state.paused_since),
        "segments": [segment_json(s) for s in state.segments],
        "skipped": list(state.skipped),
        "pauses": [pause_json(p) for p in state.pauses],
        "effects": {k: {"effect": v.effect, "reason": v.reason} for k, v in state.effects.items()},
    }


def timing_json(t: Timing) -> dict[str, Any]:
    return {
        "started_at": format_instant(t.started_at),
        "ended_at": format_instant(t.ended_at),
        "active_ms": t.active_ms,
        "paused_ms": t.paused_ms,
        "complete": t.complete,
        "edited": t.edited,
        "segments": [segment_json(s) for s in t.segments],
        "skipped": list(t.skipped),
        "pauses": [pause_json(p) for p in t.pauses],
    }


def timing_from_json(d: Mapping[str, Any]) -> Timing:
    return Timing(
        started_at=parse_instant(d["started_at"]),
        ended_at=parse_instant(d["ended_at"]),
        active_ms=d["active_ms"],
        paused_ms=d["paused_ms"],
        complete=d["complete"],
        edited=d["edited"],
        segments=tuple(
            Segment(
                kind=s["kind"],
                step=s["step"],
                label=s["label"],
                started_at=parse_instant(s["started_at"]),
                ended_at=parse_instant(s["ended_at"]),
                active_ms=s["active_ms"],
                paused_ms=s["paused_ms"],
            )
            for s in d["segments"]
        ),
        skipped=tuple(d["skipped"]),
        pauses=tuple(Pause(parse_instant(p["start"]), parse_instant(p["end"])) for p in d["pauses"]),
    )


# --- display ----------------------------------------------------------------------------


def fmt_duration(ms: int) -> str:
    """``m:ss`` below one hour, ``h:mm:ss`` from one hour; truncated to whole seconds;
    negative input reads ``0:00`` (§11.1)."""
    seconds = max(0, ms) // 1000
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"
