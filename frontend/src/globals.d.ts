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
