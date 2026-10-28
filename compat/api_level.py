"""Checks on ``shared/api-level.json`` (docs/specs/client-versions.md §2, §7).

``check <base ref>`` is the ``api level`` job: ``min_client_level`` is at most ``api_level`` on
both platforms, and none of the three went down compared with the base branch. (The job also
checks that the generated copies are fresh, by running ``make api-level``.)

``bumped <tag>`` is the ``openapi breaking`` rule for the newest ``v*`` tag: openapi.json may break
the tag's API only if this checkout raises ``api_level`` above the tag's and sets both minimums
to it, so every client built before the break is refused rather than misread. It exits 0 when it
does, else 1 with the reason.

This checkout's file is the one in the working tree, as for openapi.json. A ref that predates the
file counts as ``{api_level: 0, min_client_level: {ios: 0, web: 0}}``. Usage::

    python3 compat/api_level.py check <base ref>
    python3 compat/api_level.py bumped <tag>
"""

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
PATH = "shared/api-level.json"
PLATFORMS = ("ios", "web")


@dataclass(frozen=True)
class Levels:
    api_level: int
    minimums: dict[str, int]

    def __str__(self) -> str:
        minimums = ", ".join(f"{p} {self.minimums[p]}" for p in PLATFORMS)
        return f"api_level {self.api_level} (min_client_level {minimums})"


def parse(data: dict[str, Any], where: str) -> Levels:
    try:
        levels = Levels(
            data["api_level"], {p: data["min_client_level"][p] for p in PLATFORMS}
        )
    except (KeyError, TypeError):
        sys.exit(f"{where}: needs api_level and min_client_level.ios/.web")
    if not all(
        type(v) is int and v >= 0 for v in (levels.api_level, *levels.minimums.values())
    ):
        sys.exit(f"{where}: levels must be non-negative integers")
    return levels


def here() -> Levels:
    return parse(json.loads((ROOT / PATH).read_text()), PATH)


def at(ref: str) -> Levels:
    git = ["git", "-C", str(ROOT)]
    if subprocess.run(
        [*git, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
        capture_output=True,
    ).returncode:
        sys.exit(f"{ref} isn't a commit in this checkout")
    shown = subprocess.run([*git, "show", f"{ref}:{PATH}"], capture_output=True)
    if shown.returncode:
        return Levels(0, {p: 0 for p in PLATFORMS})  # before client-versions.md
    return parse(json.loads(shown.stdout), f"{ref}:{PATH}")


def check(base: str) -> None:
    now, before = here(), at(base)
    errors = [
        f"min_client_level.{p} ({now.minimums[p]}) is above api_level ({now.api_level})"
        for p in PLATFORMS
        if now.minimums[p] > now.api_level
    ]
    if now.api_level < before.api_level:
        errors.append(f"api_level went down from {before.api_level} to {now.api_level}")
    errors += [
        f"min_client_level.{p} went down from {before.minimums[p]} to {now.minimums[p]}"
        for p in PLATFORMS
        if now.minimums[p] < before.minimums[p]
    ]
    print(f"compat: {PATH}: {now}; {base}: {before}")
    if errors:
        sys.exit(
            "\n".join(
                f"compat: {PATH}: {e} (docs/specs/client-versions.md §7)"
                for e in errors
            )
        )


def bumped(tag: str) -> None:
    now, before = here(), at(tag)
    if now.api_level > before.api_level and all(
        m == now.api_level for m in now.minimums.values()
    ):
        print(f"compat: {PATH} bumps {tag}'s {before} to {now}")
        return
    print(f"compat: {PATH} is {now}, {tag}'s is {before}", file=sys.stderr)
    print(
        f"compat: a breaking change must bump {PATH}: raise api_level above {before.api_level} and set "
        "min_client_level.ios and .web to it (docs/specs/client-versions.md §2)",
        file=sys.stderr,
    )
    sys.exit(1)


def main(argv: list[str]) -> None:
    match argv:
        case ["check", base]:
            check(base)
        case ["bumped", tag]:
            bumped(tag)
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
