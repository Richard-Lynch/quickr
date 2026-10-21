"""tools/faultproxy.py: the fault-injecting proxy the iOS integration tests drive.

Runs the proxy in-process in front of tiny fake upstreams (no database, no docker).
"""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any

import httpx
import pytest

from tools import faultproxy
from tools.faultproxy import FaultProxy, Upstream, read_request

# Raw upstream answers, by path. The default (anything else) is a JSON echo.
CANNED: dict[str, bytes] = {
    "/chunked": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n"
    b"5\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n",
    "/early-hints": b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\n"
    b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfinal",
    "/nocontent": b"HTTP/1.1 204 No Content\r\nX-QuickR-Server-Id: server-a\r\n\r\n",
    "/not-modified": b'HTTP/1.1 304 Not Modified\r\nETag: "v1"\r\nContent-Length: 42\r\n\r\n',
    "/hop": b"HTTP/1.1 200 OK\r\nConnection: X-Up-Secret, close\r\nX-Up-Secret: 1\r\n"
    b"Keep-Alive: timeout=5\r\n"
    b'ETag: "v1"\r\nX-QuickR-Server-Id: server-a\r\nX-QuickR-Epoch: epoch-1\r\nContent-Length: 2\r\n\r\nok',
    "/bad-chunk": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n",
    "/bad-chunk-size": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n",
    "/bad-length": b"HTTP/1.1 200 OK\r\nContent-Length: 5, 6\r\n\r\nhello",
    "/big": b"HTTP/1.1 200 OK\r\n\r\n" + b"x" * 1000,
}


def is_json(body: bytes) -> bool:
    try:
        json.loads(body)
    except ValueError:
        return False
    return True


@dataclass
class FakeUpstream:
    """Answers like the backend: JSON with identity headers. Records every request."""

    server_id: str
    requests: list[tuple[str, str, bytes]] = field(default_factory=list)
    server: asyncio.Server | None = None

    @property
    def port(self) -> int:
        assert self.server is not None
        return int(self.server.sockets[0].getsockname()[1])

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle, "127.0.0.1", 0)

    async def close(self) -> None:
        assert self.server is not None
        self.server.close()
        await self.server.wait_closed()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        req = await read_request(reader, writer)
        assert req is not None
        self.requests.append((req.method, req.target, req.body))
        identity = f"X-QuickR-Server-Id: {self.server_id}\r\nX-QuickR-Epoch: epoch-1\r\n"
        if req.path in CANNED:
            writer.write(CANNED[req.path])
        elif req.path == "/missing":
            missing = b'{"code": "not_found"}'
            writer.write(
                f"HTTP/1.1 404 Not Found\r\n{identity}Content-Length: {len(missing)}\r\n\r\n".encode()
                + missing
            )
        else:
            status = "201 Created" if req.method == "POST" else "200 OK"
            body = json.dumps(
                {
                    "id": "e1",
                    "revision": 1,
                    "server": self.server_id,
                    "echo": req.body.decode(),
                    "headers": {k.lower(): v for k, v in req.headers},
                    "header_list": [[k.lower(), v] for k, v in req.headers],
                }
            )
            writer.write(
                f"HTTP/1.1 {status}\r\n{identity}Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
                + (b"" if req.method == "HEAD" else body.encode())
            )
        await writer.drain()
        writer.close()


@dataclass
class Harness:
    proxy: FaultProxy
    a: FakeUpstream
    b: FakeUpstream
    client: httpx.AsyncClient
    control: httpx.AsyncClient

    async def rule(self, **rule: Any) -> dict[str, Any]:
        r = await self.control.post("/rules", json=rule)
        assert r.status_code == 201, r.text
        body: dict[str, Any] = r.json()
        return body

    async def log(self) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = (await self.control.get("/log")).json()
        return entries


@pytest.fixture
async def h() -> AsyncIterator[Harness]:
    a, b = FakeUpstream("server-a"), FakeUpstream("server-b")
    await a.start()
    await b.start()
    proxy = FaultProxy(
        [Upstream("a", "127.0.0.1", a.port), Upstream("b", "127.0.0.1", b.port)],
    )
    await proxy.start("127.0.0.1", 0, "127.0.0.1", 0)
    async with (
        httpx.AsyncClient(base_url=f"http://127.0.0.1:{proxy.port}", timeout=5) as client,
        httpx.AsyncClient(base_url=f"http://127.0.0.1:{proxy.control_port}", timeout=5) as control,
    ):
        yield Harness(proxy, a, b, client, control)
    await proxy.close()
    await a.close()
    await b.close()


