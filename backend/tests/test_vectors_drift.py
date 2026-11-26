"""``tests.vectors.check_or_write``'s drift report (#199): a stale fixture names the case."""

from __future__ import annotations

from pathlib import Path

import pytest

from tests import vectors
from tests.vectors import check_or_write, drift_diff, dump_cases


def _doc(mean: float) -> str:
    return dump_cases(
        {
            "cases": [
                {"name": "series many d week", "response": {"mean": mean, "points": list(range(200))}},
                {"name": "series many n day", "response": {"mean": 1.0}},
            ],
            "meta": {"generator_version": 1},
        }
    )


@pytest.fixture
def fixture_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.delenv(vectors.UPDATE_ENV, raising=False)
    monkeypatch.setattr(vectors, "FIXTURES_DIR", tmp_path / "shared" / "fixtures")
    path = vectors.FIXTURES_DIR / "x-vectors.json"
    path.parent.mkdir(parents=True)
    return path


def test_a_match_passes(fixture_file: Path) -> None:
    fixture_file.write_text(_doc(-6172.839000000087))
    check_or_write(fixture_file, _doc(-6172.839000000087))


def test_a_mismatch_prints_the_drifting_case(fixture_file: Path) -> None:
    fixture_file.write_text(_doc(-6172.839000000087))
    with pytest.raises(AssertionError) as raised:
        check_or_write(fixture_file, _doc(-6172.839000000063))
    message = str(raised.value)
    assert "shared/fixtures/x-vectors.json is stale - run 'make vectors'" in message
    assert "--- committed" in message
    assert "+++ generated" in message
    # The changed line, by its case name, with the old and the new value.
    assert "series many d week" in message
    assert "-6172.839000000087" in message
    assert "-6172.839000000063" in message
    # Only the changed line: the unchanged case isn't repeated.
    assert "series many n day" not in message


def test_the_report_is_compact() -> None:
    old = "".join(f'    {{"name":"case {i}","v":{i}}},\n' for i in range(500))
    new = "".join(f'    {{"name":"case {i}","v":{i + 1}}},\n' for i in range(500))
    report = drift_diff(old, new)
    assert report.count("\n") <= vectors.DRIFT_MAX_LINES + 2
    assert "more changed lines" in report
    # Both sides of the first changes survive the cut, next to each other.
    assert '-    {"name":"case 0","v":0},' in report
    assert '+    {"name":"case 0","v":1},' in report
    assert report.index('"case 0","v":1') < report.index('"case 1","v":1')
    long_old = '    {"name":"long","v":[' + ",".join(["1"] * 2000) + "]}\n"
    long_new = long_old.replace("1]", "2]")
    report = drift_diff(long_old, long_new)
    assert all(len(line) <= 2 * vectors.DRIFT_WIDTH for line in report.splitlines())
    assert '"name":"long"' in report
    assert "2]}" in report
