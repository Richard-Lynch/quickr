import { defineConfig, type Preset } from '@vite-pwa/assets-generator/config';

/**
 * App icons, generated from `public/favicon.svg` by `pnpm gen:icons` and committed.
 *
 * The source is a rounded square whose glyph sits inside the maskable safe zone,
 * so maskable / Apple icons are produced at padding 0 with the corners filled in
 * with the brand orange (iOS and Android apply their own mask).
 */
const ORANGE = '#e8590c';

const preset: Preset = {
  transparent: {
    sizes: [64, 192, 512],
    favicons: [[48, 'favicon.ico']],
    padding: 0,
  },
  maskable: {
    sizes: [512],
    padding: 0,
    resizeOptions: { background: ORANGE },
  },
  apple: {
    sizes: [180],
    padding: 0,
    resizeOptions: { background: ORANGE },
  },
};

export default defineConfig({
  headLinkOptions: { preset: '2023' },
  preset,
  images: ['public/favicon.svg'],
});