async def test_passes_through_and_logs(h: Harness) -> None:
    r = await h.client.post("/api/v1/topics/t/entries?x=1", json={"answers": {}})
    assert r.status_code == 201
    assert r.json()["server"] == "server-a"
    assert r.headers["x-quickr-server-id"] == "server-a"
    assert h.a.requests == [("POST", "/api/v1/topics/t/entries?x=1", b'{"answers":{}}')]
    [entry] = await h.log()
    assert entry["method"] == "POST"
    assert entry["path"] == "/api/v1/topics/t/entries?x=1"
    assert entry["action"] == "pass"
    assert entry["rule"] is None
    assert (entry["upstream"], entry["upstream_status"], entry["status"]) == ("a", 201, 201)
    assert entry["state"] == "responded"


async def test_keeps_the_client_connection_alive(h: Harness) -> None:
    for _ in range(3):
        assert (await h.client.get("/api/v1/health")).status_code == 200
    assert len(h.a.requests) == 3


async def test_drop_response_commits_upstream_then_resets_the_client(h: Harness) -> None:
    rule = await h.rule(method="POST", path="/api/v1/topics/*/entries", action="drop_response")
    with pytest.raises(httpx.TransportError):
        await h.client.post("/api/v1/topics/t/entries", json={"id": "e1"})
    assert len(h.a.requests) == 1  # the backend saw (and committed) it
    [entry] = await h.log()
    assert (entry["rule"], entry["upstream_status"], entry["status"], entry["state"]) == (
        rule["id"],
        201,
        None,
        "dropped",
    )
    # One-shot: the retry goes through.
    assert (await h.client.post("/api/v1/topics/t/entries", json={"id": "e1"})).status_code == 201
    assert (await h.control.get(f"/rules/{rule['id']}")).json()["exhausted"] is True


async def test_drop_request_never_reaches_upstream(h: Harness) -> None:
    await h.rule(action="drop_request")
    with pytest.raises(httpx.TransportError):
        await h.client.get("/api/v1/health")
    assert h.a.requests == []
    [entry] = await h.log()
    assert (entry["upstream"], entry["state"]) == (None, "dropped")


@pytest.mark.parametrize(
    ("mode", "check"),
    [
        ("truncate", lambda body: not is_json(body)),
        ("drop_field", lambda body: "revision" not in json.loads(body)),
        ("not_json", lambda body: not is_json(body)),
        ("empty", lambda body: body == b""),
    ],
)
async def test_garble_corrupts_2xx_bodies(h: Harness, mode: str, check: Any) -> None:
    await h.rule(method="POST", path="/api/v1/topics/*/entries", action="garble", garble=mode)
    r = await h.client.post("/api/v1/topics/t/entries", json={})
    assert r.status_code == 201
    assert r.headers["content-length"] == str(len(r.content))  # well-formed HTTP, bad body
    assert check(r.content)
    assert len(h.a.requests) == 1


async def test_garble_drop_field_takes_any_field(h: Harness) -> None:
    await h.rule(action="garble", garble="drop_field", field="id")
    body = (await h.client.get("/x")).json()
    assert "id" not in body
    assert body["revision"] == 1


async def test_garble_leaves_non_2xx_alone(h: Harness) -> None:
    await h.rule(action="garble", sticky=True)
    r = await h.client.get("/missing")
    assert r.status_code == 404
    assert r.json() == {"code": "not_found"}


async def test_captive_page_without_upstream(h: Harness) -> None:
    await h.rule(action="captive")
    r = await h.client.get("/api/v1/changes")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/html")
    assert "<html>" in r.text
    assert "x-quickr-server-id" not in r.headers
    assert h.a.requests == []


