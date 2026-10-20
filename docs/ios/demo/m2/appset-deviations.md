# APPSET: deviations from the PWA

App settings follow the PWA's `AppSettingsPage`. SETTINGS already built the
server, Cloudflare Access, notifications and reset parts. APPSET adds "Offline &
sync", moves About into `App/Settings/App` and adds Licences. These are the
deliberate differences:

1. **No "App" (install) section.** The PWA explains installing to the Home
   Screen; the native app is installed.
2. **"Offline & sync" summarises and links, rather than listing.** The PWA
   embeds its `OutboxPanel`. iOS shows a summary instead:
   - status: the sync pill's label, or "All changes synced";
   - when the last pull succeeded;
   - why pulls keep failing, once the pill says "Sync error".

   "Review changes…" opens SYNC-UX's sheet, which has the same items and actions
   as the panel, whenever items wait or have failed. "Sync now" pulls and sends.
   The Online/Offline badge also says offline when the server can't be reached,
   not only when there is no network, the same as the sync pill.

3. **About has no build time, service worker or "Check for updates".** Updates
   come from the App Store or TestFlight. About shows the version and build, the
   core version, the server's id and this iPhone's copy (its store generation).
4. **Licences.** The PWA has no licences page. iOS lists GRDB.swift (MIT) and
   the three bundled font families (SIL Open Font License 1.1), each with its
   full text. A host test keeps the list in step with `Package.resolved` and the
   bundled fonts.
5. **Reset, not "Clear local data".** This is SETTINGS's existing deviation. It
   resets the active server's copy only, and warns about unsynced changes with
   "Sync first" (sync-protocol.md §12.1). The PWA clears everything and reloads.
