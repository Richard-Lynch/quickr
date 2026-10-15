// Monochrome notification badge (Android shows it as a white silhouette in the
// status bar). Same glyph as public/favicon.svg, no background. Run via `pnpm gen:icons`.
import sharp from 'sharp';

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <g fill="none" stroke="#fff" stroke-linecap="round"
     transform="translate(256 256) scale(1.2) translate(-218 -268)">
    <circle cx="262" cy="242" r="88" stroke-width="56"/>
    <path d="M350 186v196" stroke-width="56"/>
    <path d="M88 202h44M70 242h62M88 282h44" stroke-width="24"/>
  </g>
</svg>`;

await sharp(Buffer.from(svg)).resize(96, 96).png().toFile('public/badge-96x96.png');
console.log('✔ public/badge-96x96.png');
