#!/usr/bin/env bash
# Renders the app icon from the PWA's frontend/public/favicon.svg into
# ios/Resources/Assets.xcassets/AppIcon.appiconset: one 1024 px universal image per appearance.
#   light:  full bleed (rx removed, iOS masks the corners), orange with a white glyph, no alpha
#   dark:   the dark paper with the dark-mode accent glyph, no alpha
#   tinted: a white glyph on transparent; iOS applies the tint
# Needs rsvg-convert (brew install librsvg) and ImageMagick (brew install imagemagick).
# The output is committed; rerun when favicon.svg changes.
# Usage: icons.sh
source "$(dirname "$0")/common.sh"
command -v rsvg-convert >/dev/null || die "rsvg-convert not found: brew install librsvg"
command -v magick >/dev/null || die "magick not found: brew install imagemagick"

SRC="$ROOT_DIR/frontend/public/favicon.svg"
CATALOG="$IOS_DIR/Resources/Assets.xcassets"
OUT="$CATALOG/AppIcon.appiconset"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Colours from index.css: accent and paper in dark mode.
DARK_PAPER="#141210"
DARK_ACCENT="#ff7a2e"

grep -q 'rx="116"' "$SRC" || die "favicon.svg changed shape (no rx=\"116\"): check this script"
full="$(sed 's/ rx="116"//' "$SRC")"
printf '%s' "$full" >"$work/light.svg"
printf '%s' "$full" | sed -e "s/fill=\"#e8590c\"/fill=\"$DARK_PAPER\"/" -e "s/stroke=\"#fff\"/stroke=\"$DARK_ACCENT\"/" >"$work/dark.svg"
printf '%s' "$full" | sed 's/<rect [^>]*\/>//' >"$work/tinted.svg"

mkdir -p "$OUT"
render() { # <svg> <png> <magick args...>
  local svg="$1" png="$2"; shift 2
  rsvg-convert -w 1024 -h 1024 "$svg" | magick - "$@" "$OUT/$png"
}
render "$work/light.svg" AppIcon-1024.png -alpha off -define png:color-type=2
render "$work/dark.svg" AppIcon-1024-dark.png -alpha off -define png:color-type=2
render "$work/tinted.svg" AppIcon-1024-tinted.png -colorspace Gray

cat >"$CATALOG/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
cat >"$OUT/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-1024-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-1024-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
echo "ios: wrote $OUT"
