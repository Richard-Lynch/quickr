"""Writing and drift-checking the generated files under ``shared/fixtures``.

Generators build their output deterministically and call :func:`check_or_write`.
With ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) the file is (re)written;
otherwise the test fails if the committed file differs -- the same pattern as
``openapi.json``, so logic changes can't silently leave the Swift port's
fixtures behind. A mismatch prints a compact unified diff of the first changed lines
(:func:`drift_diff`), so a drift that only CI sees names its case.
"""

from __future__ import annotations

import difflib
import json
import os
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).resolve().parents[2] / "shared" / "fixtures"
UPDATE_ENV = "QUICKR_UPDATE_VECTORS"
# The drift report: at most this many diff lines, each cut to about this many characters.
DRIFT_MAX_LINES = 40
DRIFT_WIDTH = 240


def updating() -> bool:
    return os.environ.get(UPDATE_ENV) == "1"


def stale_message(path: Path) -> str:
    return f"{path.relative_to(FIXTURES_DIR.parents[1])} is stale - run 'make vectors'"


def check_or_write(path: Path, content: str) -> None:
    if updating():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return
    assert path.exists(), stale_message(path)
    committed = path.read_text()
    assert committed == content, f"{stale_message(path)}\n{drift_diff(committed, content)}"


def _first_difference(a: str, b: str) -> int:
    return next((i for i, (x, y) in enumerate(zip(a, b, strict=False)) if x != y), min(len(a), len(b)))


def _clip(line: str, at: int) -> str:
    """``line`` cut to about ``DRIFT_WIDTH``: its head (the case's name, in ``dump_cases``
    lines) and the window around column ``at``, where it differs from its counterpart."""
    if len(line) <= DRIFT_WIDTH:
        return line
    head = DRIFT_WIDTH // 3
    start = max(head, at - DRIFT_WIDTH // 3)
    end = start + DRIFT_WIDTH - head
    gap = "" if start == head else " … "
    return line[:head] + gap + line[start:end] + (" …" if end < len(line) else "")


def drift_diff(committed: str, generated: str) -> str:
    """A compact unified diff (no context) of the committed file and the generated content:
    the first ``DRIFT_MAX_LINES`` lines of it, a long line clipped around the column where it
    differs from its counterpart (the n-th removed and the n-th added line of a hunk)."""
    out: list[str] = []
    removed: list[str] = []
    added: list[str] = []

    def flush() -> None:
        for i, line in enumerate(removed):
            other = added[i] if i < len(added) else line
            out.append("-" + _clip(line, _first_difference(line, other)))
        for i, line in enumerate(added):
            other = removed[i] if i < len(removed) else line
            out.append("+" + _clip(line, _first_difference(line, other)))
        removed.clear()
        added.clear()

    diff = difflib.unified_diff(
        committed.splitlines(), generated.splitlines(), "committed", "generated", n=0, lineterm=""
    )
    for line in diff:
        if line.startswith(("---", "+++", "@@")):
            flush()
            out.append(line)
        elif line.startswith("-"):
            removed.append(line[1:])
        elif line.startswith("+"):
            added.append(line[1:])
    flush()
    if not out:
        return "(no line differs: only the final newline does)"
    shown = out[:DRIFT_MAX_LINES]
    if len(out) > DRIFT_MAX_LINES:
        shown.append(f"… and {len(out) - DRIFT_MAX_LINES} more changed lines")
    return "\n".join(shown)


def dump_json(value: Any) -> str:
    """Pretty, sorted, newline-terminated JSON."""
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def dump_cases(doc: dict[str, Any]) -> str:
    """Like :func:`dump_json`, but top-level lists hold one compact item per line.

    Keeps thousands of vectors small and their diffs readable.
    """
    parts: list[str] = []
    for key in sorted(doc):
        value = doc[key]
        if isinstance(value, list) and value:
            items = ",\n".join(
                "    " + json.dumps(item, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
                for item in value
            )
            rendered = f"[\n{items}\n  ]"
        else:
            rendered = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False).replace("\n", "\n  ")
        parts.append(f"  {json.dumps(key)}: {rendered}")
    return "{\n" + ",\n".join(parts) + "\n}\n"
