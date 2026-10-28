// Build-time constants injected by `define` in vite.config.ts (also available in sw.ts).

/** package.json version. */
declare const __APP_VERSION__: string;
/** ISO timestamp of the build. */
declare const __BUILD_TIME__: string;
/**
 * Short hash of the generated API types. Part of the persisted-cache buster, so
 * regenerating the client after an API change drops cache entries of the old shape.
 */
declare const __API_HASH__: string;
/**
 * The API level this bundle speaks (`api_level` of shared/api-level.json, through its copy
 * src/api/apiLevel.json). Sent in `X-QuickR-Client` (docs/specs/client-versions.md §2, §5.1).
 */
declare const __API_LEVEL__: number;
