#!/usr/bin/env bash
# Generate the three App Center icons from the upstream zot logo.
#
# QTS expects GIFs named exactly after QPKG_NAME:
#   Zot.gif        64x64  enabled state
#   Zot_gray.gif   64x64  disabled state
#   Zot_80.gif     80x80  info dialog
#
# Source: project-zot/zui public/logo512.png (Apache-2.0), a dark mark on a
# transparent background. Flattened onto white because App Center renders these
# as tiles, and a transparent dark mark disappears on a dark theme.
set -euo pipefail

SRC="${1:?usage: make-icons.sh <source-logo.png> <outdir>}"
OUT="${2:?usage: make-icons.sh <source-logo.png> <outdir>}"
mkdir -p "$OUT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Flatten onto white, drop alpha, then trim the transparent margin so the mark
# is not resized together with its empty padding.
magick "$SRC" -background white -alpha remove -alpha off -trim +repage "$TMP/mark.png"
echo "trimmed mark: $(magick identify -format '%wx%h' "$TMP/mark.png")"

# Fit inside a square canvas with a small margin, then pad to the exact size.
square() { # $1=size $2=out
    local s=$1 inset=$(( $1 * 7 / 8 ))
    magick "$TMP/mark.png" \
        -resize "${inset}x${inset}" \
        -background white -gravity center -extent "${s}x${s}" \
        -colors 255 -type Palette "$2"
}

square 64 "$OUT/Zot.gif"
square 80 "$OUT/Zot_80.gif"

# Disabled state: greyscale of the same artwork.
magick "$OUT/Zot.gif" -colorspace Gray -colors 255 -type Palette "$OUT/Zot_gray.gif"

for f in "$OUT"/*.gif; do
    printf "%-16s %s  %s\n" "$(basename "$f")" \
        "$(magick identify -format '%wx%h' "$f")" \
        "$(stat -c%s "$f") bytes"
done
