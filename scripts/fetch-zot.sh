#!/usr/bin/env bash
# Fetch the pinned zot release binary into packages/zot/x86_64/.
#
# Verifies SHA256 against the release's checksums.sha256.txt rather than
# trusting the download. ~226 MB, so it is a separate step from the build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZOT_VERSION="${ZOT_VERSION:-v2.1.22}"
DEST="$REPO_ROOT/packages/zot/x86_64"

# The only architecture this package targets. QTS reports uname -m = x86_64.
ASSET="zot-linux-amd64"

die(){ echo "error: $*" >&2; exit 1; }

mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/project-zot/zot/releases/download/${ZOT_VERSION}"

echo "==> $ASSET $ZOT_VERSION"
echo "    downloading checksums"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/checksums" "$BASE/checksums.sha256.txt" \
    || die "could not fetch checksums.sha256.txt"

# checksums.sha256.txt is in sha256sum binary-mode format: "<sha> *<filename>",
# so the filename is preceded by '*' rather than whitespace. Accept both.
WANT=$(awk -v a="$ASSET" '{ n=$2; sub(/^\*/,"",n); if (n==a) { print $1; exit } }' "$TMP/checksums")
[ -n "$WANT" ] || die "no checksum entry for $ASSET in checksums.sha256.txt"

echo "    expected sha256: $WANT"

if [ -f "$DEST/zot" ]; then
    HAVE=$(sha256sum "$DEST/zot" | awk '{print $1}')
    if [ "$HAVE" = "$WANT" ]; then
        echo "==> already present and verified, nothing to do"
        exit 0
    fi
    echo "    existing binary differs, re-downloading"
fi

echo "    downloading $ASSET (~226 MB)"
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TMP/zot" "$BASE/$ASSET" \
    || die "download failed — retry, or set HTTPS_PROXY"

GOT=$(sha256sum "$TMP/zot" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || die "checksum mismatch: got $GOT want $WANT"

install -m 0755 "$TMP/zot" "$DEST/zot"

# The binary must actually run here; a broken/truncated download that happens to
# hash correctly is not a thing, but a wrong-arch asset would be.
"$DEST/zot" --version >/dev/null 2>&1 || die "fetched binary does not execute on this host"

echo "==> ok: $DEST/zot"
"$DEST/zot" --version 2>&1 | sed -n 's/.*"commit":"\([^"]*\)".*/    version \1/p'
ls -l "$DEST/zot" | awk '{printf "    size %.1f MB\n", $5/1e6}'
