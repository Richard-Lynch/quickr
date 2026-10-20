"""Fault-injecting HTTP reverse proxy for the iOS integration tests.

Sits between the app under test and a backend, passing requests through until a test
installs a rule that makes one misbehave: drop the response after the backend has
committed, garble a 2xx body, answer with a captive-portal page, delay or hold a request,
answer 503/429 without reaching the backend, or strip the identity headers. The proxy
can also be re-pointed at another named upstream, so "the same URL now reaches a
different server" is one control call.

Standard library only, so it runs from the backend image without extra dependencies::

    python tools/faultproxy.py --listen 0.0.0.0:8080 --control 0.0.0.0:8081 \\
        --upstream a=http://backend-a:8000 --upstream b=http://backend-b:8000

The control API (JSON, on its own port) is documented in ios/README.md
("Integration tests"). HTTP/1.1 only, bodies buffered, plain http upstreams.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import fnmatch
import json
import logging
import re
import time
from collections.abc import Iterable
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from typing import Any
from urllib.parse import urlsplit

log = logging.getLogger("faultproxy")

HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)
# Recomputed by the proxy for every message it writes (bodies are buffered and de-chunked).
FRAMING = frozenset({"content-length", "transfer-encoding"})
IDENTITY_HEADERS = frozenset({"x-quickr-server-id", "x-quickr-epoch"})

ACTIONS = frozenset(
    {
        "pass",  # forward unchanged (useful as a counted no-op)
        "delay",  # sleep delay_ms, before forwarding (phase=request) or before replying (phase=response)
        "hold",  # park the request before forwarding until the rule is released
        "drop_request",  # close the client connection without forwarding
        "drop_response",  # forward, let the backend commit, then reset the client connection
        "garble",  # forward, then corrupt a 2xx body (see GARBLE_MODES)
        "captive",  # answer 200 text/html without forwarding
        "status",  # answer `status` (503 by default) without forwarding
        "strip_identity",  # forward, then remove X-QuickR-Server-Id / X-QuickR-Epoch
    }
)
GARBLE_MODES = frozenset({"truncate", "drop_field", "not_json", "empty"})
PHASES = frozenset({"request", "response"})

CAPTIVE_PAGE = (
    "<!doctype html><html><head><title>Sign in to Wi-Fi</title></head>"
    "<body><h1>Welcome</h1><p>Accept the terms to continue.</p></body></html>"
)
REASONS = {
    200: "OK",
    201: "Created",
    204: "No Content",
    400: "Bad Request",
    404: "Not Found",
    409: "Conflict",
    429: "Too Many Requests",
    500: "Internal Server Error",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout",
}
MAX_HEAD = 64 * 1024  # start line + headers, and any single chunk-size or trailer line
MAX_BODY = 16 * 1024 * 1024
MAX_TRAILERS = 16 * 1024
UPSTREAM_TIMEOUT = 60.0
CLIENT_TIMEOUT = 300.0  # to read one whole request, including keep-alive idle time
MAX_DELAY_MS = 10 * 60 * 1000

CONTENT_LENGTH = re.compile(r"[0-9]{1,12}")
CHUNK_SIZE = re.compile(rb"[0-9A-Fa-f]{1,12}")
STATUS_LINE = re.compile(r"HTTP/1\.[01] ([0-9]{3})(?: (.*))?")
METHOD = re.compile(r"\*|[A-Za-z]+")
HEADER_VALUE = re.compile(r"[\x20-\x7e]*")  # what a rule may put in a response header

Headers = list[tuple[str, str]]


class BadMessage(Exception):
    """The peer sent something that isn't the HTTP/1.x this proxy understands."""


def header(headers: Headers, name: str) -> str | None:
    name = name.lower()
    return next((v for k, v in headers if k.lower() == name), None)


def tokens(headers: Headers, name: str) -> list[str]:
    """The comma-separated tokens of every ``name`` header, lowercased."""
    name = name.lower()
    return [t.strip().lower() for k, v in headers if k.lower() == name for t in v.split(",") if t.strip()]


def end_to_end(headers: Headers, drop: Iterable[str] = ()) -> Headers:
    """``headers`` without hop-by-hop ones (the fixed set and every header the Connection
    header names) and without framing headers, which the proxy writes itself."""
    excluded = HOP_BY_HOP | FRAMING | set(tokens(headers, "connection")) | set(drop)
    return [(k, v) for k, v in headers if k.lower() not in excluded]


