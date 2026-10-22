"""Fixtures for one supported client, from this checkout's ``shared/fixtures``.

``compat/supported-clients.json`` lists the iOS builds the server must keep serving, and for
each one the vector cases it predates (a new enum case, say) with the fallback it must take
instead (docs/ios/specs/compatibility.md). This writes, for the client with ``sha``:

- ``<out>/fixtures``: ``shared/fixtures`` without those cases, and without the API fixtures of
  operations the client's ``openapi.json`` doesn't have (it never calls them), for the
  client's own wire suites, which must pass on everything else;
- ``<out>/fallbacks.json``: ``[{file, name, expect, case}]``, each case with the fallback it
  must take, for ``CompatFallbackTests``.

A declared case that isn't in the fixtures (or is there twice) is an error, so the list
can't go stale. Usage::

    python3 compat/client_fixtures.py shas
    python3 compat/client_fixtures.py suites
    python3 compat/client_fixtures.py skip
    python3 compat/client_fixtures.py fixtures <sha> <out>
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "compat" / "supported-clients.json"
FIXTURES = ROOT / "shared" / "fixtures"
EXPECTATIONS = {"unread", "plain", "no-category"}


def policy() -> dict[str, Any]:
    data: dict[str, Any] = json.loads(POLICY.read_text())
    return data


def client(sha: str) -> dict[str, Any]:
    matches: list[dict[str, Any]] = [c for c in policy()["clients"] if c["sha"] == sha]
    if len(matches) != 1:
        sys.exit(f"{POLICY.name}: no single client with sha {sha}")
    return matches[0]


def take(vectors: dict[str, Any], name: str, where: str) -> dict[str, Any]:
    """Removes the case called ``name`` from whichever top-level list holds it."""
    found = [
        (key, i)
        for key, value in vectors.items()
        if isinstance(value, list)
        for i, item in enumerate(value)
        if isinstance(item, dict) and item.get("name") == name
    ]
    if len(found) != 1:
        sys.exit(f"{where}: case {name!r} found {len(found)} times, expected once")
    key, i = found[0]
    case: dict[str, Any] = vectors[key].pop(i)
    return case


def operations(sha: str) -> set[str]:
    """The operationIds in the client's own ``openapi.json``."""
    spec: dict[str, Any] = json.loads(
        subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{sha}:openapi.json"], capture_output=True, check=True
        ).stdout
    )
    return {
        op["operationId"]
        for methods in spec["paths"].values()
        for op in methods.values()
        if "operationId" in op
    }


def write_fixtures(sha: str, out: Path) -> None:
    entry = client(sha)
    target = out / "fixtures"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(FIXTURES, target)
    known = operations(sha)
    for fixture in sorted((target / "api").glob("*.json")):
        if fixture.name.split(".")[0] not in known:
            print(f"{entry['build']}: drops api/{fixture.name} (an operation it doesn't call)")
            fixture.unlink()
    fallbacks = []
    for file, cases in sorted(entry["fallbacks"].items()):
        path = target / file
        if not path.is_file():
            sys.exit(f"{POLICY.name}: {entry['build']} declares {file}, which isn't in shared/fixtures")
        vectors = json.loads(path.read_text())
        for name, expect in sorted(cases.items()):
            where = f"{POLICY.name}: {entry['build']}: {file}"
            if expect not in EXPECTATIONS:
                sys.exit(f"{where}: {name}: unknown fallback {expect!r} (one of {sorted(EXPECTATIONS)})")
            case = take(vectors, name, where)
            fallbacks.append({"file": file, "name": name, "expect": expect, "case": case})
        path.write_text(json.dumps(vectors, indent=2) + "\n")
    (out / "fallbacks.json").write_text(json.dumps(fallbacks, indent=2) + "\n")
    print(f"{entry['build']} ({sha[:7]}): {len(fallbacks)} case(s) checked as fallbacks")


def main(argv: list[str]) -> None:
    match argv:
        case ["shas"]:
            print("\n".join(c["sha"] for c in policy()["clients"]))
        case ["suites"]:
            print("\n".join(policy()["suites"]))
        case ["skip"]:
            print("\n".join(policy()["skip"]))
        case ["fixtures", sha, out]:
            write_fixtures(sha, Path(out))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
