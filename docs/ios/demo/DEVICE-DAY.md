# Device day: checkpoint D, M3-DEV, M4-DEV and the M7 regression pass

Everything below runs on the user's iPhone (an iPhone 16 Pro Max on iOS 26.6.2;
STATUS H5). The code was built and tested on simulators, so this day is
validation only (DAG §1, move 1). The order is:

1. the prerequisites (§1);
2. build and install (§2);
3. **D**, which is a go/no-go gate (§3);
4. **M3-DEV** (§4) and **M4-DEV** (§5);
5. at M7, the regression pass (§7).

D, M3-DEV and M4-DEV each end in a short findings PR. Every row is ticked `[x]`,
failed `[!]` with what was seen, or skipped `[-]` with the reason. A no-go in D
waits for the user, with a proposal (PLAN §7, D).

**Privacy.** Never record or commit the phone's serial number, UDID, ECID, IMEI,
or any MAC address. Don't screen-record Settings ▸ General ▸ About, and don't
paste `devicectl` device details into a PR. The device is "the iPhone"; the
Mac's address is `<mac>.local`. Push tokens, key IDs and the Team ID are
redacted the same way as in `make ios-testflight` (last two characters only).

## 1. Prerequisites, in order

| #   | Step                                                                                                                                                                                                                                                                                                                           | Who        | Check                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ------------------------------------------------------------------------ |
| 1   | **Team ID** (H3) into `ios/Local.xcconfig`: copy `ios/Local.xcconfig.example` and set `DEVELOPMENT_TEAM`. The file is gitignored.                                                                                                                                                                                              | user/agent | `grep DEVELOPMENT_TEAM ios/Local.xcconfig` is not empty                  |
| 2   | **Xcode signed in** (H4): Xcode ▸ Settings ▸ Accounts ▸ + with the developer Apple ID. Automatic signing for device builds uses this account.                                                                                                                                                                                  | user       | The team shows under the account                                         |
| 3   | **iPhone** (H5): connect it by cable, unlock it and tap **Trust**. Turn on Settings ▸ Privacy & Security ▸ **Developer Mode**, then restart and confirm. Optionally, in Xcode ▸ Devices and Simulators, tick "Connect via network".                                                                                            | user       | `xcrun devicectl list devices` shows the iPhone as paired and available  |
| 4   | **Push entitlement.** `aps-environment` is not in `ios/project.yml` yet (ios/README.md says it lands in M3). Without it the app gets no APNs token. Before M3-DEV, add `aps-environment: development` to the **app** target's entitlements and run `make ios-gen`. Automatic signing switches it to production for TestFlight. | agent      | The installed app's Settings ▸ Reminders shows a registered device       |
| 5   | **APNs key** (H6): create the `.p8`, then mount it into the backend through the compose override, exactly as in [docs/hosting/apns.md](../../hosting/apns.md). Also set `QUICKR_SCHEDULER_INTERVAL_SECONDS: 10` there for the day, so a due reminder goes out within seconds.                                                  | user/agent | `curl -s localhost:8080/api/v1/push/config` shows `"apns_enabled": true` |
| 6   | **A server the phone can reach**: `make up` on this Mac, with the iPhone on the same Wi-Fi. In the app, the server is `http://<mac>.local:8080`, where `<mac>` is the Mac's local hostname from System Settings ▸ General ▸ Sharing. The app allows local HTTP (`NSAllowsLocalNetworking`). Allow the Local Network prompt.    | user/agent | The app connects and Home shows the topics                               |
| 7   | **App Store Connect key** (H7, M7 only): an **Admin**-role Team API key in `ios/testflight.env`, as in [ios/README.md, TestFlight](../../../ios/README.md#testflight).                                                                                                                                                         | user       | `make ios-testflight-dry-run`, then `make ios-testflight`                |
| 8   | **Cloudflare** (H8, M7 only): [docs/hosting/cloudflare-access.md](../../hosting/cloudflare-access.md) and [docs/hosting/README.md](../../hosting/README.md).                                                                                                                                                                   | user       | The app connects through the tunnel with the service token               |

D needs steps 1–3 and 6. D's push rows and M3-DEV need 4 and 5 as well, and M7
needs 7 and 8.

## 2. Build and install

```bash
make ios-gen
make ios-device-run                                  # the one paired iPhone
make ios-device-run IOS_DEVICE="<device name>"       # if several are paired
make ios-device-run URL=quickr://t/water/record      # then open a link
```

`make ios-device-run` (ios/scripts/device-run.sh) does three things:

1. It makes a signed Debug build for the iPhone. Signing is automatic and uses
   `-allowProvisioningUpdates`, so the first build registers the device and
   creates the development profile.
2. It installs the build with `xcrun devicectl device install app`.
3. It launches the app with `devicectl device process launch`.

It takes the device from `IOS_DEVICE`, from `QUICKR_DEVICE` in `Local.xcconfig`,
or uses the only paired iPhone. It prints device names only. If the launch fails
because the phone is locked, unlock it and run it again.

After the first install:

1. Open the app and onboard: enter the server from step 6 and allow
   notifications.
2. Don't launch with `-QuickrUITest`. It uses an in-memory Keychain and a fresh
   store, which background launches and the extensions can't see.
   `IOS_LAUNCH_ARGS=-QuickrDemoStore` gives a seeded demo store for screenshots
   only.

**Looking inside.** These are agent-run, from the Mac:

- **App logs:** Console.app with the iPhone selected, filtered to subsystem
  `com.bahumia.quickr` (categories such as `nse` and `store`).
  `xcrun devicectl device process launch --console …` streams one launch's
  stdout.
- **The App Group's files** (store, registry):
  `xcrun devicectl device copy from --device "<device name>" --domain-type appGroupDataContainer --domain-identifier group.com.bahumia.quickr --source Library/quickr --destination /tmp/quickr-device`.
  Read them locally. They hold your data, so never commit them.
- **The server's view:** `curl -s localhost:8080/api/v1/topics/<id>/entries` for
  `channel` and `source`. `docker compose logs backend | grep -i apns` shows
  sends and APNs errors.
- **A push without the scheduler:** Settings ▸ Reminders ▸ **Test this device**
  in the app, which calls `POST /api/v1/push/apns/devices/test`. Or run
  `cd backend && uv run python scripts/apns_send.py --token <hex> --env sandbox`.
  The token is in the `apns_devices` table; don't paste it anywhere.
- **A real reminder:** in the PWA or the app, give a topic a schedule that is
  due now. The scheduler sends it on its next tick (10 s with step 5).

**Recording.** The user records with Control Center ▸ Screen Recording, or the
agent records with QuickTime ▸ New Movie Recording ▸ camera: the iPhone.
Recordings go to `docs/ios/demo/m3/` and `docs/ios/demo/m4/` as short `.mp4` or
GIF files (keep each under ~10 MB). D's go under `docs/ios/demo/d/`.

## 3. Checkpoint D: device probe (go/no-go)

From PLAN §7 D, DAG row D, STATUS "D", the open questions and D1 in
docs/ios/specs/notifications.md, and the device items left over from
docs/ios/demo/m1/spike-findings.md (F1, F2, F6, F7, F8).

| #   | Check                                            | Steps                                                                                                                                                                                               | Go when                                                                                                                                                                                             | Record                                                    |
| --- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| D1  | `devicectl` install                              | `make ios-device-run` from a clean checkout                                                                                                                                                         | The app installs and launches, and onboards to the Mac's server                                                                                                                                     | The command's tail (no device identifiers)                |
| D2  | Delivery delay (spike F2)                        | Make a 2-option enum topic due now. Note the time of the scheduler's send in the backend log, and when the banner appears                                                                           | The banner appears within ~10 s; note the figure                                                                                                                                                    | The seconds, 3 runs                                       |
| D3  | NSE category upsert (spike F1, notifications D1) | Create a **new** enum topic on the web and don't open the app. Make it due. The NSE is then the only one registering its category                                                                   | The first reminder already shows the topic's actions, so the NSE's category applies before display. Otherwise the app-side registration (the primary path) still covers it from the next app launch | Yes or no, plus a screenshot of the expanded notification |
| D4  | Visible action count (spike F6)                  | Use a 4-option topic. Check the banner (long-press), the expanded notification, the Lock Screen and Notification Center. Then a 5–6-option topic: 3 most-used + "More…"                             | Record how many show in each place. PLAN assumes 2 or 4; the design already handles 2                                                                                                               | Screenshot of each                                        |
| D5  | Action budget (spike F7)                         | Kill the app (swipe it away). Tap an action from the Lock Screen. From the `nse` and handler logs, take the background launch to the committed enqueue and the flush; check the entry on the server | The entry commits and flushes well inside the ~30 s window; note the times. A miss is a no-go to raise                                                                                              | The times, 3 runs                                         |
| D6  | Lock Screen logging (open question 1)            | With the phone locked (unlocked once since boot), tap a chip on the Lock Screen                                                                                                                     | It logs with no unlock prompt, no "Open quickR" bounce and no failure notification                                                                                                                  | Recording                                                 |
| D7  | Before first unlock (spike F8, open question 3)  | Restart the phone and **don't unlock it**. Make a topic due and tap an action if one shows                                                                                                          | The handler fails gracefully (notifications §7.1 step 3) and nothing is lost or duplicated. Decide open question 3: leave the content untouched, or clear the category                              | What showed, and what the handler did                     |
| D8  | Concurrent replacement (notifications D1, §5.4)  | Two reminders for the same topic (an older slot, then a newer one) while the app is killed                                                                                                          | One notification remains, for the newer slot                                                                                                                                                        | Screenshot                                                |
| D9  | Category growth and registration budget          | Over the day, with a number topic and an enum topic in real use: count the categories (app log) and time `setNotificationCategories`                                                                | Growth per day and the wall time are recorded; pruning only if they're a problem (open question 5)                                                                                                  | The numbers                                               |
| D10 | Widget buttons                                   | Add the quickR widget to the Home Screen and configure a topic. With the app killed, tap a chip                                                                                                     | It logs, the widget shows the result, and the entry reaches the server on the next flush                                                                                                            | Recording                                                 |
| D11 | Action button                                    | Settings ▸ Action Button ▸ Shortcut ▸ quickR. Use Repeat-last if INTENTS shipped it, else "Log Entry" for a topic. Press it                                                                         | It logs without opening the app                                                                                                                                                                     | Recording                                                 |

**Output:** a findings PR, `docs/ios/demo/d/findings.md`, with the table above
filled in and a go/no-go for each row.

## 4. M3-DEV: reminders and logging from notifications (APNs sandbox)

From PLAN §7 M3, DAG row M3-DEV and STATUS M3. Needs prerequisites 4 and 5.

| #   | Check                                    | Steps                                                                                                           | Expected                                                                                                             |
| --- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| M0  | Registration and "Test this device"      | Settings ▸ Reminders shows this device registered (`sandbox`). Tap **Test this device**                         | A notification arrives within seconds. The backend log shows a 200 from APNs                                         |
| M1  | The reminder arrives                     | An enum topic with a schedule due now                                                                           | The reminder shows with its actions (D4's count)                                                                     |
| M2  | A chip action logs with the app killed   | Kill the app, then tap an option on the reminder                                                                | No app UI opens, the notification goes away and the entry is committed                                               |
| M3  | The server has it                        | `GET /api/v1/topics/<id>/entries`                                                                               | The entry has `channel=ios` and `source=ios.notification`, and arrives once even if the action is tapped twice (N16) |
| M4  | The badge updates                        | Several topics due, then log one from a notification                                                            | The app icon badge equals the due count and drops by one                                                             |
| M5  | A version published under a notification | Leave a reminder on screen. In the PWA, publish a new version of that topic. Then tap the old reminder's action | The entry is logged against the version the reminder was sent with (N14), not the new one                            |
| M6  | Number input                             | A number topic's reminder: type a value; then type something that isn't a number                                | The value logs. The bad input posts a local "tap to fix" notification, which opens the record screen                 |

**Record:** one screen recording of M1–M4, in `docs/ios/demo/m3/`. Tick the 5
PLAN items (M1–M5) in the M3 PR body; M0 and M6 are extra.

## 5. M4-DEV: widgets, Controls, Siri and Shortcuts

From PLAN §7 M4, DAG row M4-DEV and STATUS M4.

Some rows depend on work packages that haven't merged yet. At f695859,
ios/m3 has `LogEntryIntent` (the "Log … in quickR" phrase) and the topic
widget, but not `RepeatLastEntryIntent`, `LogTopicIntent` or a Control. W2, W4–W6
and W7 wait for INTENTS and WIDGETS; skip them with `[-]` until those have
merged.

| #   | Check                                  | Steps                                                                                                                                        | Expected                                                                                                                                                                                                     |
| --- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| W1  | Widget, app killed, **no network**     | Turn on Airplane Mode and kill the app. Tap a widget chip. Then turn the network back on and open the app (or wait for a background refresh) | The widget shows "queued". The entry syncs on the next trigger, once                                                                                                                                         |
| W2  | Action button                          | As D11, with Repeat-last                                                                                                                     | Repeats the last entry of the configured topic                                                                                                                                                               |
| W3  | Siri, one phrase                       | "Log water in quickR"                                                                                                                        | The water topic logs (or asks for its value) and confirms                                                                                                                                                    |
| W4  | Siri, a 3-question topic while offline | Airplane Mode, then "Log workout in quickR"                                                                                                  | Siri asks field by field, shows the confirmation card, and the entry queues and syncs later                                                                                                                  |
| W5  | Editing in the Siri card               | At W4's confirmation, change a value, then confirm                                                                                           | The edited value is the one logged                                                                                                                                                                           |
| W6  | One sentence (Apple Intelligence)      | "Log a 30 minute run, effort 7, in quickR"                                                                                                   | It parses into one confirmation without per-field turns                                                                                                                                                      |
| W7  | Controls                               | Add the quickR Control to Control Center (and the Lock Screen), then run it                                                                  | It logs or opens the record screen, as configured                                                                                                                                                            |
| W8  | Multi-process soak                     | For ~2 minutes, log from the app, a widget and notification actions in quick succession, with the app in front and killed in turn            | Console shows no `SQLITE_BUSY`, and there is no 0xDEAD10CC crash (check Settings ▸ Privacy & Security ▸ Analytics & Improvements ▸ Analytics Data for `QuickR` reports). Every entry reaches the server once |

**Record:** a recording of W1–W3 and W4–W6 in `docs/ios/demo/m4/`, plus GIFs of
the widget and the Siri card. Mark W2 `[-]` only on a phone without an Action
button; this one has one.

## 6. Who drives what

The agent can run everything that goes through a terminal on the Mac. A person
holds the phone for the rest. An agent never taps on the phone.

| Agent (from the Mac)                                                                    | The user (on the phone)                                             |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `make ios-device-run` builds, installs and launches                                     | Trust this Mac, Developer Mode, the restart (prerequisite 3)        |
| `xcrun devicectl`: device list, App Group file copies, `process launch --console`, URLs | Unlocking the phone, and **not** unlocking it for D7                |
| Console.app logs for subsystem `com.bahumia.quickr` (with the phone connected)          | Every tap on a notification, the Lock Screen, a widget or a Control |
| The push test endpoint, `apns_send.py`, and making topics due (PWA or API)              | The Action button, and Siri by voice (W3–W6)                        |
| Server checks (`curl`, `docker compose logs`), and timings from the logs                | Adding widgets and Controls, and Airplane Mode                      |
| Publishing a new version (M5) in the PWA or through the API                             | Screen recordings from Control Center (or the agent with QuickTime) |
| Writing the findings PRs and the GIFs                                                   | Killing the app (app switcher), and Settings ▸ Action Button        |

## 7. M7 regression pass (on the device)

PLAN §7 M7 requires "the full regression checklist passes on the device". This
is that list, from the requirements matrix (PLAN §11) and the M2–M6 features.
Run it on a **TestFlight** build (it installs over the air, and APNs is
`production`), against the hosted server through Cloudflare.

**Install and setup**

- [ ] TestFlight install over the air; launch; onboard to the hosted server with
      the Cloudflare service token (Settings shows the server; the token is in
      the Keychain)
- [ ] Notification permission; Settings ▸ Reminders shows the device registered
      as `production`; Test this device arrives

**Home, tiles, record**

- [ ] Home lists due topics first; light and dark mode; Dynamic Type XL and an
      accessibility size
- [ ] A tile chip logs in one tap, with Undo; a number tile's "✓ last"
- [ ] The record screen: every question type, "Same as last time", "Log
      another", the keyboard Save; leaving with changes asks first
- [ ] Deep links: `quickr://t/<slug>/record` and the server's own PWA URL open
      the record screen

**Offline and sync**

- [ ] Airplane Mode: log from a tile and the record screen ("Saved on this
      device"); the entries list shows them waiting; back online they sync
- [ ] The sync sheet: waiting and failed items, Retry, Fix, Discard

**Entries, edit, delete, CSV**

- [ ] The entries list and filters; an entry opens to edit; Save changes syncs
- [ ] Delete with Undo; Undo keeps it on the server; without Undo it is deleted
- [ ] An edit made on the web shows on the phone
- [ ] CSV export through the share sheet (online)

**Topics and stats**

- [ ] A new topic; the builder; publish v2; log against v2; an older entry shows
      its version
- [ ] Topic settings: schedule, archive with Undo, delete with typed
      confirmation
- [ ] Stats charts with the right buckets and time zone

**Notifications (production APNs)**

- [ ] M3-DEV M1–M5 again, in production
- [ ] Logging from the Lock Screen; the badge

**Widgets, Controls, Siri**

- [ ] M4-DEV W1, W2, W3 and W7 again on the TestFlight build

**Settings and app**

- [ ] Sync status, reset (warns about pending changes), about, licences
- [ ] Changing the server, then changing it back: nothing from one server shows
      on the other

**Accessibility and performance**

- [ ] VoiceOver through home, a tile, record, entries and settings; tap targets
      at least 44 pt
- [ ] Cold start under 1 s with the 10k-entry seed (PERF), timed on the phone

**PWA**

- [ ] The PWA still works, and its Chromium notification actions log entries
