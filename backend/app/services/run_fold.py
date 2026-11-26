"""The run fold: a run's events in, its state and timing out.

Pure functions (no DB, no clock), mirrored by the PWA (``lib/runs/fold.ts``) and the iOS app
(QuickrCore ``RunFold``): ``shared/fixtures/run-fold-vectors.json`` (generated from this
module) is the contract all three check. The rules are docs/specs/timers.md §4 (the fold)
as changed by docs/specs/timers2.md §3 (fold v4: the version's ``timer`` with its lap types,
``reopen`` and ``remove``, the gap pause, ghost boundaries), timers.md §2.3 (the ``Timing``
projection and its invariants T1 to T5) and §11.1 (the duration format).

Every instant is an integer count of milliseconds since the Unix epoch, so every duration is
an exact integer difference and segment sums equal the totals exactly (§2.3). Wire strings
are truncated to the millisecond by :func:`parse_instant`, never rounded, and never go
through a float.

- :func:`fold` replays a run's events (in server arrival order) into a :class:`RunState`:
  terminals, reopens and removes by arrival (pass 1), everything else by time (pass 2) with
  the reopened stops and their reopens taking part as gap pause and gap resume roles
  (timers2.md §3.4). Effects are outputs of one fold only: nothing is retained between folds.
- :func:`project_timing` turns a stopped run's state into the entry's :class:`Timing`, and
  :func:`make_timing` builds one from segment boundaries and pauses (an edit).
  :func:`check_timing` enforces T1 to T5.
- :func:`fmt_duration` is the ``m:ss`` / ``h:mm:ss`` duration format of every client.

Decided outside the fold, by the server (timers.md §3.6, §3.7, §4.4; timers2.md §3.6):
``finish`` (it gets no effect here), the discard of a finishing run, ``finishing`` versus
``stopped`` (the fold says ``stopped``), and the void reasons ``run_edited``,
``entry_deleted`` and ``already_closed`` for events that arrive once the run is edited, its
entry deleted or the run discarded. The server passes that cut-off as ``frozen``: later
arrivals are void and the run isn't refolded past it.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

type EventType = Literal[
    "start", "next", "lap", "skip", "pause", "resume", "stop", "finish", "discard", "reopen", "remove"
]
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
    "reverted",
    "not_stopped",
    "deleted",
    "no_target",
]
type FrozenReason = Literal["run_edited", "entry_deleted", "already_closed"]
type Status = Literal["running", "paused", "stopped", "discarded"]
type SegmentKind = Literal["step", "lap"]
type OpenedBy = Literal["start", "next", "lap", "skip"]

EVENT_TYPES: frozenset[str] = frozenset(
    {"start", "next", "lap", "skip", "pause", "resume", "stop", "finish", "discard", "reopen", "remove"}
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
class LapType:
    key: str
    label: str


@dataclass(frozen=True, slots=True)
class Timer:
    """What the fold needs of a version's timer (timers2.md §3.1): its steps and lap types.
    Variables and alerts are not fold inputs."""

    steps: Sequence[Step] = ()
    laps: Sequence[LapType] = ()

    def __post_init__(self) -> None:  # stored as tuples: hashable, and equal whatever was passed
        object.__setattr__(self, "steps", tuple(self.steps))
        object.__setattr__(self, "laps", tuple(self.laps))


@dataclass(frozen=True, slots=True)
class Event:
    """One stored tap. ``at`` is epoch milliseconds; ``seg`` is set for next, lap and skip,
    ``step`` for skip, ``pause_id`` for resume (§3.2), ``target`` for reopen and remove
    (timers2.md §3)."""

    id: str
    type: EventType
    at: int
    seg: int | None = None
    step: str | None = None
    pause_id: str | None = None
    target: str | None = None


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
    """``id`` is the ``pause`` event's id (a gap pause carries its stop's id); None on a
    pre-v2 stored timing and after an edit (timers2.md §3.3)."""

    start: int
    end: int
    id: str | None = None


@dataclass(frozen=True, slots=True)
class Segment:
    """``event_id`` and ``opened_by`` name the event that opened the segment: the start
    (``event_id`` None, ``opened_by`` "start"), a next or a lap. Both None on a pre-v2 stored
    timing and after an edit; ``skip`` never opens a segment and is reserved."""

    kind: SegmentKind
    step: str | None
    label: str
    started_at: int
    ended_at: int
    active_ms: int
    paused_ms: int
    lap_type: str | None = None
    event_id: str | None = None
    opened_by: OpenedBy | None = None


@dataclass(frozen=True, slots=True)
class OpenSegment:
    index: int
    kind: SegmentKind
    step: str | None
    label: str
    started_at: int
    lap_type: str | None = None


@dataclass(frozen=True, slots=True)
class RunState:
    """The fold's output (§4.3, timers2.md §3.3), plus the run's start and (when stopped) end.

    ``segments``, ``skipped`` and ``pauses`` are the closed ones; an open pause is
    ``paused_since``. ``effects`` maps each event id (lowercase) to its effect; ``finish``
    events are left out (the server decides them). ``terminal_id`` is the applied stop that
    closed the run: None while open, after a reopen, and for a discarded run.
    ``next_lap_type`` is the type of the lap a ``lap`` tap would open now (None when untyped
    or the run isn't open); ``lap_count`` the closed lap segments.
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
    terminal_id: str | None
    next_lap_type: str | None
    lap_count: int


@dataclass(frozen=True, slots=True)
class Timing:
    """``entries.timing`` (§2.3). ``terminal_id`` is the applied stop; None on a pre-v2 stored
    timing (an edit keeps it)."""

    started_at: int
    ended_at: int
    active_ms: int
    paused_ms: int
    complete: bool
    edited: bool
    segments: tuple[Segment, ...]
    skipped: tuple[str, ...]
    pauses: tuple[Pause, ...]
    terminal_id: str | None = None


# --- the fold ---------------------------------------------------------------------------


def lap_typing(n: int, laps: Sequence[LapType]) -> tuple[str | None, str]:
    """The lap type key and label of the run's ``n``-th lap segment (1-based): laps cycle
    through the lap types in order with a per-type ordinal (timers2.md §3.2); with no lap
    types, ``(None, "Lap n")``."""
    if not laps:
        return None, f"Lap {n}"
    lap_type = laps[(n - 1) % len(laps)]
    return lap_type.key, f"{lap_type.label} {(n - 1) // len(laps) + 1}"


def lap_label(n: int, laps: Sequence[LapType] = ()) -> str:
    return lap_typing(n, laps)[1]


def fold(run_id: str, timer: Timer, events: Sequence[Event], *, frozen: Frozen | None = None) -> RunState:
    """Replay ``events`` (in arrival order) of run ``run_id`` over its version's ``timer``.

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
    arrival = _arrival_pass(run_id, start, events, frozen, effects)
    terminal = arrival.terminal

    clock = _Clock(timer, start.at, arrival.removed)
    end = terminal.at if terminal is not None else None
    items: list[Event | _Role] = [*arrival.accepted, *arrival.gaps()]
    for item in sorted(items, key=_time_order(arrival.accepted)):
        if isinstance(item, _Role):  # never recorded; skipped outside the run
            if item.at >= start.at and (end is None or item.at <= end):
                clock.role(item)
            continue
        if item.at < start.at:
            reason: VoidReason | None = "before_start"
        elif end is not None and item.at > end:
            reason = "after_stop"
        elif item.at > start.at + MAX_RUN_MS:
            reason = "too_long"
        else:
            reason = clock.apply(item)
        effects[item.id.lower()] = APPLIED if reason is None else Effect("void", reason)

    return clock.state(start.at, terminal, effects)


@dataclass(frozen=True, slots=True)
class _Role:
    """A reopened stop's gap pause (id = the stop's) or a reopen's gap resume (id = the
    reopen's) in pass 2 (timers2.md §3.4)."""

    kind: Literal["gap_pause", "gap_resume"]
    at: int
    id: str


