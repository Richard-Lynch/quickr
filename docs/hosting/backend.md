# Running the backend for the iOS app

The app connects to the same address you open quickR at in a browser: the web
origin. nginx there serves the PWA and passes `/api/` and `/mcp/` to the
backend. There's nothing to set up on the server side for the app. It sends
`X-QuickR-Channel: ios`, and the backend accepts that channel already.

## The stack

```bash
make up      # db, backend and web in docker; web on :8080 (API :8100, Postgres :5433)
make down
```

`docker compose` also reads `docker-compose.override.yml` when it exists. That
file is gitignored and is where machine-specific settings go, such as the APNs
key ([apns.md](apns.md)). Every other setting is a `QUICKR_*` variable, listed
in the [README](../../README.md#quick-start).

To check that it's up, and which server it is:

```bash
curl -si http://localhost:8080/api/v1/changes?after=0\&limit=1 | grep -i '^x-quickr'
# X-QuickR-Server-Id: <uuid>    one per database, never changes
# X-QuickR-Epoch: <epoch>       changes on a restore or `make rotate-epoch` (`rotate-epoch-docker` for the docker stack)
```

The app keeps **one local store per server id**. Pointing it at another
database, even at the same address, switches stores and never mixes their data.
After a restore, the app sees the new epoch and rebuilds from the server. Writes
it hasn't sent yet are kept and resent
([sync-protocol.md](../ios/specs/sync-protocol.md) §7).

## On the LAN

This is the setup for development and for the device checkpoint.

1. Run `make up` on the Mac.
2. In the app, enter `http://<mac-name>.local:8080`, or `http://<lan-ip>:8080`.
   - Plain `http` is allowed only for local addresses
     (`NSAllowsLocalNetworking`).
   - The first connection prompts for **Local Network** access. If it was
     declined, turn it back on in **Settings ▸ Privacy & Security ▸ Local
     Network ▸ quickR**.
3. If the app says it **couldn't reach the server**:
   - check that the iPhone is on the same Wi-Fi;
   - check that the Mac's firewall allows incoming connections for Docker;
   - check that `http://<mac-name>.local:8080` opens in Safari on the phone.

A simulator can use `http://localhost:8080`, because it shares the Mac's
network.

## Away from home: a Cloudflare tunnel

To reach the server from anywhere without opening a port, put the web origin
behind a Cloudflare tunnel and protect it with Cloudflare Access. The PWA, the
app and MCP then each sign in their own way.
[cloudflare-access.md](cloudflare-access.md) is the walkthrough.

## What the app needs from the server

| Need                                                | Where                                                                                              |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| The API under `/api/v1` with the identity headers   | Any quickR backend from this branch on                                                             |
| `GET /api/v1/changes` (the feed the app syncs from) | Same                                                                                               |
| Push                                                | Optional: [apns.md](apns.md). Without it, the app works, but the server can't send reminders to it |
| A service token                                     | Only behind Cloudflare Access: [cloudflare-access.md](cloudflare-access.md)                        |
