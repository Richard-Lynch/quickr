"""Writing and drift-checking the generated files under ``shared/fixtures``.

Generators build their output deterministically and call :func:`check_or_write`.
With ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) the file is (re)written;
otherwise the test fails if the committed file differs -- the same pattern as
``openapi.json``, so logic changes can't silently leave the Swift port's
fixtures behind.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

FIXTURES_DIR = Path(__file__).resolve().parents[2] / "shared" / "fixtures"
UPDATE_ENV = "QUICKR_UPDATE_VECTORS"


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
    assert path.read_text() == content, stale_message(path)


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