class _Arrival:
    """Pass 1's state and outcome (§4.2, timers2.md §3.4): the terminal, the events left for
    pass 2, every applied (stop, reopen) role pair and the removed targets."""

    def __init__(self, run_id: str, start: Event, effects: dict[str, Effect]) -> None:
        self.run_id = run_id
        self.start = start
        self.effects = effects
        self.seen: dict[str, Event] = {}  # the first occurrence of each id
        self.terminal: Event | None = None
        self.accepted: list[Event] = []
        self.open_reopen: tuple[Event, Event] | None = (
            None  # the (stop, reopen) that cleared the CURRENT terminal
        )
        self.roles: list[tuple[Event, Event]] = []
        self.removed: dict[str, Event] = {}  # target id (lowercase) -> the remove that applied

    def gaps(self) -> list[_Role]:
        return [
            _Role("gap_pause", s.at, s.id.lower()) for s, _ in self.roles if s.id.lower() not in self.removed
        ] + [_Role("gap_resume", r.at, r.id.lower()) for _, r in self.roles]

    def stop(self, e: Event) -> VoidReason | None:
        # An out-of-range stop is never a terminal, whenever it arrives (the server refuses it).
        if e.at < self.start.at:
            return "before_start"
        if e.at > self.start.at + MAX_RUN_MS:
            return "too_long"
        if self.terminal is not None:
            return "already_closed"
        self.terminal, self.open_reopen = e, None  # a new terminal ends the reopen transaction
        return None

    def discard(self, e: Event) -> VoidReason | None:
        if self.terminal is not None:
            return "already_closed"
        if self.open_reopen is None:
            self.terminal = e
            return None
        stop, reopen = self.open_reopen  # the terminal was cleared by a reopen: revert (OQ-2)
        self.open_reopen = None
        self.effects[reopen.id.lower()] = Effect("void", "reverted")
        self.terminal = stop
        self.roles.remove((stop, reopen))
        if stop.id.lower() in self.removed:  # the gap pause had been removed: a terminal again
            self.effects[stop.id.lower()] = APPLIED
            self.effects[self.removed.pop(stop.id.lower()).id.lower()] = Effect("void", "no_target")
        return None  # the discard closed what the reopen opened

    def reopen(self, e: Event) -> VoidReason | None:
        target = (e.target or "").lower()
        t = self.seen.get(target)
        if t is None or t.type != "stop":
            return "no_target"
        if self.terminal is not None and self.terminal.type == "discard":
            return "already_closed"
        if self.terminal is None or self.terminal.id.lower() != target:
            return "not_stopped"  # not the current terminal
        if e.at <= t.at:
            return "stale"
        if e.at > self.start.at + MAX_RUN_MS:
            return "too_long"
        self.open_reopen = (t, e)
        self.roles.append((t, e))
        self.terminal = None
        return None

    def remove(self, e: Event) -> VoidReason | None:
        """Eligibility is by type and identity only: a pause, a lap, or a reopened stop, not yet
        removed, with ``e.at`` after it; there is no 7-day bound."""
        target = (e.target or "").lower()
        t = self.seen.get(target)
        if t is None or target in self.removed or e.at <= t.at:
            return "no_target"
        if t.type == "stop":
            if not any(s.id.lower() == target for s, _ in self.roles):
                return "no_target"
            self.effects[target] = Effect("void", "deleted")  # the gap pause goes; its reopen stays applied
        elif t.type not in ("pause", "lap"):
            return "no_target"
        self.removed[target] = e
        return None


