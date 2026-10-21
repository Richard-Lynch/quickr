#!/usr/bin/env python3
"""Judges a run of checkpoint D's category probe (DeviceProbe; docs/ios/demo/DEVICE-DAY.md D8, D9).

Usage: dprobe-summary.py <results.jsonl> [run]

Reads the probe's results file (copied off the device or simulator) and prints, for the last
run (or the one given):
- D8: the rounds complete at once, after one reconcile, or not; how many attempts overlapped;
  and the verdict.
- D9: set, register and readback times per process and size.

Exit status: 0 for a complete run (D8: go), 1 for D8 no-go (a round failed), 3 for an incomplete
run (rounds missing, an error, a timeout, a stop, a side not done, or the real categories not
restored). An incomplete run decides nothing: run it again.
"""

import json
import sys


def load(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                print(f"skipped a malformed line: {line[:80]}", file=sys.stderr)
    return records


def problems(mine, sides):
    """Why the run is incomplete, whatever the probe."""
    found = []
    for r in mine:
        if r["event"] in ("error", "timeout", "stopped"):
            found.append(
                f"{r['process']} {r['event']}: {r.get('note', '')} (round {r.get('round')}, size {r.get('size')})"
            )
    for side in sides:
        done = [r for r in mine if r["process"] == side and r["event"] == "done"]
        if not done:
            found.append(f"{side} never finished")
        elif not all(r.get("ok") for r in done):
            found.append(f"{side} didn't restore the real categories")
    return found


def d8(mine):
    start = next(
        (r for r in mine if r["process"] == "app" and r["event"] == "start"), None
    )
    wanted = start.get("rounds") if start else None
    rounds = {
        r["round"]: r for r in mine if r["process"] == "app" and r["event"] == "round"
    }
    found = problems(mine, ("app", "nse"))
    if wanted is None:
        found.append("no start record: the run's round count is unknown")
    elif sorted(rounds) != list(range(1, wanted + 1)):
        found.append(f"{len(rounds)} of {wanted} rounds recorded")
    at_once = sum(1 for r in rounds.values() if r.get("ok") and not r.get("missing"))
    after = sum(1 for r in rounds.values() if r.get("ok") and r.get("missing"))
    failed = sorted(n for n, r in rounds.items() if not r.get("ok"))
    overlapped = sum(1 for r in rounds.values() if r.get("overlap"))
    print(
        f"D8: {len(rounds)} rounds: {at_once} complete at once, {after} after one reconcile, {len(failed)} not"
        + (f" ({failed[:10]}{'…' if len(failed) > 10 else ''})" if failed else "")
    )
    print(
        f"D8: the app's and the NSE's attempts overlapped in {overlapped} of {len(rounds)} rounds"
    )
    for p in found:
        print(f"  incomplete: {p}")
    if failed:
        print(
            "D8 NO-GO: a round lost a category even after one reconcile (notifications.md §5.4); report it"
        )
        return 1
    if found:
        print("D8 INCOMPLETE: run it again")
        return 3
    print("D8 go")
    return 0


def d9(mine):
    found = problems(mine, ("app", "nse"))
    print("D9: process   size     set ms  register ms  readback ms     seen  ok")
    short = []
    for r in mine:
        if r["event"] == "size":
            readback = r.get("readback_ms")
            seen = r.get("seen")
            print(
                f"    {r['process']:<7} {r['size']:>6}  {r.get('set_ms') or 0:>9.1f}  {r.get('register_ms') or 0:>11.1f}  "
                f"{readback if readback is not None else '—':>11}  {seen if seen is not None else '—':>7}  {r.get('ok')}"
                f"{'  (past the deadline)' if r.get('overrun') else ''}"
            )
            if not r.get("ok") and not r.get("overrun"):
                short.append(f"{r['process']} {r['size']}: the readback showed {seen} of {r['size']} within 10 s")
    for s in short:
        print(f"  finding: {s}")
    for p in found:
        print(f"  incomplete: {p}")
    print(
        "Compare the NSE's set and readback times at the projected one-year category count with its 3 s target (D1)."
    )
    if found:
        print(
            "D9 INCOMPLETE: run it again (a size the NSE ran out of time for is itself a finding)"
        )
        return 3
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    records = load(sys.argv[1])
    if not records:
        print("no records")
        return 3
    run = sys.argv[2] if len(sys.argv) > 2 else records[-1]["run"]
    mine = [r for r in records if r["run"] == run]
    if not mine:
        print(f"no records for run {run}")
        return 3
    probe = mine[0]["probe"]
    print(f"run {run} ({probe}), {len(mine)} records")
    return d8(mine) if probe == "d8" else d9(mine)


if __name__ == "__main__":
    sys.exit(main())
