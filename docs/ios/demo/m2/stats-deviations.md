# STATS: deviations from the PWA

The Overview matches the PWA's `OverviewPage` and its charts. The server
computes the stats and series and does all the bucketing; the app only lays them
out. The layout decisions are the PWA's own code, run in both places:

- `frontend/src/components/charts/chartModels.ts` holds the chart models, which
  moved out of the components unchanged.
- `stats.vectors.test.ts` runs them over real backend responses
  (`shared/fixtures/stats-vectors.json`) into `stats-chart-vectors.json`.
- `StatsChartVectorTests` checks the QuickrCore port against that file bit for
  bit: kept buckets, value ticks and their labels, labelled x positions at two
  widths, legend, segments, totals, bucket labels in each series' zone, every
  card's text, and the number and percent formats.

These are the deliberate differences:

1. **Offline shows the last answer.** The PWA shows "Could not load stats" when
   a fetch fails. iOS caches every answer in the store's `stats_cache`, keyed by
   server, store generation and the whole query (range, version, source, and for
   a series the question, bucket and zone). When a fetch fails, the cached
   answer for the same query stays on screen with "Last updated 5 minutes ago"
   (and the reason, unless it is just offline). With nothing cached, the card
   says "Stats need a connection."
2. **A response from another epoch is never shown** (sync-protocol §11, S20). It
   is discarded, the store is marked `epoch_suspect` and the coordinator runs.
   Cached rows are read only under the epoch they were fetched in.
3. **A zone change is never served from cache.** The reader's zone is part of a
   series' key. After a change, the new zone's buckets are fetched. Offline, a
   chart cached only for another zone says "Charts for this time zone need a
   connection." rather than showing that zone's (wrong) buckets. The PWA has no
   cache, so offline it shows its error either way.
4. **The cache key names the range, not its start.** `captured_from` moves every
   day; yesterday's "30 days" still shows offline today, marked stale.
5. **Filters are shared through memory, not the URL.** The PWA keeps range,
   version and source in the page URL, so the Overview and Entries tabs share
   them. iOS keeps them per topic in `AppEnvironment.topicFilters` for the app's
   run; a relaunch starts from the defaults (30 days).
6. **Selection instead of hover.** Charts show their tooltip while you press and
   drag (Swift Charts' `chartXSelection`); the PWA follows the pointer.
7. **Swift Charts draws.** Values, ticks, which buckets get an x label and the
   colours are the PWA's. Swift Charts places the plot area and the bars itself,
   so pixel positions differ.
8. **Legend order for unknown values.** A stacked chart's legend lists the
   question's options first, then values the question no longer has, by first
   appearance. A JSON object's key order doesn't survive decoding on iOS, so
   within one bucket those values are in sorted order (the server sends them
   sorted anyway).
9. **Accessibility sizes.** The range and bucket pickers become menus (segments
   would truncate), and the summary is one column instead of two.
10. **Relative times** ("Latest", "Last updated") use the system's
    `RelativeDateTimeFormatter`. Its wording can differ slightly from the
    browser's `Intl.RelativeTimeFormat`.
11. **The zone sent is the device's identifier.** A device set to UTC sends
    `GMT`, which the server accepts.