def _arrival_pass(
    run_id: str, start: Event, events: Sequence[Event], frozen: Frozen | None, effects: dict[str, Effect]
) -> _Arrival:
    """Pass 1, arrival order: duplicates, starts, the frozen cut-off, terminals, reopens (and
    their revert by a discard) and removes. Records their effects."""
    st = _Arrival(run_id, start, effects)
    for i, e in enumerate(events):
        if e.type not in EVENT_TYPES:
            raise ValueError(f"unknown event type {e.type!r}")
        eid = e.id.lower()
        if eid in st.seen:
            continue
        st.seen[eid] = e
        if e.type == "finish":
            continue
        reason: VoidReason | None
        if frozen is not None and i >= frozen.after:
            reason = frozen.reason
        elif e.type == "start":
            reason = None if eid == run_id else "merged"
        elif e.type == "stop":
            reason = st.stop(e)
        elif e.type == "discard":
            reason = st.discard(e)
        elif e.type == "reopen":
            reason = st.reopen(e)
        elif e.type == "remove":
            reason = st.remove(e)
        else:
            st.accepted.append(e)  # next, lap, skip, pause, resume
            continue
        effects[eid] = APPLIED if reason is None else Effect("void", reason)
    return st


def _time_order(accepted: Sequence[Event]) -> Callable[[Event | _Role], tuple[int, int, str, int, str]]:
    """Pass 2's order ``(at, rank, id)``: at equal ``at`` a gap pause (rank 0) comes before
    every user event (rank 1) and a gap resume (rank 2) after them; user events by lowercase
    id, except that a resume at the same instant as the pause it names comes right after that
    pause (several such resumes by lowercase id)."""
    pauses = {e.id.lower(): e.at for e in accepted if e.type == "pause"}

    def key(x: Event | _Role) -> tuple[int, int, str, int, str]:
        if isinstance(x, _Role):
            return (x.at, 0 if x.kind == "gap_pause" else 2, x.id, 0, "")
        named = (x.pause_id or "").lower()
        if x.type == "resume" and pauses.get(named) == x.at:
            return (x.at, 1, named, 1, x.id.lower())
        return (x.at, 1, x.id.lower(), 0, "")

    return key