def has_body(method: str, status: int) -> bool:
    return method != "HEAD" and status >= 200 and status not in (204, 304)


@dataclass
class Request:
    method: str
    target: str
    version: str
    headers: Headers
    body: bytes

    @property
    def path(self) -> str:
        return urlsplit(self.target).path or "/"

    @property
    def keep_alive(self) -> bool:
        conn = tokens(self.headers, "connection")
        if self.version == "HTTP/1.0":
            return "keep-alive" in conn
        return "close" not in conn


@dataclass
class Response:
    status: int
    headers: Headers
    body: bytes
    reason: str = ""
    # Made up by the proxy because the upstream failed (502), not the upstream's answer.
    from_proxy: bool = False

    def encode(self, *, method: str, keep_alive: bool) -> bytes:
        """The response as an answer to ``method``: no body for HEAD, 1xx, 204 and 304."""
        reason = self.reason or REASONS.get(self.status, "Unknown")
        lines = [f"HTTP/1.1 {self.status} {reason}"]
        lines += [f"{k}: {v}" for k, v in end_to_end(self.headers)]
        body = b""
        if has_body(method, self.status):
            body = self.body
            lines.append(f"Content-Length: {len(body)}")
        elif self.status >= 200 and self.status != 204:
            # HEAD and 304 carry the length the body would have had: the upstream's, or ours.
            length = header(self.headers, "content-length")
            if length is None and method == "HEAD":
                length = str(len(self.body))
            if length is not None:
                lines.append(f"Content-Length: {length}")
        lines.append(f"Connection: {'keep-alive' if keep_alive else 'close'}")
        return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body


def simple_response(
    status: int, body: str | bytes, content_type: str, extra: Headers | None = None
) -> Response:
    data = body.encode() if isinstance(body, str) else body
    return Response(status, [("Content-Type", content_type), *(extra or [])], data)


def json_response(status: int, payload: Any) -> Response:
    return simple_response(status, json.dumps(payload), "application/json")


# --- HTTP/1.x wire format ----------------------------------------------------------


async def read_head(reader: asyncio.StreamReader) -> tuple[str, Headers] | None:
    """The start line and headers, or None on a clean EOF before any byte."""
    try:
        raw = await reader.readuntil(b"\r\n\r\n")
    except asyncio.IncompleteReadError as exc:
        if not exc.partial:
            return None
        raise BadMessage("connection closed mid-head") from exc
    except asyncio.LimitOverrunError as exc:
        raise BadMessage("head too large") from exc
    start, *rest = raw[:-4].decode("latin-1").split("\r\n")
    headers: Headers = []
    for line in rest:
        name, sep, value = line.partition(":")
        if not sep:
            raise BadMessage(f"bad header line {line!r}")
        headers.append((name.strip(), value.strip()))
    return start, headers


async def read_line(reader: asyncio.StreamReader) -> bytes:
    try:
        return await reader.readuntil(b"\r\n")
    except asyncio.LimitOverrunError as exc:
        raise BadMessage("line too long") from exc


async def read_chunked(reader: asyncio.StreamReader) -> bytes:
    body = bytearray()
    while True:
        size_text = (await read_line(reader))[:-2].split(b";", 1)[0].strip()
        if not CHUNK_SIZE.fullmatch(size_text):
            raise BadMessage(f"bad chunk size {size_text!r}")
        size = int(size_text, 16)
        if size == 0:
            break
        if len(body) + size > MAX_BODY:
            raise BadMessage("body too large")
        body += await reader.readexactly(size)
        if await reader.readexactly(2) != b"\r\n":
            raise BadMessage("chunk not terminated by CRLF")
    trailers = 0
    while (line := await read_line(reader)) != b"\r\n":
        trailers += len(line)
        if trailers > MAX_TRAILERS:
            raise BadMessage("trailers too large")
    return bytes(body)


def content_length(headers: Headers) -> int | None:
    values = set(tokens(headers, "content-length"))
    if not values:
        return None
    if len(values) > 1 or not CONTENT_LENGTH.fullmatch(value := values.pop()):
        raise BadMessage(f"bad Content-Length {header(headers, 'content-length')!r}")
    if int(value) > MAX_BODY:
        raise BadMessage("body too large")
    return int(value)


