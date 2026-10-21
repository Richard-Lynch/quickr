# WIDGETS: deviations and notes

The PWA has no widgets, so these are the native app's own rules: what each
widget does, and where the platform shaped it (PLAN §2, "Widgets").

## What there is

| Widget                                               | Families                                                    | Does                                                                                                                                    |
| ---------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| **Topic** (configured with a topic)                  | Small, Medium; Lock Screen rectangular, circular and inline | Name, due pill, "Last …", "queued" while this device's logs wait to sync. Chips log an option, ✓ logs the last number, without the app. |
| **Due now**                                          | Medium, Large; Lock Screen rectangular, circular and inline | Due first, then scheduled, like the home list. A row opens that topic's record screen.                                                  |
| **Log a topic** (a Control, configured with a topic) | Control Center, Lock Screen, Action button                  | Logs the topic's last answer again in one press.                                                                                        |

## Deliberate choices

1. **Writes are durable first.** A chip, ✓ or Control runs INTENTS'
   `LogEntryIntent`. That commits one `entry.create` from "ios.widget" before
   `perform()` returns. The widgets then reload, which shows "queued", and a
   bounded 4 s flush sends it. Offline, or out of time, the entry stays queued
   and the app or the next trigger sends it (`WidgetWrites`).
2. **Reloads follow changes, not a clock.** A timeline holds an entry at every
   instant a shown topic's due state changes (`Due.timeline`), plus refresh
   points so relative text stays true: every 15 minutes for 2 hours, then
   hourly, up to 12 hours and 48 entries. Due changes are kept first. The app
   reloads the timelines only when something a widget shows changes
   (`WidgetFingerprint`), not on every sync.
3. **Text stops growing at xxLarge.** A widget is a fixed size: at the
   accessibility sizes, names, pills and chips no longer fit. Widget text
   follows Dynamic Type up to xxLarge. VoiceOver reads everything: chips are
   "Log Mild", the queued mark is "1 waiting to sync".
4. **A Control can't ask.** It runs one fully specified intent and can't prompt
   or branch. A chip topic logs its last option. A number topic logs its last
   value, or the stepper's start when it was never logged, like the tile's ✓. A
   chip topic that was never logged, or a topic that needs the form, shows "Log
   it in quickR first" or "Needs the form", and a press is declined.
5. **A topic that needs the form opens it.** Its widget shows "Log", and a tap opens the record
   screen, as does a tap anywhere else on a topic widget.
6. **Lock Screen and tinted are checked on a device.** The app's widget gallery
   (DEBUG, `-QuickrWidgetGallery`) renders the extension's own views at their
   sizes, and `WidgetViewsUITests` checks them in light, dark and AX. The
   gallery's Lock Screen and tinted pages approximate the system's one-colour
   rendering. The real rendering, and a log with the app killed and offline, are
   on the M4-DEV device checklist. SpringBoard automation stalls on the
   simulator (`widget-proof.sh`).
