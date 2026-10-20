# TILES: deviations from the PWA

Quick-log tiles match the PWA's `TopicTile`, `useQuickLog` and `useUndoLog`.
That includes the same tap counts as the design loop
(`frontend/docs/design-loop.md`):

| Row               | PWA | iOS |
| ----------------- | --- | --- |
| (a) chip          | 1   | 1   |
| (b) number        | 1   | 1   |
| (b) number with ± | 2   | 2   |
| (f) undo          | 1   | 1   |
| (g) offline       | 1   | 1   |

`TileUITests` checks every row except "number with ±". These are the deliberate
differences:

1. **A refused quick-log stays in the outbox.** The PWA's `recordEntry` discards
   a new entry that gets a 4xx. iOS keeps it as `failed`, so the sync sheet can
   fix or discard it (outbox.md §11). The toast is the same: "Couldn't log
   Headache" with the server's message.
2. **Undo of a delete that already left says so.** If the hold was already
   released (for example, the app went to the background), Undo shows "Couldn't
   undo: The delete was already sent." The PWA's timer-based undo has no such
   state, and its Undo does nothing.
3. **"Nothing to undo".** The PWA says "Undone" whenever its discard or DELETE
   succeeds. iOS says "Undone" only when the create was removed or a DELETE now
   reserves its id (outbox.md §9.1). When there was nothing left to undo, iOS
   says "Nothing to undo".
4. **Undo and `sendNow` are tied to the store.** A write remembers its server
   and store generation. After a server switch or a reset, its toast's Undo is
   refused with "The server changed since then. Nothing was undone." Its
   `sendNow` reports "queued", because the entry waits in its own store. The PWA
   has a single server, so this can't happen there.
5. **Offline, one attempt is made.** The PWA skips the request when `navigator`
   says it's offline. iOS sends it, and `sendNow` reports "queued" as soon as
   that attempt fails, rather than at the end of the 2.5 s wait. NWPathMonitor
   (SYNC-UX) can skip the attempt later.
6. **VoiceOver.** A chip's "same as last time" and "Logged" are its
   accessibility _value_, so the label stays "Log Mild". The PWA appends "(same
   as last time)" to the `aria-label`. The ✓ reads "Log 3 glasses", as the PWA's
   does.
7. **Accessibility sizes.** At the accessibility text sizes, the due badge sits
   above the "Last …" line. The badge wraps into a rounded box instead of
   truncating the time. The PWA has one wrapping row and no accessibility sizes.
