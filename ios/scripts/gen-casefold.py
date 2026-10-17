#!/usr/bin/env python3
"""Writes QuickrCore/Builder/CaseFoldTable.swift from shared/fixtures/builder-vectors.json.

The table is the server's Python `str.casefold()` (its Unicode version, not the OS's), which the
builder needs to compare labels the way the server does. `make vectors` regenerates it with the
fixture (backend/tests/test_builder_vectors.py renders it through `render`), and the backend
drift check fails when the committed file differs. By hand, run it with the backend's Python:

    cd backend && uv run python ../ios/scripts/gen-casefold.py [--check]

`--check` exits 1 instead of writing when the file is stale. Either way the interpreter's
Unicode version must be the fixture's, so a different Python can't produce a different table.
"""

from __future__ import annotations

import json
import sys
import unicodedata
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "shared/fixtures/builder-vectors.json"
OUT = ROOT / "ios/QuickrKit/Sources/QuickrCore/Builder/CaseFoldTable.swift"


def check_unicode(version: str) -> None:
    """Fail unless this interpreter has the Unicode version the fixture was built with."""
    if unicodedata.unidata_version != version:
        raise SystemExit(
            f"{sys.executable} (Python {sys.version.split()[0]}) has Unicode "
            f"{unicodedata.unidata_version}, but the fixture was generated with Unicode {version}. "
            "Use the backend's Python (cd backend && uv run python …), or regenerate the vectors "
            "with it first ('make vectors')."
        )


def render(doc: dict[str, Any]) -> str:
    """CaseFoldTable.swift for a builder-vectors document."""
    entries = [f"{c:x}:{' '.join(f'{m:x}' for m in mapped)}" for c, mapped in doc["casefold"]]
    lines = []
    line = ""
    for entry in entries:
        piece = entry + ","
        if len(line) + len(piece) > 100:
            lines.append(line)
            line = ""
        line += piece
    lines.append(line.rstrip(","))
    version = doc["meta"]["unicode_version"]
    body = "\n".join(f"        {x}" for x in lines)
    return f"""// Generated from shared/fixtures/builder-vectors.json by ios/scripts/gen-casefold.py.
// Do not edit: 'make vectors' regenerates it, and the backend drift check fails when it's stale.
// Python str.casefold(), Unicode {version}: {len(entries)} code points fold to something else.

extension BuilderText {{
    /// `code point:folded code points`, hex, comma-separated.
    static let caseFoldTable = \"\"\"
{body}
        \"\"\"
}}
"""


def main(argv: list[str]) -> int:
    doc = json.loads(FIXTURE.read_text())
    check_unicode(doc["meta"]["unicode_version"])
    content = render(doc)
    if "--check" in argv:
        if not OUT.exists() or OUT.read_text() != content:
            print(
                f"{OUT.relative_to(ROOT)} is stale - run 'make vectors'",
                file=sys.stderr,
            )
            return 1
        return 0
    OUT.write_text(content)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(doc['casefold'])} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
