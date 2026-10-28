/// <reference types="vitest/config" />
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import { defineConfig, searchForWorkspaceRoot } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

// Where the dev/preview server proxies /api and /mcp (`QUICKR_API_TARGET=http://localhost:8200`).
// QUICKR_BACKEND_URL is the older name for the same thing.
const backend =
  process.env.QUICKR_API_TARGET ?? process.env.QUICKR_BACKEND_URL ?? 'http://localhost:8100';

const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')) as {
  version: string;
};
// Changes whenever the generated API types change → busts the persisted query cache.
const apiHash = createHash('sha256')
  .update(readFileSync(new URL('./src/client/types.gen.ts', import.meta.url)))
  .digest('hex')
  .slice(0, 10);
// The API level this bundle speaks: a generated copy of shared/api-level.json (`make api-level`,
// docs/specs/client-versions.md §2), since the image is built from frontend/ alone.
const apiLevel = JSON.parse(
  readFileSync(new URL('./src/api/apiLevel.json', import.meta.url), 'utf8'),
) as { api_level: number };

const proxy = {
  '/api': { target: backend, changeOrigin: true },
  '/mcp': { target: backend, changeOrigin: true },
};

// Light / dark "paper" colours from src/index.css.
const PAPER = '#f3efe6';

export default defineConfig({
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __BUILD_TIME__: JSON.stringify(new Date().toISOString()),
    __API_HASH__: JSON.stringify(apiHash),
    __API_LEVEL__: JSON.stringify(apiLevel.api_level),
  },
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.ts',
      // The app shows its own "Update available" toast (src/components/pwa/UpdatePrompt).
      registerType: 'prompt',
      injectRegister: false,
      // Icons are already matched by globPatterns (avoids duplicate precache entries).
      includeManifestIcons: false,
      injectManifest: {
        // Only the latin font subsets: the other ~20 subset files stay network-only.
        globPatterns: ['**/*.{js,css,html,ico,png,svg,webmanifest}', 'assets/*-latin-wght-*.woff2'],
      },
      manifest: {
        id: '/',
        name: 'quickR',
        short_name: 'quickR',
        description: 'Log anything, fast — config-driven data capture.',
        lang: 'en',
        dir: 'ltr',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        display_override: ['standalone', 'minimal-ui'],
        background_color: PAPER,
        theme_color: PAPER,
        categories: ['productivity', 'utilities', 'health'],
        icons: [
          { src: 'pwa-64x64.png', sizes: '64x64', type: 'image/png' },
          { src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' },
          { src: 'pwa-512x512.png', sizes: '512x512', type: 'image/png' },
          {
            src: 'maskable-icon-512x512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
          { src: 'favicon.svg', sizes: 'any', type: 'image/svg+xml' },
        ],
        shortcuts: [
          {
            name: 'New topic',
            url: '/new',
            icons: [{ src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' }],
          },
          {
            name: 'Settings',
            url: '/settings',
            icons: [{ src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' }],
          },
        ],
      },
      devOptions: {
        // `PWA_DEV=1 pnpm dev` runs the service worker in dev too.
        enabled: process.env.PWA_DEV === '1',
        type: 'module',
        navigateFallback: 'index.html',
      },
    }),
  ],
  server: {
    port: Number(process.env.PORT ?? 5180),
    strictPort: true,
    proxy,
    // Tests read the cross-platform vectors in ../shared/fixtures (quickLog.vectors.test.ts).
    fs: { allow: [searchForWorkspaceRoot(process.cwd()), '../shared/fixtures'] },
  },
  preview: { port: Number(process.env.PREVIEW_PORT ?? 5180), proxy },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
  },
});
