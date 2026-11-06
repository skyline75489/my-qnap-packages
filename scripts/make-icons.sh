#!/usr/bin/env bash
# Generate the three App Center icons from an upstream logo.
#
# QTS expects GIFs named exactly after QPKG_NAME:
#   <NAME>.gif        64x64  enabled state
#   <NAME>_gray.gif   64x64  disabled state
#   <NAME>_80.gif     80x80  info dialog
#
# Usage: make-icons.sh <source-logo.png> <outdir> [name]
#
# The name defaults to Zot. Source logos:
#   Zot      project-zot/zui public/logo512.png (Apache-2.0)
#   OpenList OpenListTeam/Logo logo/256x256.png (CC BY-NC-SA 4.0)
# Both are a mark on a transparent background. Flattened onto white because
# App Center renders these as tiles, and a transparent dark mark disappears
# on a dark theme.
set -euo pipefail

SRC="${1:?usage: make-icons.sh <source-logo.png> <outdir> [name]}"
OUT="${2:?usage: make-icons.sh <source-logo.png> <outdir> [name]}"
NAME="${3:-Zot}"
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

square 64 "$OUT/$NAME.gif"
square 80 "$OUT/${NAME}_80.gif"

# Disabled state: greyscale of the same artwork.
magick "$OUT/$NAME.gif" -colorspace Gray -colors 255 -type Palette "$OUT/${NAME}_gray.gif"

for f in "$OUT"/*.gif; do
    printf "%-16s %s  %s\n" "$(basename "$f")" \
        "$(magick identify -format '%wx%h' "$f")" \
        "$(stat -c%s "$f") bytes"
done