@pytest.mark.parametrize(("status", "retry_after"), [(503, None), (429, "2")])
async def test_status_without_upstream(h: Harness, status: int, retry_after: str | None) -> None:
    rule: dict[str, Any] = {"action": "status", "status": status}
    if retry_after:
        rule["retry_after"] = retry_after
    await h.rule(**rule)
    r = await h.client.post("/api/v1/topics/t/entries", json={})
    assert r.status_code == status
    assert r.headers.get("retry-after") == retry_after
    assert h.a.requests == []
    [entry] = await h.log()
    assert (entry["upstream"], entry["status"]) == (None, status)


async def test_strip_identity(h: Harness) -> None:
    await h.rule(action="strip_identity")
    r = await h.client.get("/api/v1/health")
    assert r.status_code == 200
    assert "x-quickr-server-id" not in r.headers
    assert "x-quickr-epoch" not in r.headers
    assert len(h.a.requests) == 1


TOKEN = {"CF-Access-Client-Id": "app.access", "CF-Access-Client-Secret": "s3cret"}


async def test_access_forwards_with_the_token_and_swaps_it_for_a_jwt(h: Harness) -> None:
    await h.rule(action="access", sticky=True, client_id="app.access", client_secret="s3cret")
    r = await h.client.get("/api/v1/changes", headers=TOKEN)
    assert r.status_code == 200
    seen = r.json()["headers"]
    assert "cf-access-client-id" not in seen
    assert "cf-access-client-secret" not in seen
    assert seen["cf-access-jwt-assertion"] == "faultproxy.access.jwt"
    [entry] = await h.log()
    assert (entry["access"], entry["upstream"]) == ("granted", "a")


async def test_access_forwards_exactly_one_assertion(h: Harness) -> None:
    await h.rule(action="access", sticky=True, client_id="app.access", client_secret="s3cret")
    forged = [("Cf-Access-Jwt-Assertion", "forged"), ("cf-access-jwt-assertion", "forged-too")]
    r = await h.client.get("/x", headers=[*TOKEN.items(), *forged])
    assert r.status_code == 200
    assertions = [v for k, v in r.json()["header_list"] if k == "cf-access-jwt-assertion"]
    assert assertions == ["faultproxy.access.jwt"]


@pytest.mark.parametrize(
    ("strict", "headers", "status"),
    [
        (False, {}, 302),
        (False, {**TOKEN, "CF-Access-Client-Secret": "wrong"}, 302),
        # Strict mode applies only to requests carrying the headers: none still go to sign-in.
        (True, {}, 302),
        (True, {"CF-Access-Client-Id": "app.access"}, 403),
        (True, {**TOKEN, "CF-Access-Client-Secret": "wrong"}, 403),
    ],
)
async def test_access_refuses_without_the_right_token(
    h: Harness, strict: bool, headers: dict[str, str], status: int
) -> None:
    await h.rule(action="access", sticky=True, strict=strict, client_id="app.access", client_secret="s3cret")
    r = await h.client.get("/api/v1/changes", headers=headers)
    assert r.status_code == status
    assert "x-quickr-server-id" not in r.headers
    if status == 302:
        assert r.headers["location"].startswith("https://quickr.cloudflareaccess.com/")
    assert h.a.requests == []
    [entry] = await h.log()
    assert (entry["access"], entry["upstream"], entry["status"]) == ("denied", None, status)


@pytest.mark.parametrize("phase", ["request", "response"])
async def test_delay(h: Harness, phase: str) -> None:
    await h.rule(action="delay", delay_ms=200, phase=phase)
    start = time.monotonic()
    assert (await h.client.get("/api/v1/health")).status_code == 200
    assert time.monotonic() - start >= 0.2


async def test_hold_parks_the_request_until_released(h: Harness) -> None:
    rule = await h.rule(method="POST", path="/api/v1/topics/*/entries", action="hold")
    pending = asyncio.create_task(h.client.post("/api/v1/topics/t/entries", json={}))
    for _ in range(100):
        if (await h.control.get(f"/rules/{rule['id']}")).json()["waiting"] == 1:
            break
        await asyncio.sleep(0.01)
    assert h.a.requests == []
    assert (await h.log())[0]["state"] == "held"
    # Other traffic is not blocked behind the held request.
    assert (await h.client.get("/api/v1/health")).status_code == 200

    released = (await h.control.post(f"/rules/{rule['id']}/release")).json()
    assert released["released_now"] == 1
    assert (await pending).status_code == 201
    assert [m for m, _, _ in h.a.requests] == ["GET", "POST"]


