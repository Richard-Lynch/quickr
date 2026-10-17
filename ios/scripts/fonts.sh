#!/usr/bin/env bash
# Downloads the brand's variable fonts from the Google Fonts repo (pinned commit) and cuts the
# static instances QuickrUI bundles, plus each family's OFL.txt (as <Family>-OFL.txt: SwiftPM
# flattens processed resources, so the names must be unique). Needs curl and uvx (fonttools).
# The output is committed; rerun only to change weights or bump the pin.
# Usage: fonts.sh
#
# Axis pins follow what the PWA renders: @fontsource-variable's wght-only files keep Bricolage
# at its default opsz 96 and every family at wdth 100.
source "$(dirname "$0")/common.sh"
command -v uvx >/dev/null || die "uvx not found: brew install uv"

GF_COMMIT="47d54ca1ebb14fd864695f1d39dc734f39017c33"
FONTTOOLS="fonttools==4.67.0"
OUT="$IOS_DIR/QuickrKit/Sources/QuickrUI/Resources/Fonts"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() { # <google/fonts path> <dest>
  curl -sfL "https://raw.githubusercontent.com/google/fonts/$GF_COMMIT/$1" -o "$2" || die "download failed: $1"
}

# The OFL lets a Reserved Font Name be declared in the copyright header. A modified (instanced)
# file must not keep a reserved name, so stop if one appears and rename before shipping.
check_rfn() { # <OFL.txt>
  if sed '/^This Font Software is licensed/,$d' "$1" | grep -qi 'reserved font name'; then
    die "$1 declares a Reserved Font Name: rename the instances before bundling"
  fi
}

rm -rf "$OUT"
mkdir -p "$OUT"
# <dir in google/fonts> <variable file> <family stem>
for spec in \
  'bricolagegrotesque BricolageGrotesque%5Bopsz,wdth,wght%5D.ttf BricolageGrotesque' \
  'instrumentsans InstrumentSans%5Bwdth,wght%5D.ttf InstrumentSans' \
  'jetbrainsmono JetBrainsMono%5Bwght%5D.ttf JetBrainsMono'; do
  read -r dir file stem <<<"$spec"
  fetch "ofl/$dir/$file" "$work/$stem.ttf"
  fetch "ofl/$dir/OFL.txt" "$work/$stem-OFL.txt"
  check_rfn "$work/$stem-OFL.txt"
  cp "$work/$stem-OFL.txt" "$OUT/$stem-OFL.txt"
done

# Instances are named explicitly (not from STAT, which lacks some weights). Prints each file's
# PostScript name: QuickrFonts.swift refers to the fonts by these.
uvx --quiet --from "$FONTTOOLS" python - "$work" "$OUT" <<'PY'
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

work, out = sys.argv[1], sys.argv[2]
FAMILIES = {
    # stem: (family name, fixed axes, {weight: style})
    "BricolageGrotesque": ("Bricolage Grotesque", {"opsz": 96, "wdth": 100}, {600: "SemiBold", 700: "Bold"}),
    "InstrumentSans": ("Instrument Sans", {"wdth": 100}, {400: "Regular", 500: "Medium", 600: "SemiBold"}),
    "JetBrainsMono": ("JetBrains Mono", {}, {400: "Regular", 600: "SemiBold"}),
}

for stem, (family, axes, weights) in FAMILIES.items():
    for weight, style in weights.items():
        font = instantiateVariableFont(TTFont(f"{work}/{stem}.ttf"), {**axes, "wght": weight}, static=True)
        name = font["name"]
        for nid in (16, 17, 21, 22, 25):
            name.removeNames(nameID=nid)
        ribbi = style in ("Regular", "Bold")
        ps = f"{family.replace(' ', '')}-{style}"
        values = {
            1: family if ribbi else f"{family} {style}",
            2: style if ribbi else "Regular",
            3: f"{ps};{font['head'].fontRevision:.3f}",
            4: family if style == "Regular" else f"{family} {style}",
            6: ps,
        }
        if not ribbi:
            values.update({16: family, 17: style})
        for nid, value in values.items():
            name.setName(value, nid, 3, 1, 0x409)
            name.setName(value, nid, 1, 0, 0)
        os2 = font["OS/2"]
        os2.usWeightClass = weight
        bold = style == "Bold"
        os2.fsSelection = (os2.fsSelection & ~0b1100001) | (0b100000 if bold else 0b1000000)
        font["head"].macStyle = 1 if bold else 0
        path = f"{out}/{stem}-{style}.ttf"
        font.save(path)
        print(f"ios: {stem}-{style}.ttf: {ps}")
PY
