# Hosting quickR for the iOS app

quickR is one backend (FastAPI and Postgres) behind one web origin (nginx, which
serves the PWA and proxies `/api/` and `/mcp/` to the backend). The iOS app, the
PWA and MCP clients all talk to that origin. The app needs nothing the PWA
doesn't, apart from two optional things: APNs for push, and a Cloudflare Access
service token when the origin is behind Cloudflare Access.

| Page                                         | What it covers                                                                                     |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| [backend.md](backend.md)                     | Running the stack, and the address the app connects to: on the LAN, or through a Cloudflare tunnel |
| [apns.md](apns.md)                           | Push to the app: the `.p8` key, mounted through the gitignored compose override                    |
| [cloudflare-access.md](cloudflare-access.md) | Access in front of quickR: the app's service token (kept in the Keychain), `/mcp`, the AASA bypass |

Secrets never go in the repo. Every id, key and secret in these pages is a
placeholder, such as `ABCDE12345` or `<client-id>.access`.

## Checklist: the steps only you can do

These need your accounts, your devices or the Cloudflare dashboard, so no agent
can do them for you. Each one links to the page that explains it.

**On the LAN (development and the device checkpoint)**

- [ ] Run the stack on the Mac with `make up`
      ([backend.md](backend.md#on-the-lan)).
- [ ] Find the Mac's LAN address. On the iPhone, open `http://<mac>.local:8080`
      in Safari once to check that it's reachable.
- [ ] In the app, enter `http://<mac>.local:8080` as the server address, and
      allow **Local Network** access when iOS asks.

**Push (H6)**

- [ ] Create an APNs key in the Apple Developer portal, download the `.p8` file,
      and note its Key ID and your Team ID
      ([apns.md](apns.md#1-create-the-key)).
- [ ] Copy `docker-compose.override.yml.example` to
      `docker-compose.override.yml` and fill in the ids and the key's path
      ([apns.md](apns.md#2-mount-it)).
- [ ] Run `make up`, and check that `GET /api/v1/push/config` says
      `"apns_enabled": true`.
- [ ] In the app, go to **Settings ▸ Reminders ▸ Test this device**, and check
      that the notification arrives.

**Cloudflare (H8)**

- [ ] Create a tunnel whose public hostname points at the web origin,
      `http://localhost:8080`
      ([cloudflare-access.md](cloudflare-access.md#1-the-tunnel)).
- [ ] Create a self-hosted Access application for the hostname, with an
      **Allow** policy for you in a browser
      ([§2](cloudflare-access.md#2-the-access-application)).
- [ ] Create a service token for the app, copying its secret right away because
      it's shown once, then add a **Service Auth** policy that includes it
      ([§3](cloudflare-access.md#3-a-service-token-for-the-app)).
- [ ] Create a separate Access application for `/mcp` with its own service token
      ([§5](cloudflare-access.md#5-mcp)).
- [ ] Check that **strict service-token authentication** is on (Zero Trust ▸
      Settings; it's on, and can't be turned off, for organisations created on or after
      2026-10-05) ([§3](cloudflare-access.md#strict-mode)).
- [ ] In the app, enter `https://<hostname>` and add the service token under
      **Cloudflare Access token**. Log an entry, then check that it shows up in
      the PWA ([§4](cloudflare-access.md#4-in-the-app)).
- [ ] Run the manual end-to-end check through the real tunnel
      ([§6](cloudflare-access.md#6-checking-it-end-to-end)). Everything apart
      from Cloudflare itself is covered by `make ios-integration`.
- [ ] Only if universal links are ever added: add a **Bypass** application for
      `/.well-known/apple-app-site-association`
      ([§7](cloudflare-access.md#7-universal-links-aasa)).
