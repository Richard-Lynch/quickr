"""SSRF guard for Web Push endpoints.

The API is unauthenticated, so anyone could register a "subscription" whose
endpoint points at an internal service and have the scheduler POST to it. Two
layers prevent that:

* registration only accepts ``https://`` endpoints on known browser push
  services (extendable via ``QUICKR_PUSH_ALLOWED_HOSTS``);
* delivery re-checks the host, refuses hosts that resolve to non-global
  addresses (loopback, RFC 1918, link-local, ULA, ...), and never follows
  redirects.
"""

from __future__ import annotations

import ipaddress
import socket
from urllib.parse import urlsplit

from app.config import get_settings

# Each entry matches the host itself and any subdomain of it.
DEFAULT_PUSH_HOSTS: tuple[str, ...] = (
    "fcm.googleapis.com",  # Chrome, Edge (Chromium), Android
    "updates.push.services.mozilla.com",  # Firefox
    "push.apple.com",  # Safari / iOS home-screen apps (web.push.apple.com)
    "notify.windows.com",  # legacy Edge / Windows (WNS)
    "wns.windows.com",
)


class PushEndpointRejected(Exception):
    """The endpoint is not a URL we are willing to send to."""


def _normalise(host: str) -> str:
    return host.strip().lower().rstrip(".")


def allowed_hosts() -> tuple[str, ...]:
    extra = tuple(_normalise(h) for h in get_settings().push_allowed_hosts if h.strip())
    return DEFAULT_PUSH_HOSTS + extra


def host_allowed(host: str) -> bool:
    host = _normalise(host)
    return any(host == a or host.endswith("." + a) for a in allowed_hosts())


def check_endpoint(url: str) -> str:
    """Return the endpoint's hostname, or raise PushEndpointRejected with a human message."""
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError as exc:
        raise PushEndpointRejected("must be a valid https:// URL") from exc
    if parts.scheme != "https" or not parts.hostname:
        raise PushEndpointRejected("must be an https:// URL from the browser's push service")
    if parts.username is not None or parts.password is not None or port not in (None, 443):
        raise PushEndpointRejected("must not contain credentials or a custom port")
    if not host_allowed(parts.hostname):
        raise PushEndpointRejected(
            f"host '{parts.hostname}' is not a known push service (set QUICKR_PUSH_ALLOWED_HOSTS to allow it)"
        )
    return _normalise(parts.hostname)


def ensure_public(host: str) -> None:
    """Raise PushEndpointRejected unless every address ``host`` resolves to is globally routable."""
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
    except OSError as exc:
        raise PushEndpointRejected(f"cannot resolve '{host}'") from exc
    addresses = {info[4][0] for info in infos}
    if not addresses:
        raise PushEndpointRejected(f"cannot resolve '{host}'")
    for address in addresses:
        ip = ipaddress.ip_address(str(address).split("%", 1)[0])
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        if not ip.is_global:
            raise PushEndpointRejected(f"'{host}' resolves to a non-public address ({ip})")
