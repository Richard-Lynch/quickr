"""The vector case lists of docs/specs/timers2.md, read from the spec itself.

timers2.md §12.1 names every case ``run-fold-vectors.json`` v4 must carry, and §7.4 the new
cases of ``timing-stats-vectors.json`` v3. The generators' coverage tests read the names here
instead of repeating them (M1-plan.md, M1-FOLD), so a case the spec adds or renames fails the
drift check until the generator follows.
"""

from __future__ import annotations

import re
from pathlib import Path

SPEC = Path(__file__).resolve().parents[2] / "docs" / "specs" / "timers2.md"
_TICKED = re.compile(r"`([^`]+)`")


def _spec() -> str:
    return SPEC.read_text()


def run_fold_v4_cases() -> list[str]:
    """§12.1: the backticked vector names in the ``run-fold-vectors.json`` row (hyphenated
    names only: field names and void reasons in the same cell use underscores)."""
    row = next(line for line in _spec().splitlines() if line.startswith("| `run-fold-vectors.json`"))
    cells = row.split("|")
    names = [t for t in _TICKED.findall(cells[3]) if "-" in t and "_" not in t and "." not in t]
    assert len(names) == len(set(names)), "a case is named twice in §12.1"
    return names


def timing_stats_v3_cases() -> list[str]:
    """§7.4: the ``lap_types_*`` cases named after ``GENERATOR_VERSION 2 → 3``."""
    text = _spec()
    start = text.index("`timing-stats-vectors.json` `GENERATOR_VERSION 2 → 3`")
    tail = text[start : text.index("\n\n", start)]
    names = [t for t in _TICKED.findall(tail) if t.startswith("lap_types_")]
    assert len(names) == len(set(names))
    return names
