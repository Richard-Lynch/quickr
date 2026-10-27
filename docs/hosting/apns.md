# Push to the iOS app (APNs)

APNs is **off** until it's configured. `GET /api/v1/push/config` reports
`"apns_enabled": false`. Devices can still register while it's off, but nothing
is sent to them. The backend's side is documented in the
[README](../../README.md#apns-the-ios-app). This page covers the hosting part:
getting the key into the container without putting it in the repo.

## 1. Create the key

In the Apple Developer portal:

1. Go to **Certificates, Identifiers & Profiles ▸ Keys ▸ +**.
2. Tick **Apple Push Notifications service (APNs)**, and enable it for **Sandbox
   & Production**.
3. Download `AuthKey_<KEYID>.p8`. It can only be downloaded **once**.
4. Note the key's **Key ID** and your **Team ID** (shown under Membership).

Keep the file outside the repo, for example in `~/secrets/` with `chmod 644`.
The container runs as uid 10001 and has to be able to read it.

A debug build from Xcode registers as `sandbox`. TestFlight and App Store builds
register as `production`. One key that's enabled for both serves both
environments. If your key is limited to production, add a sandbox key as well,
with `QUICKR_APNS_SANDBOX_KEY_ID` and `QUICKR_APNS_SANDBOX_PRIVATE_KEY_FILE`.

## 2. Mount it

```bash
cp docker-compose.override.yml.example docker-compose.override.yml   # gitignored
```

Fill it in. Placeholders are shown here:

```yaml
services:
  backend:
    environment:
      QUICKR_APNS_TEAM_ID: ABCDE12345
      QUICKR_APNS_KEY_ID: FGHIJ67890
      QUICKR_APNS_PRIVATE_KEY_FILE: /run/secrets/apns.p8
      # QUICKR_APNS_TOPIC: com.bahumia.quickr   # only if the bundle id differs
    volumes:
      - ~/secrets/AuthKey_FGHIJ67890.p8:/run/secrets/apns.p8:ro
```

`docker compose` merges the override automatically, so `make up` picks it up.
The key is mounted read-only, and it never enters the image, the repo or an
environment variable.

## 3. Check it

```bash
make up
curl -s http://localhost:8080/api/v1/push/config     # {"public_key": "...", "apns_enabled": true}
docker compose logs backend | grep -i apns           # a key that can't be loaded is logged here
```

Then, in the app, go to **Settings ▸ Reminders ▸ Test this device**. A
notification should arrive within seconds.

| What you see                                | What it means                                                                                                               |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `apns_enabled: false` after a restart       | One of the team id, the key id or the key is missing, or the key couldn't be read. Check the logs and the file permissions  |
| `409 apns_disabled` from Test this device   | The same thing: APNs is off on this server                                                                                  |
| `DeviceTokenNotForTopic` in the logs        | `QUICKR_APNS_TOPIC` doesn't match the app's bundle id                                                                       |
| Nothing arrives, and the logs show no error | The device registered in the other environment: a debug build is `sandbox`. Check the key covers it, or add the sandbox key |

To send to a token directly, without the scheduler:
`cd backend && uv run python scripts/apns_send.py --token <hex token> --env sandbox`.
To send a topic's real reminder now, with its category and actions:
`make send-reminder-docker t=<slug>` (see the README's push section).

## Live Activities (timed topics)

The timed-topics Live Activity uses the same APNs setup. There is nothing extra
to configure:

- **Topic.** Keep `QUICKR_APNS_TOPIC` the bare bundle id (`com.bahumia.quickr`).
  The server derives the Live Activity topic itself: it sends with
  `apns-push-type: liveactivity` on `<QUICKR_APNS_TOPIC>.push-type.liveactivity`.
  Don't put the suffix in the variable; reminders would then fail with
  `DeviceTokenNotForTopic`.
- **Key.** The same `.p8` key signs Live Activity pushes. No separate key or
  certificate is needed.
- **Environment.** Each Live Activity token is registered with its build's
  environment, as device tokens are. A TestFlight or App Store build registers
  `production`, so the key must be valid for production, or push-to-start and
  remote updates never reach the phone (local updates from the phone's own taps
  still work).
- **APNs off.** With APNs off, the server sends no Live Activity pushes. A run
  started on the PWA or by MCP then gets no activity on the phone (the app only
  requests one for a run it starts itself), and an activity isn't updated by
  another device's taps until the app next opens and reconciles it.

## Rotating or revoking the key

1. Create a new key and point the override at it.
2. Run `make up`.
3. Then revoke the old key in the portal.

Device tokens don't change when the key does, so the app doesn't need to do
anything.
