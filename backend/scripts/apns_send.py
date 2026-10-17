"""Send one APNs notification straight to a device token (manual debugging).

Uses the server's APNs settings (``QUICKR_APNS_*``) and never touches the database:

    uv run python scripts/apns_send.py --token <hex> --env sandbox [--title ... --body ...]

The app logs its token on registration, and Settings shows it. Prints Apple's
``apns-id`` on success, or the APNs status and reason on failure.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from app.config import get_settings
from app.services.push.apns import ApnsConfig, ApnsSender
from app.services.push.base import Notification, PushFailed, PushGone


async def main(args: argparse.Namespace) -> int:
    config = ApnsConfig.from_settings(get_settings())
    if config is None:
        print(
            "APNs is not configured: set QUICKR_APNS_TEAM_ID, QUICKR_APNS_KEY_ID and a key", file=sys.stderr
        )
        return 2
    sender = ApnsSender(config)
    n = Notification(kind="test", title=args.title, body=args.body, url="/", tag="test")
    try:
        apns_id = await sender.post(args.token.lower(), args.env, n, ttl=3600)
    except PushGone as exc:
        print(f"gone (the server would delete this device): {exc}", file=sys.stderr)
        return 1
    except PushFailed as exc:
        print(f"failed: {exc}", file=sys.stderr)
        return 1
    finally:
        await sender.aclose()
    print(f"sent to {args.env} (topic {config.topic}): apns-id {apns_id}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--token", required=True, help="the device token (hex)")
    parser.add_argument("--env", required=True, choices=["sandbox", "production"])
    parser.add_argument("--title", default="quickR")
    parser.add_argument("--body", default="Test notification from apns_send.py")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    sys.exit(asyncio.run(main(parser.parse_args())))