@dataclass(frozen=True, slots=True)
class _Closed:
    step: Step | None  # None: a lap
    started_at: int
    ended_at: int
    event_id: str | None
    opened_by: OpenedBy | None


class _Clock:
    """Pass 2's state: the open segment, the steps still to come, what has closed, the open
    pause and its owner, and the ghost boundaries of removed laps."""

    def __init__(self, timer: Timer, started_at: int, removed: Mapping[str, Event]) -> None:
        self.timer = timer
        self.pending: deque[Step] = deque(timer.steps)
        self.open_step: Step | None = self.pending.popleft() if self.pending else None  # None: a lap
        self.open_start = started_at
        self.open_event: tuple[str | None, OpenedBy | None] = (None, "start")
        self.closed: list[_Closed] = []
        self.skipped: list[str] = []
        self.pauses: list[Pause] = []
        self.paused_since: int | None = None
        self.pause_id: str | None = None
        self.removed = removed
        self.ghosts: list[tuple[int, int]] = []  # (lap.at, remove.at) of removed lap boundaries

    def pop(self) -> Step | None:
        """The next step, or a lap once the steps run out."""
        return self.pending.popleft() if self.pending else None

    def expected_seg(self, at: int) -> int:
        """§3.5: the closed segments plus the removed boundaries a device tapping at ``at``
        still saw (removed later than ``at``)."""
        return len(self.closed) + sum(1 for lap_at, removed_at in self.ghosts if lap_at < at < removed_at)

    def close(self, at: int, then: Step | None, event_id: str | None, opened_by: OpenedBy | None) -> None:
        self.closed.append(_Closed(self.open_step, self.open_start, at, *self.open_event))
        self.open_step, self.open_start, self.open_event = then, at, (event_id, opened_by)

    def end_pause(self, at: int) -> None:
        if self.paused_since is not None:
            self.pauses.append(Pause(self.paused_since, at, self.pause_id))
            self.paused_since = self.pause_id = None

    def role(self, role: _Role) -> None:
        """A gap pause or gap resume in range (timers2.md §3.4)."""
        if role.kind == "gap_pause":
            if self.paused_since is None:
                self.paused_since = role.at
            self.pause_id = role.id  # the gap OWNS the open pause: a user resume inside it is stale
        else:
            self.end_pause(role.at)  # ends WHATEVER pause is open

    def apply(self, e: Event) -> VoidReason | None:
        """Apply one in-range event; its void reason, or None when it applied."""
        eid = e.id.lower()
        if eid in self.removed:  # a deleted boundary or pause
            if e.type == "lap" and e.seg == self.expected_seg(e.at):
                self.ghosts.append((e.at, self.removed[eid].at))
            return "deleted"
        if e.type in ("next", "lap", "skip") and e.seg != self.expected_seg(e.at):
            return "stale"
        match e.type:
            case "next":
                self.close(e.at, self.pop(), eid, "next")
            case "lap":
                self.close(e.at, None, eid, "lap")
            case "skip":
                return self.skip(e.step)
            case "pause":
                if self.paused_since is not None:
                    return "already_paused"
                self.paused_since, self.pause_id = e.at, eid
            case "resume":
                named = (e.pause_id or "").lower()
                if named in self.removed:
                    return "deleted"
                if self.paused_since is None:
                    return "not_paused"
                if named != self.pause_id:
                    return "stale"  # it ends an older pause, or one the gap took over
                self.end_pause(e.at)
            case _:  # start, stop, discard, finish, reopen and remove never reach pass 2
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
        terminal_id: str | None = None
        if terminal is not None and terminal.type == "stop":
            self.end_pause(terminal.at)  # stop while paused ends the pause
            self.close(terminal.at, None, None, None)
            status, ended_at, terminal_id = "stopped", terminal.at, terminal.id.lower()
        elif terminal is not None:
            status, self.paused_since, self.pause_id = "discarded", None, None
        else:
            status = "paused" if self.paused_since is not None else "running"

        laps = self.timer.laps
        segments = _segments(self.closed, self.pauses, laps, open_pause=self.paused_since)
        lap_count = sum(s.kind == "lap" for s in segments)
        open_seg: OpenSegment | None = None
        next_lap_type: str | None = None
        if status in ("running", "paused"):
            step = self.open_step
            lap_type, label = lap_typing(lap_count + 1, laps) if step is None else (None, step.label)
            open_seg = OpenSegment(
                index=len(self.closed),
                kind="lap" if step is None else "step",
                step=None if step is None else step.key,
                label=label,
                started_at=self.open_start,
                lap_type=lap_type,
            )
            if laps:  # the lap a `lap` tap would open now
                next_lap_type = lap_typing(lap_count + (1 if step is None else 0) + 1, laps)[0]
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
            terminal_id=terminal_id,
            next_lap_type=next_lap_type,
            lap_count=lap_count,
        )


