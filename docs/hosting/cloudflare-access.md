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

What the app sees without a valid token depends on **strict service-token
authentication** (section 3, "Strict mode"):

| Request                           | Strict off              | Strict on               | The app says                                                                  |
| --------------------------------- | ----------------------- | ----------------------- | ----------------------------------------------------------------------------- |
| No token headers                  | `302` to the login page | `302` to the login page | "Something answered, but it isn't quickR", plus the token field               |
| A wrong, revoked or expired token | `302` to the login page | `401` or `403`          | Strict off: as above. Strict on: "The server refused access", check the token |
| A valid token                     | Forwarded to quickR     | Forwarded to quickR     | Connects                                                                      |

The app follows no redirects and keeps no cookies, so either way it never
mistakes the login page for quickR. Every case is tested: the `302` and `403` cases
in section 6, and `401` by a unit test.

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

Strict service-token authentication is an **organisation-wide** Zero Trust
setting, not a per-application one. It changes only requests that carry
service-token headers:

- Only Service Auth policies can let such a request through.
- A failure is a `401` or `403` instead of a `302`.
- No `CF_Authorization` cookie is issued.

Requests without the headers, such as your browser signing in to the PWA, still
go through the Allow policy and the login page as before.

Organisations created on or after 2026-10-05 have it **on**, and it can't be
turned off. Cloudflare recommends that older organisations turn it on too. Do
that: a mistyped or revoked token then shows up in the app as "access refused,
check the token" rather than as a login page.

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
- **Password AutoFill** can fill the two fields from the Passwords app or a
  password manager, and offers to save a token typed by hand (section 7). That
  copy is yours, and quickR's own copy is still only the Keychain item above.

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
2. Point the client at it with the two headers:

   ```bash
   claude mcp add --transport http quickr https://quickr.example.com/mcp/ \
     --header "CF-Access-Client-Id: <client-id>.access" \
     --header "CF-Access-Client-Secret: <client-secret>"
   ```

   The command puts the secret in your shell history and, while it runs, in its
   arguments (visible to other users with `ps`), and the client stores it in its
   own config file, so treat that file as a secret. Prefer adding the two headers
   to the client's config file in an editor; if you use the command, delete it
   from your history afterwards.

## 6. Checking it end to end

### Automated, against the local stack

`make ios-integration` includes an **Access** suite
(`ios/QuickrKit/Tests/QuickrDataIntegrationTests/AccessIntegrationTests.swift`).
In that suite, the fault proxy's `access` rule stands in for Access. It forwards
a request only when the rule's `CF-Access-Client-Id` and `-Secret` are present,
and swaps them for a (fake) `Cf-Access-Jwt-Assertion`. Otherwise it refuses the
request the way Access does. A request without the headers gets a `302` to a
`cloudflareaccess.com` login page. One with a wrong token also gets the `302`,
or a `403` in strict mode.

The suite checks that:

- the server probe, through the real `URLSession` transport, doesn't follow the
  redirect, and reads it as "not quickR, add a token";
- in strict mode, a wrong token's `403` reads as "access refused", while no
  token still gets the login page;
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

Check those manually, from any machine. The secret stays out of your shell
history (read without echoing) and out of the process list (`ps` shows every
command's arguments, so it never goes on curl's command line: curl reads the
headers from its standard input, written by the shell's built-in `printf`):

```bash
HOST=https://quickr.example.com
read -r  CF_ID     # <client-id>.access
read -rs CF_SECRET
curl -si "$HOST/api/v1/changes?after=0&limit=1" | head -1                 # 302 (no token, either mode)
printf 'header = "CF-Access-Client-Id: %s"\nheader = "CF-Access-Client-Secret: %s"\n' \
  "$CF_ID" "$CF_SECRET" \
  | curl -si --config - "$HOST/api/v1/changes?after=0&limit=1" \
  | grep -i '^HTTP\|^x-quickr-server-id'                                  # 200 and the server id
unset CF_SECRET
```

(Cloudflare's client IDs and secrets contain no quotes or backslashes, so they
need no escaping inside curl's config syntax.)

Then finish the check in the app, on the phone:

1. Connect with the token.
2. Log an entry, and check that it shows up in the PWA.
3. Turn on flight mode, log another entry, turn flight mode off, and check that
   it's sent.

## 7. Password AutoFill (AASA bypass, required)

The app's token fields are labelled for Password AutoFill (the Client ID as the
username, the Secret as the password), so iOS's Passwords app or a password
manager such as 1Password can fill them, and offer to save a token typed by hand.
That works only if iOS can confirm the app belongs to the domain:

- The app's entitlement is `webcredentials:quickr.bahumia.com`, and **only that
  domain**. A server on another domain gets no AutoFill unless the entitlement
  (`ios/project.yml`) and a rebuild change it. Typing the token by hand always
  works.
- The web origin serves
  `https://quickr.bahumia.com/.well-known/apple-app-site-association`, which
  is `frontend/public/.well-known/apple-app-site-association`, served by nginx
  as `application/json` with status 200 and no redirect. CI's docker smoke test
  checks it.
- Apple fetches that file through its CDN, **with no token**. Behind Access, the
  fetch gets the login redirect, the association fails silently, and AutoFill
  never offers or fills the token.

So add a **Bypass** for exactly that path: a self-hosted application for
`quickr.bahumia.com` with the path `.well-known/apple-app-site-association`,
and one policy whose action is **Bypass** and whose include is **Everyone**. As
a more specific path, it takes precedence over the hostname's application. The
infrastructure-as-code setup adds this application. Check it from any machine:

```bash
curl -sI https://quickr.bahumia.com/.well-known/apple-app-site-association
# HTTP/2 200, content-type: application/json, and no location header
curl -s https://app-site-association.cdn-apple.com/a/v1/quickr.bahumia.com
# Apple's cached copy: {"webcredentials":{"apps":["J26MC29Z55.com.bahumia.quickr"]}}
```

Apple's CDN can take a while to pick up a change. A development build can skip
it: append `?mode=developer` to the entitlement's domain, and turn on Settings ▸
Developer ▸ Associated Domains Development on the phone.

The app doesn't use universal links (`applinks`). If it ever does, the same
bypass covers them.