async def read_body(reader: asyncio.StreamReader, headers: Headers, *, until_eof: bool) -> bytes:
    encodings = tokens(headers, "transfer-encoding")
    if encodings:
        if encodings != ["chunked"]:
            raise BadMessage(f"unsupported Transfer-Encoding {encodings}")
        return await read_chunked(reader)
    length = content_length(headers)
    if length is not None:
        return await reader.readexactly(length)
    if not until_eof:
        return b""
    body = bytearray()
    while chunk := await reader.read(64 * 1024):
        body += chunk
        if len(body) > MAX_BODY:
            raise BadMessage("body too large")
    return bytes(body)


async def read_request(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> Request | None:
    head = await read_head(reader)
    if head is None:
        return None
    start, headers = head
    parts = start.split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
        raise BadMessage(f"bad request line {start!r}")
    method, target, version = parts
    if "100-continue" in tokens(headers, "expect"):
        writer.write(b"HTTP/1.1 100 Continue\r\n\r\n")
        await writer.drain()
    body = await read_body(reader, headers, until_eof=False)
    return Request(method.upper(), target, version, headers, body)


# --- rules -------------------------------------------------------------------------


@dataclass
class Rule:
    id: int
    action: str
    method: str = "*"
    path: str = "*"
    sticky: bool = False
    times: int = 1
    delay_ms: int = 0
    phase: str = "request"
    status: int = 503
    body: str | None = None
    content_type: str | None = None
    retry_after: str | None = None
    garble: str = "truncate"
    field: str = "revision"
    hits: int = 0
    waiting: int = 0
    released: asyncio.Event = dataclass_field(default_factory=asyncio.Event)

    FIELDS = frozenset(
        {
            "action",
            "method",
            "path",
            "sticky",
            "times",
            "delay_ms",
            "phase",
            "status",
            "body",
            "content_type",
            "retry_after",
            "garble",
            "field",
        }
    )

    INT_FIELDS = frozenset({"times", "delay_ms", "status"})
    OPTIONAL_STR_FIELDS = frozenset({"body", "content_type", "retry_after"})
    HEADER_VALUE_FIELDS = frozenset({"content_type", "retry_after"})

    @classmethod
    def from_json(cls, rule_id: int, data: Any) -> Rule:
        """A rule from control-API JSON. Raises ValueError, never anything else, if invalid."""
        if not isinstance(data, dict):
            raise ValueError("rule must be a JSON object")
        unknown = set(data) - cls.FIELDS
        if unknown:
            raise ValueError(f"unknown rule fields: {sorted(unknown)}")
        if "action" not in data:
            raise ValueError("action is required")
        for name, value in data.items():
            if name in cls.INT_FIELDS:
                ok, kind = type(value) is int, "an integer"
            elif name == "sticky":
                ok, kind = type(value) is bool, "a boolean"
            elif name in cls.OPTIONAL_STR_FIELDS:
                ok, kind = value is None or isinstance(value, str), "a string or null"
            else:
                ok, kind = isinstance(value, str), "a string"
            if not ok:
                raise ValueError(f"{name} must be {kind}")
            if name in cls.HEADER_VALUE_FIELDS and value is not None and not HEADER_VALUE.fullmatch(value):
                raise ValueError(f"{name} must be printable ASCII (no CR, LF or other controls)")
        rule = cls(id=rule_id, **data)
        if not METHOD.fullmatch(rule.method):
            raise ValueError("method must be '*' or an HTTP method")
        rule.method = rule.method.upper()
        if rule.action not in ACTIONS:
            raise ValueError(f"action must be one of {sorted(ACTIONS)}")
        if rule.garble not in GARBLE_MODES:
            raise ValueError(f"garble must be one of {sorted(GARBLE_MODES)}")
        if rule.phase not in PHASES:
            raise ValueError(f"phase must be one of {sorted(PHASES)}")
        if rule.times < 1:
            raise ValueError("times must be >= 1")
        if not 0 <= rule.delay_ms <= MAX_DELAY_MS:
            raise ValueError(f"delay_ms must be in 0..{MAX_DELAY_MS}")
        if not 200 <= rule.status <= 599:
            # A synthetic 1xx would never be followed by a final response.
            raise ValueError("status must be a final HTTP status code (200..599)")
        return rule

    def matches(self, method: str, path: str) -> bool:
        if self.method not in ("*", method):
            return False
        return fnmatch.fnmatchcase(path, self.path)

    @property
    def exhausted(self) -> bool:
        return not self.sticky and self.hits >= self.times

    def to_json(self) -> dict[str, Any]:
        out = {name: getattr(self, name) for name in sorted(self.FIELDS)}
        return {
            "id": self.id,
            **out,
            "hits": self.hits,
            "waiting": self.waiting,
            "released": self.released.is_set(),
            "exhausted": self.exhausted,
        }


def garble_body(body: bytes, mode: str, field_name: str) -> bytes:
    if mode == "empty":
        return b""
    if mode == "not_json":
        return b"\x00garbled\xff"
    if mode == "drop_field":
        try:
            doc = json.loads(body)
        except ValueError:
            doc = None
        if isinstance(doc, dict):
            doc.pop(field_name, None)
            return json.dumps(doc).encode()
    # truncate (and drop_field on a body that isn't a JSON object)
    return body[: max(1, len(body) // 2)] if body else b"{"


# --- the proxy ---------------------------------------------------------------------


@dataclass
class Upstream:
    name: str
    host: str
    port: int

    @classmethod
    def parse(cls, spec: str) -> Upstream:
        name, sep, url = spec.partition("=")
        parts = urlsplit(url)
        if not sep or parts.scheme != "http" or not parts.hostname:
            raise ValueError(f"upstream must look like name=http://host:port, got {spec!r}")
        return cls(name, parts.hostname, parts.port or 80)

    def to_json(self) -> str:
        return f"http://{self.host}:{self.port}"


class FaultProxy:
    def __init__(self, upstreams: list[Upstream]) -> None:
        if not upstreams:
            raise ValueError("at least one upstream is required")
        self.upstreams = {u.name: u for u in upstreams}
        self.default = upstreams[0].name
        self.current = self.default
        self.rules: list[Rule] = []
        self.log: list[dict[str, Any]] = []
        self._next_rule = 1
        self._next_seq = 1
        self._servers: list[asyncio.Server] = []

    # lifecycle

    async def start(self, host: str, port: int, control_host: str, control_port: int) -> None:
        self._servers = [
            await asyncio.start_server(self._proxy_client, host, port, limit=MAX_HEAD),
            await asyncio.start_server(self._control_client, control_host, control_port, limit=MAX_HEAD),
        ]

    @property
    def port(self) -> int:
        return int(self._servers[0].sockets[0].getsockname()[1])

    @property
    def control_port(self) -> int:
        return int(self._servers[1].sockets[0].getsockname()[1])

    async def close(self) -> None:
        self.reset()
        for server in self._servers:
            server.close()
            server.close_clients()
            await server.wait_closed()

    # state

    def add_rule(self, data: Any) -> Rule:
        rule = Rule.from_json(self._next_rule, data)
        self._next_rule += 1
        self.rules.append(rule)
        return rule

    def remove_rule(self, rule: Rule) -> None:
        rule.released.set()
        self.rules.remove(rule)

    def clear_rules(self) -> None:
        for rule in list(self.rules):
            self.remove_rule(rule)

    def reset(self) -> None:
        self.clear_rules()
        self.log.clear()
        self.current = self.default

    def _take_rule(self, method: str, path: str) -> Rule | None:
        for rule in self.rules:
            if not rule.exhausted and rule.matches(method, path):
                rule.hits += 1
                return rule
        return None

    # proxying

    async def _proxy_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                req = await asyncio.wait_for(read_request(reader, writer), CLIENT_TIMEOUT)
                if req is None or not await self._serve(req, writer):
                    break
        except (BadMessage, asyncio.IncompleteReadError, ConnectionError, TimeoutError) as exc:
            log.debug("client connection ended: %r", exc)
        except Exception:
            log.exception("proxy connection failed")
        finally:
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    async def _serve(self, req: Request, writer: asyncio.StreamWriter) -> bool:
        """Answer one request. Returns whether the client connection stays open."""
        rule = self._take_rule(req.method, req.path)
        action = rule.action if rule else "pass"
        entry: dict[str, Any] = {
            "seq": self._next_seq,
            "at": time.time(),
            "method": req.method,
            "path": req.target,
            "rule": rule.id if rule else None,
            "action": action,
            "upstream": None,
            "upstream_status": None,
            "status": None,
            "state": "in_flight",
        }
        self._next_seq += 1
        self.log.append(entry)
        log.info("%s %s -> %s", req.method, req.target, action)

        if action == "drop_request":
            entry["state"] = "dropped"
            writer.transport.abort()
            return False
        if rule and action == "captive":
            return await self._reply(entry, writer, req, self._captive(rule))
        if rule and action == "status":
            return await self._reply(entry, writer, req, self._status(rule))
        if rule and action == "hold":
            entry["state"] = "held"
            rule.waiting += 1
            try:
                await rule.released.wait()
            finally:
                rule.waiting -= 1
            entry["state"] = "in_flight"
        if rule and action == "delay" and rule.phase == "request":
            await asyncio.sleep(rule.delay_ms / 1000)

        upstream = self.upstreams[self.current]
        entry["upstream"] = upstream.name
        resp = await self._forward(upstream, req)
        entry["upstream_status"] = None if resp.from_proxy else resp.status

        if action == "drop_response":
            entry["state"] = "dropped"
            writer.transport.abort()
            return False
        if rule and action == "delay" and rule.phase == "response":
            await asyncio.sleep(rule.delay_ms / 1000)
        if rule and action == "garble" and 200 <= resp.status < 300:
            resp.body = garble_body(resp.body, rule.garble, rule.field)
        if action == "strip_identity":
            resp.headers = [(k, v) for k, v in resp.headers if k.lower() not in IDENTITY_HEADERS]
        return await self._reply(entry, writer, req, resp)

    async def _reply(
        self, entry: dict[str, Any], writer: asyncio.StreamWriter, req: Request, resp: Response
    ) -> bool:
        keep_alive = req.keep_alive
        entry["status"] = resp.status
        try:
            writer.write(resp.encode(method=req.method, keep_alive=keep_alive))
            await writer.drain()
        except ConnectionError:
            # The client gave up (e.g. timed out while the request was held).
            entry["state"] = "client_gone"
            return False
        entry["state"] = "responded"
        return keep_alive

    @staticmethod
    def _captive(rule: Rule) -> Response:
        return simple_response(
            200, rule.body or CAPTIVE_PAGE, rule.content_type or "text/html; charset=utf-8"
        )

    @staticmethod
    def _status(rule: Rule) -> Response:
        extra = [("Retry-After", rule.retry_after)] if rule.retry_after is not None else []
        body = rule.body if rule.body is not None else f"{rule.status} injected by faultproxy\n"
        return simple_response(rule.status, body, rule.content_type or "text/plain; charset=utf-8", extra)

    async def _forward(self, upstream: Upstream, req: Request) -> Response:
        try:
            return await asyncio.wait_for(self._exchange(upstream, req), UPSTREAM_TIMEOUT)
        except (OSError, TimeoutError, BadMessage, asyncio.IncompleteReadError, ValueError) as exc:
            log.warning("upstream %s failed: %r", upstream.name, exc)
            resp = simple_response(
                502, f"faultproxy: upstream {upstream.name} failed: {exc!r}\n", "text/plain"
            )
            resp.from_proxy = True
            return resp

    @staticmethod
    async def _exchange(upstream: Upstream, req: Request) -> Response:
        reader, writer = await asyncio.open_connection(upstream.host, upstream.port, limit=MAX_HEAD)
        try:
            lines = [f"{req.method} {req.target} HTTP/1.1"]
            # Expect was answered by the proxy already (read_request).
            lines += [f"{k}: {v}" for k, v in end_to_end(req.headers, drop=("expect",))]
            if req.body or req.method in ("POST", "PUT", "PATCH"):
                lines.append(f"Content-Length: {len(req.body)}")
            lines.append("Connection: close")
            writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + req.body)
            await writer.drain()

            while True:
                head = await read_head(reader)
                if head is None:
                    raise BadMessage("upstream closed without a response")
                start, headers = head
                match = STATUS_LINE.fullmatch(start)
                if not match:
                    raise BadMessage(f"bad status line {start!r}")
                status = int(match[1])
                if status == 101:
                    raise BadMessage("upstream switched protocols; upgrades are not supported")
                if status >= 200:
                    break
                # Interim response (100 Continue, 103 Early Hints): the final one follows.
            body = await read_body(reader, headers, until_eof=True) if has_body(req.method, status) else b""
            return Response(status, headers, body, match[2] or "")
        finally:
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    # control API

    async def _control_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                req = await asyncio.wait_for(read_request(reader, writer), CLIENT_TIMEOUT)
                if req is None:
                    break
                try:
                    resp = self._control(req)
                except ValueError as exc:
                    resp = json_response(400, {"error": str(exc)})
                except Exception as exc:
                    log.exception("control request failed")
                    resp = json_response(500, {"error": repr(exc)})
                writer.write(resp.encode(method=req.method, keep_alive=req.keep_alive))
                await writer.drain()
                if not req.keep_alive:
                    break
        except (BadMessage, asyncio.IncompleteReadError, ConnectionError, TimeoutError) as exc:
            log.debug("control connection ended: %r", exc)
        finally:
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    def _rule_by_id(self, text: str) -> Rule | None:
        return next((r for r in self.rules if str(r.id) == text), None)

    def _control(self, req: Request) -> Response:
        parts = [p for p in req.path.split("/") if p]
        m = req.method

        def body() -> Any:
            try:
                return json.loads(req.body or b"null")
            except ValueError as exc:
                raise ValueError(f"body is not JSON: {exc}") from exc

        match parts:
            case ["health"] if m == "GET":
                return json_response(200, {"ok": True})
            case ["reset"] if m == "POST":
                self.reset()
                return json_response(200, {"ok": True})
            case ["rules"] if m == "GET":
                return json_response(200, [r.to_json() for r in self.rules])
            case ["rules"] if m == "POST":
                return json_response(201, self.add_rule(body()).to_json())
            case ["rules"] if m == "DELETE":
                self.clear_rules()
                return json_response(200, {"ok": True})
            case ["rules", rule_id, *rest]:
                rule = self._rule_by_id(rule_id)
                if rule is None:
                    return json_response(404, {"error": f"no rule {rule_id}"})
                if not rest and m == "GET":
                    return json_response(200, rule.to_json())
                if not rest and m == "DELETE":
                    self.remove_rule(rule)
                    return json_response(200, {"ok": True})
                if rest == ["release"] and m == "POST":
                    waiting = rule.waiting
                    rule.released.set()
                    return json_response(200, {**rule.to_json(), "released_now": waiting})
            case ["log"] if m == "GET":
                return json_response(200, self.log)
            case ["log"] if m == "DELETE":
                self.log.clear()
                return json_response(200, {"ok": True})
            case ["upstream"] if m == "GET":
                return json_response(200, self._upstream_json())
            case ["upstream"] if m == "PUT":
                data = body()
                name = data.get("name") if isinstance(data, dict) else None
                if not isinstance(name, str) or name not in self.upstreams:
                    raise ValueError(f"name must be one of {sorted(self.upstreams)}")
                self.current = name
                return json_response(200, self._upstream_json())
        return json_response(404, {"error": f"no route {m} {req.path}"})

    def _upstream_json(self) -> dict[str, Any]:
        return {
            "current": self.current,
            "default": self.default,
            "upstreams": {n: u.to_json() for n, u in self.upstreams.items()},
        }


def _host_port(text: str) -> tuple[str, int]:
    host, _, port = text.rpartition(":")
    return host or "127.0.0.1", int(port)


async def _main(args: argparse.Namespace) -> None:
    proxy = FaultProxy([Upstream.parse(s) for s in args.upstream])
    host, port = _host_port(args.listen)
    control_host, control_port = _host_port(args.control)
    await proxy.start(host, port, control_host, control_port)
    log.info(
        "faultproxy on %s:%d (control %s:%d) -> %s",
        host,
        proxy.port,
        control_host,
        proxy.control_port,
        {n: u.to_json() for n, u in proxy.upstreams.items()},
    )
    try:
        await asyncio.Event().wait()
    finally:
        await proxy.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--listen", default="127.0.0.1:8080", help="host:port for proxied traffic")
    parser.add_argument("--control", default="127.0.0.1:8081", help="host:port for the control API")
    parser.add_argument(
        "--upstream",
        action="append",
        required=True,
        help="name=http://host:port; repeatable, the first is the default",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s faultproxy %(message)s"
    )
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(_main(args))


if __name__ == "__main__":
    main()