async def test_held_request_still_reaches_upstream_after_the_client_left(h: Harness) -> None:
    rule = await h.rule(action="hold")
    with pytest.raises(httpx.TimeoutException):
        await h.client.post("/api/v1/topics/t/entries", json={}, timeout=0.2)
    await h.control.post(f"/rules/{rule['id']}/release")
    for _ in range(100):
        if h.a.requests:
            break
        await asyncio.sleep(0.01)
    assert [m for m, _, _ in h.a.requests] == ["POST"]


async def test_times_and_sticky(h: Harness) -> None:
    await h.rule(action="status", status=503, times=2)
    codes = [(await h.client.get("/x")).status_code for _ in range(3)]
    assert codes == [503, 503, 200]

    await h.control.delete("/rules")
    await h.rule(action="status", status=503, sticky=True)
    codes = [(await h.client.get("/x")).status_code for _ in range(3)]
    assert codes == [503, 503, 503]


async def test_matching_by_method_and_path_glob(h: Harness) -> None:
    await h.rule(method="patch", path="/api/v1/entries/*", action="status", status=503, sticky=True)
    assert (await h.client.get("/api/v1/entries/e1")).status_code == 200
    assert (await h.client.patch("/api/v1/topics/t", json={})).status_code == 200
    assert (await h.client.patch("/api/v1/entries/e1?x=1", json={})).status_code == 503


async def test_first_matching_rule_wins(h: Harness) -> None:
    await h.rule(path="/a", action="status", status=429)
    await h.rule(action="status", status=503)
    assert (await h.client.get("/a")).status_code == 429
    assert (await h.client.get("/a")).status_code == 503


async def test_switching_upstream(h: Harness) -> None:
    assert (await h.client.get("/x")).headers["x-quickr-server-id"] == "server-a"
    r = await h.control.put("/upstream", json={"name": "b"})
    assert r.json()["current"] == "b"
    assert (await h.client.get("/x")).headers["x-quickr-server-id"] == "server-b"
    assert (await h.log())[-1]["upstream"] == "b"
    assert (await h.control.put("/upstream", json={"name": "c"})).status_code == 400


async def test_reset(h: Harness) -> None:
    rule = await h.rule(action="hold")
    pending = asyncio.create_task(h.client.get("/x"))
    await h.control.put("/upstream", json={"name": "b"})
    await asyncio.sleep(0.05)
    assert (await h.control.post("/reset")).status_code == 200
    assert (await pending).status_code == 200  # reset releases held requests
    assert (await h.control.get("/rules")).json() == []
    assert (await h.control.get(f"/rules/{rule['id']}")).status_code == 404
    assert (await h.control.get("/upstream")).json()["current"] == "a"
    await h.control.delete("/log")
    assert await h.log() == []


async def test_dechunks_upstream_responses(h: Harness) -> None:
    r = await h.client.get("/chunked")
    assert r.text == "hello world"
    assert r.headers["content-length"] == "11"


async def test_upstream_down_is_a_502_with_no_upstream_status(h: Harness) -> None:
    await h.a.close()
    r = await h.client.get("/x")
    assert r.status_code == 502
    [entry] = await h.log()
    assert (entry["upstream_status"], entry["status"]) == (None, 502)
    await h.a.start()  # so the fixture can close it


