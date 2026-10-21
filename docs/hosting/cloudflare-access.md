# quickR behind Cloudflare Access

Cloudflare Access can put a sign-in in front of a self-hosted quickR without
opening a port. Each client signs in differently:

| Client                | How it gets past Access                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------- |
| The PWA, in a browser | You sign in through the identity provider (an **Allow** policy). Access sets a `CF_Authorization` cookie |
| The iOS app           | A **service token**, sent as two headers on every request (a **Service Auth** policy)                    |
| MCP clients           | Their own service token, on a separate application for `/mcp` (section 5)                                |

Every value below is a placeholder. The dashboard names were current when this
was written; Cloudflare moves things around now and then.

## 1. The tunnel

In Cloudflare Zero Trust, go to **Networks ▸ Tunnels**, create a tunnel, and run
`cloudflared` on the machine that runs `make up`. Add a public hostname for it:

| Field    | Value                                                     |
| -------- | --------------------------------------------------------- |
| Hostname | `quickr.example.com`                                      |
| Service  | `http://localhost:8080`, the web origin, not the API port |

The web origin serves the PWA and proxies `/api/` and `/mcp/`, so one hostname
covers every client.

## 2. The Access application

Go to **Access ▸ Applications ▸ Add an application ▸ Self-hosted**, and set the
domain to `quickr.example.com` with no path. Give it two policies:

| Policy  | Action           | Include                                                      |
| ------- | ---------------- | ------------------------------------------------------------ |
| You     | **Allow**        | Emails: `you@example.com`, or your identity provider's group |
| iOS app | **Service Auth** | Service Token: `quickr-ios` (the token from step 3)          |

The service token needs a policy whose action is **Service Auth**. Under an
Allow policy, Access sends even a valid token to the login page.

Leave **strict service-token authentication** off for this application. In
strict mode, Access ignores Allow policies, so the PWA couldn't sign in. The app
doesn't need strict mode. Without a valid token, Access answers with a `302` to
its login page, and the app reads that as "something answered, but it isn't
quickR" and offers to add a token. In strict mode the answer is `401` or `403`
instead, and the app reads that as "access refused, check the token". Both cases
are tested (section 6).

## 3. A service token for the app

1. Go to **Access ▸ Service auth ▸ Service Tokens ▸ Create Service Token**, and
   name it `quickr-ios`.
2. Choose a duration. A non-expiring token avoids a surprise lockout. If you
   pick an expiry, put a reminder in your calendar.
3. Copy the **Client ID** (`<client-id>.access`) and the **Client Secret**. The
   secret is shown **once**. Paste it straight into the app, or into your
   password manager, and nowhere else: not a note, not a chat, not the repo.
4. Add the token to the application's **Service Auth** policy (section 2).

### Strict mode

Strict mode only makes sense on an application that no browser uses, such as
`/mcp` (section 5). For the main application, see section 2.

## 4. In the app

Go to **Settings ▸ Change server…**, or use onboarding:

1. Enter the address: `https://quickr.example.com`.
2. Under **Cloudflare Access token**, enter the Client ID and the Client Secret.
3. Tap **Connect**.

Where the token lives, and how it's sent:

- It's stored only in the **Keychain**: never in `UserDefaults`, app settings,
  logs or backups.
  - It's readable after the first unlock, so background sync, the widget and
    notification actions can use it while the phone is locked.
  - It's `ThisDeviceOnly`, so it never syncs to iCloud or moves to another
    phone. A new phone needs the token entered again.
  - It's in the shared Keychain access group (`<team-id>.com.bahumia.quickr.shared`), so
    the widget and the notification service extension read the same item.
- It's kept **per server**. Each request carries the token of the server it's
  going to, so switching servers never sends one server's secret to another.
- It's sent as `CF-Access-Client-Id` and `CF-Access-Client-Secret` on **every**
  request. The app keeps no cookies, so a revoked token stops working on the
  very next request.
- Requests, errors and logs show the headers redacted.

**Settings ▸ Cloudflare Access** shows the Client ID, never the secret, and has
**Replace token…** and **Remove token**.

### Rotating or revoking the token

1. Create a new token and add it to the Service Auth policy, next to the old
   one.
2. In the app, use **Replace token…** to save the new one.
3. Remove the old token from the policy, then delete it.

If you revoke the token first instead, the app's writes wait in its outbox. They
aren't lost and aren't marked as failed. Once you save the new token and tap
Retry (or the next sync runs), they're sent, each one exactly once. The
integration test in section 6 checks this.

## 5. MCP

MCP clients aren't browsers, so give `/mcp` an application of its own. Add a
self-hosted application for `quickr.example.com` with the path `mcp`. A more
specific path takes precedence over the hostname's application, and it covers
everything under `/mcp/`.

1. Give it one **Service Auth** policy with its own token, `quickr-mcp`.
   - Keep it separate from the app's token, so either one can be revoked alone.
   - Strict service-token authentication can be on here.
2. Point the client at it with the two headers:

   ```bash
   claude mcp add --transport http quickr https://quickr.example.com/mcp/ \
     --header "CF-Access-Client-Id: <client-id>.access" \
     --header "CF-Access-Client-Secret: <client-secret>"
   ```

   The command stores the secret in the client's own config file, so treat that
   file as a secret.

## 6. Checking it end to end

### Automated, against the local stack

`make ios-integration` includes an **Access** suite
(`ios/QuickrKit/Tests/QuickrDataIntegrationTests/AccessIntegrationTests.swift`).
In that suite, the fault proxy's `access` rule stands in for Access. It forwards
a request only when the rule's `CF-Access-Client-Id` and `-Secret` are present,
and swaps them for a (fake) `Cf-Access-Jwt-Assertion`. Otherwise it refuses the
request the way Access does: with a `302` to a `cloudflareaccess.com` login
page, or with `401` or `403` in strict mode.

The suite checks that:

- the server probe, through the real `URLSession` transport, doesn't follow the
  redirect, and reads it as "not quickR, add a token";
- strict mode's `401` and `403` read as "access refused";
- with the token from the Keychain, onboarding connects and a log reaches the
  server;
- with the token revoked at the gate, the log waits in the outbox, unfailed and
  never reaching quickR;
- once the new token is saved, the log is sent exactly once.

### Manual, through the real tunnel

The automated suite can't cover:

- Cloudflare's TLS;
- the hostname and path matching;
- your policies and the token's expiry.

Check those manually, from any machine. Read the secret without echoing it, so
it stays out of your shell history:

```bash
HOST=https://quickr.example.com
read -r  CF_ID     # <client-id>.access
read -rs CF_SECRET
curl -si "$HOST/api/v1/changes?after=0&limit=1" | head -1                 # 302 (403 in strict mode)
curl -si "$HOST/api/v1/changes?after=0&limit=1" \
  -H "CF-Access-Client-Id: $CF_ID" -H "CF-Access-Client-Secret: $CF_SECRET" \
  | grep -i '^HTTP\|^x-quickr-server-id'                                  # 200 and the server id
unset CF_SECRET
```

Then finish the check in the app, on the phone:

1. Connect with the token.
2. Log an entry, and check that it shows up in the PWA.
3. Turn on flight mode, log another entry, turn flight mode off, and check that
   it's sent.

## 7. Universal links (AASA)

The app doesn't use universal links today. If it ever does, iOS fetches
`https://quickr.example.com/.well-known/apple-app-site-association` through
Apple's CDN, with no token. Access would answer that request with its login
page, and the links would silently not work. Add a self-hosted application for
the path `.well-known/apple-app-site-association`, with one policy whose action
is **Bypass** and whose include is **Everyone**.