def _overlap(start: int, end: int, pauses: Sequence[Pause], open_pause: int | None = None) -> int:
    """How much of ``[start, end)`` the pauses cover; ``open_pause`` is the start of a pause
    not resumed yet, which covers up to ``end``."""
    paused = sum(max(0, min(end, p.end) - max(start, p.start)) for p in pauses)
    return paused if open_pause is None else paused + max(0, end - max(start, open_pause))


def _segments(
    closed: Sequence[_Closed],
    pauses: Sequence[Pause],
    laps: Sequence[LapType],
    *,
    open_pause: int | None = None,
) -> list[Segment]:
    """Closed segments with their labels and lap types (timers2.md §3.2). Pauses stay whole;
    each segment's paused_ms is its overlap with them (T5)."""
    out: list[Segment] = []
    lap_n = 0
    for c in closed:
        if c.step is None:
            lap_n += 1
            lap_type, label = lap_typing(lap_n, laps)
        else:
            lap_type, label = None, c.step.label
        paused = _overlap(c.started_at, c.ended_at, pauses, open_pause)
        out.append(
            Segment(
                kind="lap" if c.step is None else "step",
                step=None if c.step is None else c.step.key,
                label=label,
                started_at=c.started_at,
                ended_at=c.ended_at,
                active_ms=c.ended_at - c.started_at - paused,
                paused_ms=paused,
                lap_type=lap_type,
                event_id=c.event_id,
                opened_by=c.opened_by,
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
    timer: Timer,
    edited: bool = False,
    terminal_id: str | None = None,
) -> Timing:
    """A ``Timing`` from its boundaries: ``parts`` is each segment's step (None for a lap)
    and end, in order; the last end is the run's end. ``timer`` is the run version's: its
    steps for ``complete`` (:func:`is_complete`), its lap types for the laps' labels. A timing
    built this way is an edit's (timers2.md §3.3): its segments and pauses carry no event ids,
    and ``terminal_id`` is whatever the caller keeps."""
    if not parts:
        raise ValueError("a timing has at least one segment")
    closed: list[_Closed] = []
    previous = started_at
    for step, ended_at in parts:
        closed.append(_Closed(step, previous, ended_at, None, None))
        previous = ended_at
    plain = [Pause(p.start, p.end) for p in pauses]
    segments = _segments(closed, plain, timer.laps)
    paused = sum(p.end - p.start for p in plain)
    return Timing(
        started_at=started_at,
        ended_at=previous,
        active_ms=previous - started_at - paused,
        paused_ms=paused,
        complete=is_complete(timer.steps, segments, skipped),
        edited=edited,
        segments=tuple(segments),
        skipped=tuple(skipped),
        pauses=tuple(plain),
        terminal_id=terminal_id,
    )


def is_complete(steps: Sequence[Step], segments: Sequence[Segment], skipped: Sequence[str]) -> bool:
    """§9.1: the version has no steps, or every one of its steps has a segment and none was
    skipped. A run stopped before it reached its last step is not complete."""
    done = {s.step for s in segments}
    return not skipped and all(step.key in done for step in steps)


def project_timing(state: RunState, timer: Timer) -> Timing:
    """A stopped run's ``Timing``: exactly its fold state (§4.3). ``timer`` is the run
    version's, the one it was folded over."""
    if state.status != "stopped" or state.ended_at is None:
        raise ValueError("only a stopped run has a timing")
    paused = sum(p.end - p.start for p in state.pauses)
    return Timing(
        started_at=state.started_at,
        ended_at=state.ended_at,
        active_ms=state.ended_at - state.started_at - paused,
        paused_ms=paused,
        complete=is_complete(timer.steps, state.segments, state.skipped),
        edited=False,
        segments=state.segments,
        skipped=state.skipped,
        pauses=state.pauses,
        terminal_id=state.terminal_id,
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
        "lap_type": s.lap_type,
        "event_id": s.event_id,
        "opened_by": s.opened_by,
    }


def pause_json(p: Pause) -> dict[str, Any]:
    return {"start": format_instant(p.start), "end": format_instant(p.end), "id": p.id}


def state_json(state: RunState) -> dict[str, Any]:
    """``RunState`` as the API carries it (§4.3, timers2.md §3.3), plus ``started_at`` and
    ``ended_at``."""
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
            "lap_type": o.lap_type,
        },
        "next_step": state.next_step,
        "paused_since": None if state.paused_since is None else format_instant(state.paused_since),
        "segments": [segment_json(s) for s in state.segments],
        "skipped": list(state.skipped),
        "pauses": [pause_json(p) for p in state.pauses],
        "effects": {k: {"effect": v.effect, "reason": v.reason} for k, v in state.effects.items()},
        "terminal_id": state.terminal_id,
        "next_lap_type": state.next_lap_type,
        "lap_count": state.lap_count,
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
        "terminal_id": t.terminal_id,
    }


def timing_from_json(d: Mapping[str, Any]) -> Timing:
    """A stored timing. The v2 fields (``terminal_id``, ``lap_type``, ``event_id``,
    ``opened_by``, a pause's ``id``) are None when absent: a pre-v2 stored timing (§3.3)."""
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
                lap_type=s.get("lap_type"),
                event_id=s.get("event_id"),
                opened_by=s.get("opened_by"),
            )
            for s in d["segments"]
        ),
        skipped=tuple(d["skipped"]),
        pauses=tuple(
            Pause(parse_instant(p["start"]), parse_instant(p["end"]), p.get("id")) for p in d["pauses"]
        ),
        terminal_id=d.get("terminal_id"),
    )


# --- display ----------------------------------------------------------------------------


def fmt_duration(ms: int) -> str:
    """``m:ss`` below one hour, ``h:mm:ss`` from one hour; truncated to whole seconds;
    negative input reads ``0:00`` (§11.1)."""
    seconds = max(0, ms) // 1000
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"