@pytest.mark.parametrize(
    "rule",
    [
        {"action": "explode"},
        {"action": "pass", "colour": "red"},
        {"action": "garble", "garble": "sideways"},
        {"action": "delay", "phase": "later"},
        {"action": "pass", "times": 0},
        {"action": "status", "status": 42},
        {"action": "pass", "sticky": "yes"},
        ["not", "an", "object"],
        {},
        {"method": "GET"},
        {"action": 5},
        {"action": "pass", "method": 3},
        {"action": "pass", "method": "GE T"},
        {"action": "pass", "path": None},
        {"action": "pass", "times": "1"},
        {"action": "pass", "times": True},
        {"action": "delay", "delay_ms": 1.5},
        {"action": "delay", "delay_ms": -1},
        {"action": "status", "status": "503"},
        {"action": "status", "body": 5},
        {"action": "garble", "garble": []},
        {"action": "garble", "field": {}},
        {"action": "pass", "phase": None},
        {"action": "status", "retry_after": "1\r\nX-Injected: 1"},
        {"action": "captive", "content_type": "text/html\nX-Injected: 1"},
        {"action": "status", "status": 100},
        {"action": "status", "status": 103},
        {"action": "status", "status": 199},
        {"action": "status", "status": 600},
        {"action": "status", "content_type": "\U0001f600"},
        {"action": "status", "retry_after": "\U0001f600"},
        {"action": "captive", "content_type": "text/html; charset=\u00e9"},
        {"action": "status", "retry_after": "1\t2"},
        {"action": "access"},
        {"action": "access", "client_id": "x"},
        {"action": "access", "client_id": "x", "client_secret": ""},
        {"action": "access", "client_id": "x", "client_secret": "y", "strict": "yes"},
        {"action": "access", "client_id": "x", "client_secret": "\n"},
        {"action": "access", "client_id": "a b", "client_secret": "y"},
        {"action": "access", "client_id": "x", "client_secret": "s\u00e9cret"},
    ],
)
async def test_rejects_bad_rules(h: Harness, rule: Any) -> None:
    r = await h.control.post("/rules", json=rule)
    assert r.status_code == 400
    assert "error" in r.json()
    assert (await h.control.get("/rules")).json() == []  # nothing installed
    assert (await h.client.get("/x")).status_code == 200  # and the proxy still works


@pytest.mark.parametrize("body", [{"name": []}, {"name": None}, {}, [], "b", {"name": {"x": 1}}])
async def test_rejects_bad_upstream_switch(h: Harness, body: Any) -> None:
    r = await h.control.put("/upstream", json=body)
    assert r.status_code == 400
    assert "error" in r.json()
    assert (await h.control.get("/upstream")).json()["current"] == "a"


async def test_control_errors(h: Harness) -> None:
    assert (await h.control.get("/rules/99")).status_code == 404
    assert (await h.control.get("/nope")).status_code == 404
    r = await h.control.post("/rules", content=b"{not json")
    assert r.status_code == 400
    assert (await h.control.get("/health")).json() == {"ok": True}


# --- wire format, over raw sockets ---------------------------------------------------


async def read_response(
    reader: asyncio.StreamReader, method: str = "GET"
) -> tuple[int, dict[str, str], bytes]:
    """One response off a raw connection, framed by Content-Length (as the proxy writes them)."""
    head = (await reader.readuntil(b"\r\n\r\n")).decode("latin-1")
    start, *lines = head[:-4].split("\r\n")
    headers = {k.lower(): v.strip() for k, _, v in (line.partition(":") for line in lines)}
    status = int(start.split(" ")[1])
    no_body = method == "HEAD" or status in (204, 304) or status < 200
    length = 0 if no_body else int(headers.get("content-length", "0"))
    return status, headers, await reader.readexactly(length)


async def raw(h: Harness) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    return await asyncio.open_connection("127.0.0.1", h.proxy.port)


async def test_raw_keep_alive_sequence_stays_in_sync(h: Harness) -> None:
    """GET, HEAD, 204, 304, synthetic HEAD, GET on one connection: no stray body bytes."""
    await h.rule(method="HEAD", path="/injected", action="status", status=503)
    reader, writer = await raw(h)
    steps = [
        ("GET", "/x", 200),
        ("HEAD", "/x", 200),
        ("GET", "/nocontent", 204),
        ("GET", "/not-modified", 304),
        ("HEAD", "/injected", 503),
        ("GET", "/x", 200),
    ]
    for method, path, want in steps:
        writer.write(f"{method} {path} HTTP/1.1\r\nHost: t\r\n\r\n".encode())
        await writer.drain()
        status, headers, body = await read_response(reader, method)
        assert status == want, (method, path)
        if method == "HEAD":
            assert int(headers["content-length"]) > 0  # the length a GET would have had
        if path == "/nocontent":
            assert "content-length" not in headers
        if path == "/not-modified":
            assert headers["content-length"] == "42"
            assert headers["etag"] == '"v1"'
        if (method, path) == ("GET", "/x"):
            assert json.loads(body)["server"] == "server-a"
    writer.close()
    assert [m for m, _, _ in h.a.requests] == ["GET", "HEAD", "GET", "GET", "GET"]


