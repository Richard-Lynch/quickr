#!/usr/bin/env python3
"""Summarises checkpoint D's category probe (DeviceProbe; docs/ios/demo/DEVICE-DAY.md D8, D9).

Usage: dprobe-summary.py <results.jsonl> [run]

Reads the probe's results file (copied off the device or simulator) and prints, for the last
run (or the one given): D8's rounds (all three categories registered at once, after one
reconcile, or not), and D9's register and readback times per process and size.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    records = []
    with open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    print(f"skipped a malformed line: {line[:80]}", file=sys.stderr)
    if not records:
        print("no records")
        return 1
    run = sys.argv[2] if len(sys.argv) > 2 else records[-1]["run"]
    mine = [r for r in records if r["run"] == run]
    probe = mine[0]["probe"]
    print(f"run {run} ({probe}), {len(mine)} records")

    for r in mine:
        if r["event"] in ("timeout", "error"):
            print(
                f"  {r['process']} {r['event']}: {r.get('note', '')} (round {r.get('round')}, size {r.get('size')})"
            )

    if probe == "d8":
        rounds = [r for r in mine if r["event"] == "round"]
        at_once = sum(1 for r in rounds if r.get("ok") and not r.get("missing"))
        after_reconcile = sum(1 for r in rounds if r.get("ok") and r.get("missing"))
        failed = [r["round"] for r in rounds if not r.get("ok")]
        print(
            f"D8: {len(rounds)} rounds: {at_once} complete at once, {after_reconcile} after one reconcile, "
            f"{len(failed)} not ({failed[:10]}{'…' if len(failed) > 10 else ''})"
        )
        print(
            "D8 go"
            if rounds and not failed
            else "D8 NO-GO: report it (notifications.md §5.4)"
        )
    else:
        print("D9: process  size   register ms  readback ms  ok")
        for r in mine:
            if r["event"] == "size":
                readback = r.get("readback_ms")
                print(
                    f"    {r['process']:<7} {r['size']:>5}  {r.get('register_ms', 0):>11.1f}  "
                    f"{readback if readback is not None else '—':>11}  {r.get('ok')}"
                )
        print(
            "Compare the NSE's times at the projected one-year category count with its 3 s target (D1)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
