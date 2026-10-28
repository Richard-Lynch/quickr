"""The compatibility gate's scripts (compat/), run in throwaway fixture repos.

V11 (docs/specs/client-versions.md §6, §7): ``openapi-breaking.sh`` lets openapi.json break the
newest ``v*`` tag only when ``shared/api-level.json`` raises ``api_level`` and sets both minimums
to it, and never lets it break a supported client. Also the rest of §7: the client list's levels
(``client_fixtures.py``), the ``api level`` checks (``api_level.py``), and ``old-requests.sh``
replaying each supported client at its own level.

oasdiff is replaced by a stub that calls any change to openapi.json a break: what is under test is
the gate's rule, not oasdiff's.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ["client_fixtures.py", "api_level.py", "openapi-breaking.sh", "old-requests.sh"]
GIT = ["git", "-c", "user.name=compat", "-c", "user.email=compat@example.com", "-c", "commit.gpgsign=false"]

# Like oasdiff, it exits 1 for a break and 100 or more when it can't run: here, for a spec that
# says "unreadable".
STUB_OASDIFF = """#!/usr/bin/env bash
if [[ "$1" == --version ]]; then echo "oasdiff version stub"; exit 0; fi
grep -q unreadable "$3" && { echo "Error: failed to load revision spec"; exit 102; }
cmp -s "$2" "$3" && exit 0
echo "error [stub-break] openapi.json changed"
exit 1
"""

# Records what old-requests.sh runs pytest with, one line per client: the level, then the sha
# (QUICKR_REQUEST_GOLDENS_DIR is <work>/<sha>/shared/fixtures/requests).
STUB_UV = """#!/usr/bin/env bash
sha="${QUICKR_REQUEST_GOLDENS_DIR%/shared/fixtures/requests}"
echo "$QUICKR_REPLAY_CLIENT_LEVEL ${sha##*/}" >> "$UV_LOG"
"""


def levels(api: int, ios: int, web: int | None = None) -> dict[str, Any]:
    return {"api_level": api, "min_client_level": {"ios": ios, "web": ios if web is None else web}}


class Repo:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.commits = 0
        (path / "compat").mkdir(parents=True)
        for script in SCRIPTS:
            shutil.copy2(ROOT / "compat" / script, path / "compat" / script)
        (path / "compat" / "openapi-break-approvals.txt").write_text("")
        (path / "backend").mkdir()
        self.write("shared/fixtures/requests/createTopic.json", {})
        self.policy([])
        self.git("init", "-q", "-b", "main")

    def git(self, *args: str) -> str:
        # Each commit a second after the last, so the newest tag is the last one made.
        date = f"2026-01-01T00:00:{self.commits:02d}Z"
        env = {**os.environ, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
        run = [*GIT, "-C", str(self.path), *args]
        return subprocess.run(run, capture_output=True, text=True, env=env, check=True).stdout

    def write(self, name: str, data: Any) -> None:
        path = self.path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2) + "\n")

    def commit(self, **files: Any) -> str:
        """Writes ``files`` (``api_level`` and ``openapi``, a None removes it) and commits."""
        names = {"api_level": "shared/api-level.json", "openapi": "openapi.json"}
        for key, data in files.items():
            if data is None:
                (self.path / names[key]).unlink(missing_ok=True)
            else:
                self.write(names[key], data)
        self.git("add", "-A")
        self.commits += 1
        self.git("commit", "-q", "--allow-empty", "-m", "change")
        return self.git("rev-parse", "HEAD").strip()

    def policy(self, clients: list[dict[str, Any]]) -> None:
        self.write("compat/supported-clients.json", {"suites": [], "skip": {}, "clients": clients})

    def run(self, *argv: str, **env: str) -> subprocess.CompletedProcess[str]:
        stubs = self.path.parent / "stubs"
        stubs.mkdir(exist_ok=True)
        for name, text in (("oasdiff", STUB_OASDIFF), ("uv", STUB_UV)):
            (stubs / name).write_text(text)
            (stubs / name).chmod(0o755)
        environ = {**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}", **env}
        environ.pop("GITHUB_ACTIONS", None)
        return subprocess.run(
            list(argv), cwd=self.path, capture_output=True, text=True, env=environ, check=False
        )

    def breaking(self, *refs: str) -> subprocess.CompletedProcess[str]:
        return self.run("compat/openapi-breaking.sh", *refs)

    def fixtures(self, *argv: str) -> subprocess.CompletedProcess[str]:
        return self.run("python3", "compat/client_fixtures.py", *argv)

    def api_level(self, *argv: str) -> subprocess.CompletedProcess[str]:
        return self.run("python3", "compat/api_level.py", *argv)


@pytest.fixture
def repo(tmp_path: Path) -> Repo:
    return Repo(tmp_path / "repo")


OPENAPI: dict[str, Any] = {"paths": {"/a": {}, "/b": {}}}
BROKEN: dict[str, Any] = {"paths": {"/a": {}}}  # /b removed


def client(build: str, sha: str, level: int | None = None) -> dict[str, Any]:
    entry: dict[str, Any] = {"build": build, "sha": sha, "source": "test", "fallbacks": {}}
    if level is not None:
        entry["api_level"] = level
    return entry


# --- V11: openapi breaking, against the tag -------------------------------------------------


@pytest.mark.parametrize(
    ("tag_levels", "now", "passes"),
    [
        (levels(1, 0), levels(1, 0), False),  # no bump
        (levels(1, 0), levels(2, 2), True),  # the bump
        (levels(1, 0), levels(2, 1), False),  # api_level raised, minimums not set to it
        (levels(1, 0), levels(2, 2, 0), False),  # the web minimum left behind
        (levels(1, 1), levels(1, 1), False),  # minimums already at api_level: still no bump
        (None, levels(1, 1), True),  # a tag before CV counts as level 0
        (None, levels(1, 0), False),
    ],
)
def test_a_break_against_the_tag_needs_a_bump(
    repo: Repo, tag_levels: dict[str, Any] | None, now: dict[str, Any], passes: bool
) -> None:
    repo.commit(api_level=tag_levels, openapi=OPENAPI)
    repo.git("tag", "v1")
    repo.commit(api_level=now, openapi=BROKEN)
    r = repo.breaking()
    assert (r.returncode == 0) == passes, r.stdout + r.stderr
    if not passes:
        assert "a breaking change must bump shared/api-level.json" in r.stderr


def test_no_break_needs_no_bump(repo: Repo) -> None:
    repo.commit(api_level=levels(1, 0), openapi=OPENAPI)
    repo.git("tag", "v1")
    repo.commit()
    assert repo.breaking().returncode == 0


def test_the_newest_tag_is_compared(repo: Repo) -> None:
    repo.commit(api_level=levels(1, 0), openapi=OPENAPI)
    repo.git("tag", "v1")
    repo.commit(api_level=levels(2, 2), openapi=BROKEN)
    repo.git("tag", "v2")
    repo.commit(api_level=levels(2, 2), openapi={"paths": {}})
    r = repo.breaking()
    assert r.returncode == 1  # v2 already has level 2: this break needs level 3
    assert "against v2" in r.stdout


def test_a_bump_does_not_excuse_oasdiff_failing_to_run(repo: Repo) -> None:
    repo.commit(api_level=levels(1, 0), openapi=OPENAPI)
    repo.git("tag", "v1")
    repo.commit(api_level=levels(2, 2), openapi={"unreadable": True})
    r = repo.breaking()
    assert r.returncode == 1
    assert "oasdiff failed against v1 (exit 102)" in r.stderr
    assert "so the break passes" not in r.stdout


# --- V11: openapi breaking, against supported clients ---------------------------------------


def test_a_break_against_a_supported_client_fails_even_with_a_bump(repo: Repo) -> None:
    """A build from after the tag (a TestFlight upload from main, say) can already speak the
    bumped level: the bump excuses the break against the tag, not against it."""
    repo.commit(api_level=levels(1, 1), openapi=OPENAPI)
    repo.git("tag", "v1")
    sha = repo.commit(api_level=levels(2, 2))
    repo.policy([client("2", sha, 2)])
    repo.commit(api_level=levels(2, 2), openapi=BROKEN)
    r = repo.breaking()
    assert r.returncode == 1
    assert "so the break passes" in r.stdout  # against v1
    assert f"breaks the API of supported client {sha}" in r.stderr


def test_raising_the_minimum_above_a_client_stops_comparing_it(repo: Repo) -> None:
    sha = repo.commit(api_level=levels(1, 1), openapi=OPENAPI)
    repo.git("tag", "v1")
    repo.policy([client("1", sha, 1)])
    repo.commit(api_level=levels(2, 2), openapi=BROKEN)
    r = repo.breaking()
    assert r.returncode == 0, r.stdout + r.stderr
    assert sha not in r.stdout
    assert "skips build 1" in r.stderr


# --- the client list ------------------------------------------------------------------------


def test_shas_lists_only_clients_at_or_above_the_minimum(repo: Repo) -> None:
    old, mid, new = (repo.commit() for _ in range(3))
    repo.policy([client("3", new, 3), client("2", mid, 2), client("1", old)])  # "1" has no level: 0
    repo.commit(api_level=levels(3, 2))
    r = repo.fixtures("shas")
    assert r.stdout.split() == [new, mid]
    assert "skips build 1" in r.stderr
    assert "level 0 is below min_client_level.ios 2" in r.stderr
    assert repo.fixtures("level", old).stdout == "0\n"
    assert repo.fixtures("level", mid).stdout == "2\n"


def test_add_records_the_level_at_the_builds_sha(repo: Repo) -> None:
    before = repo.commit(api_level=None)
    after = repo.commit(api_level=levels(2, 1))
    for build, sha in (("1", before), ("2", after)):
        assert repo.fixtures("add", build, sha, "test").returncode == 0
    listed = json.loads((repo.path / "compat/supported-clients.json").read_text())["clients"]
    assert [(c["build"], c["api_level"]) for c in listed] == [("2", 2), ("1", 0)]


MALFORMED: list[tuple[str, Any]] = [("a string level", "1"), ("a negative level", -1)]


@pytest.mark.parametrize(("_", "bad"), MALFORMED)
def test_a_malformed_client_fails_the_gate(repo: Repo, _: str, bad: Any) -> None:
    """A client list that can't be read stops each script, rather than leaving no clients to check
    (a failing command in a for-list or process substitution doesn't stop bash, even with set -e)."""
    sha = repo.commit(api_level=levels(1, 0), openapi=OPENAPI)
    repo.git("tag", "v1")
    repo.policy([client("1", sha, bad)])
    repo.commit()
    assert repo.fixtures("shas").returncode == 1
    assert repo.fixtures("check").returncode == 1
    assert repo.breaking().returncode == 1
    log = repo.path.parent / "uv.log"
    assert repo.run("compat/old-requests.sh", UV_LOG=str(log)).returncode == 1
    assert not log.exists()


def test_check_needs_each_clients_level_at_its_sha(repo: Repo) -> None:
    before = repo.commit(api_level=None)
    after = repo.commit(api_level=levels(2, 1))
    good = [client("2", after, 2), client("1", before)]  # missing: no file at that sha, so 0
    for clients, error in [
        (good, None),
        ([client("2", after, 1)], "api_level is 1, but"),
        ([client("2", after)], "api_level is missing (0), but"),
        ([client("1", before, 1)], "api_level is 1, but"),
        ([client("1", before[:7], 0)], "isn't a full commit sha"),
        ([{**client("1", before, 0), "build": ""}], "no build"),
    ]:
        repo.policy(clients)
        r = repo.fixtures("check")
        assert (r.returncode == 0) == (error is None), (clients, r.stdout + r.stderr)
        if error is not None:
            assert error in r.stderr


def test_add_refuses_a_sha_it_cannot_read(repo: Repo) -> None:
    repo.commit(api_level=levels(1, 0))
    r = repo.fixtures("add", "1", "f" * 40, "test")
    assert r.returncode == 1
    assert "isn't a commit in this checkout" in r.stderr


# --- the api level check --------------------------------------------------------------------


@pytest.mark.parametrize(
    ("base", "now", "error"),
    [
        (levels(1, 0), levels(1, 0), None),
        (levels(1, 0), levels(2, 2), None),
        (None, levels(1, 0), None),  # a base before CV counts as level 0
        (levels(1, 0), levels(1, 2, 0), "min_client_level.ios (2) is above api_level (1)"),
        (levels(2, 2), levels(1, 1), "api_level went down from 2 to 1"),
        (levels(2, 2), levels(2, 2, 1), "min_client_level.web went down from 2 to 1"),
        (levels(2, 2), levels(2, 1, 2), "min_client_level.ios went down from 2 to 1"),
        (levels(1, 0), levels(3, 3), "api_level went up by more than one, from 1 to 3"),
    ],
)
def test_api_level_check(
    repo: Repo, base: dict[str, Any] | None, now: dict[str, Any], error: str | None
) -> None:
    sha = repo.commit(api_level=base)
    repo.write("shared/api-level.json", now)
    r = repo.api_level("check", sha)
    assert (r.returncode == 0) == (error is None), r.stdout + r.stderr
    if error is not None:
        assert error in r.stderr


# --- old requests ---------------------------------------------------------------------------


def test_old_requests_replays_each_supported_client_at_its_level(repo: Repo) -> None:
    """compat/old-requests.sh sets QUICKR_REPLAY_CLIENT_LEVEL from each client's api_level
    (missing means 0), and replays no client below the minimum: test_request_goldens.py's
    test_a_listed_client_below_the_minimum_gets_426_on_replay shows what that level does."""
    level_0, level_1, level_2 = (repo.commit() for _ in range(3))
    repo.policy([client("2", level_2, 2), client("1", level_1, 1), client("0", level_0)])
    log = repo.path.parent / "uv.log"

    repo.commit(api_level=levels(2, 0))
    assert repo.run("compat/old-requests.sh", UV_LOG=str(log)).returncode == 0
    assert log.read_text().splitlines() == [f"2 {level_2}", f"1 {level_1}", f"0 {level_0}"]

    log.unlink()
    repo.commit(api_level=levels(2, 1))
    assert repo.run("compat/old-requests.sh", UV_LOG=str(log)).returncode == 0
    assert log.read_text().splitlines() == [f"2 {level_2}", f"1 {level_1}"]