async def test_raw_two_requests_with_bodies_on_one_connection(h: Harness) -> None:
    reader, writer = await raw(h)
    for n in (1, 2):
        body = json.dumps({"n": n}).encode()
        writer.write(
            b"POST /api/v1/topics/t/entries HTTP/1.1\r\nHost: t\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
            + body
        )
        await writer.drain()
        status, _, resp = await read_response(reader)
        assert status == 201
        assert json.loads(resp)["echo"] == body.decode()
    writer.close()


async def test_skips_interim_responses(h: Harness) -> None:
    r = await h.client.get("/early-hints")
    assert (r.status_code, r.text) == (200, "final")


async def test_hop_by_hop_headers_are_dropped_both_ways(h: Harness) -> None:
    r = await h.client.get(
        "/x",
        headers={
            "Connection": "X-Secret, keep-alive",
            "X-Secret": "1",
            "Keep-Alive": "timeout=5",
            "Proxy-Authorization": "Basic eA==",
            "If-None-Match": '"v1"',
            "If-Match": '"v2"',
            "X-QuickR-Expect-Server-Id": "server-a",
            "X-QuickR-Expect-Epoch": "epoch-1",
        },
    )
    seen = r.json()["headers"]
    assert {"x-secret", "keep-alive", "proxy-authorization"}.isdisjoint(seen)
    assert seen["connection"] == "close"  # the proxy's own, to the upstream
    assert seen["if-none-match"] == '"v1"'
    assert seen["if-match"] == '"v2"'
    assert seen["x-quickr-expect-server-id"] == "server-a"
    assert seen["x-quickr-expect-epoch"] == "epoch-1"

    r = await h.client.get("/hop")
    assert r.text == "ok"
    assert "x-up-secret" not in r.headers
    assert "keep-alive" not in r.headers
    assert r.headers["etag"] == '"v1"'
    assert r.headers["x-quickr-server-id"] == "server-a"
    assert r.headers["x-quickr-epoch"] == "epoch-1"


@pytest.mark.parametrize("path", ["/bad-chunk", "/bad-chunk-size", "/bad-length"])
async def test_bad_upstream_framing_is_a_502(h: Harness, path: str) -> None:
    r = await h.client.get(path)
    assert r.status_code == 502
    assert (await h.log())[-1]["upstream_status"] is None


async def test_upstream_body_cap(h: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(faultproxy, "MAX_BODY", 100)
    assert (await h.client.get("/big")).status_code == 502


@pytest.mark.parametrize(
    "request_bytes",
    [
        b"POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
        b"POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        b"POST /x HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        b"POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
        b"NONSENSE\r\n\r\n",
    ],
)
async def test_bad_client_framing_closes_the_connection(h: Harness, request_bytes: bytes) -> None:
    reader, writer = await raw(h)
    writer.write(request_bytes)
    await writer.drain()
    assert await reader.read() == b""  # closed, no response, no crash
    writer.close()
    assert h.a.requests == []
    assert (await h.client.get("/x")).status_code == 200


async def test_client_body_cap(h: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(faultproxy, "MAX_BODY", 10)
    with pytest.raises(httpx.TransportError):
        await h.client.post("/x", content=b"y" * 100)
    assert h.a.requests == []


@pytest.mark.parametrize("status", [200, 204, 304, 429, 503, 599])
async def test_every_accepted_synthetic_status_gets_a_final_response(h: Harness, status: int) -> None:
    await h.rule(action="status", status=status, retry_after="5", content_type="text/plain")
    reader, writer = await raw(h)
    try:
        writer.write(b"GET /x HTTP/1.1\r\nHost: t\r\n\r\nGET /x HTTP/1.1\r\nHost: t\r\n\r\n")
        await writer.drain()
        got, headers, _ = await read_response(reader)
        assert (got, headers["retry-after"]) == (status, "5")
        got, _, body = await read_response(reader)  # the connection is still in sync
        assert (got, json.loads(body)["server"]) == (200, "server-a")
    finally:
        writer.close()
