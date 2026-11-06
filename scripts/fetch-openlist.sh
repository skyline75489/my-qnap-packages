#!/usr/bin/env bash
# Fetch the pinned OpenList release binary into packages/openlist/x86_64/.
#
# Upstream publishes only md5 sums (md5-linux-musl.txt), so the tarball is
# checked against those and the sha256 of the extracted binary is recorded
# for our own reference. ~53 MB tarball, ~155 MB binary, so it is a separate
# step from the build.
#
# Why the musl build: it is statically linked (upstream asserts this in
# CI), so it does not care about the NAS's glibc 2.21. The glibc build
# links against libc.so.6 and would work too, but the static one has no
# runtime dependency at all.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENLIST_VERSION="${OPENLIST_VERSION:-v4.2.9}"
DEST="$REPO_ROOT/packages/openlist/x86_64"

# The only architecture this package targets. QTS reports uname -m = x86_64.
ASSET="openlist-linux-musl-amd64.tar.gz"
CHECKSUM_FILE="md5-linux-musl.txt"

# sha256 of the extracted binary for the pinned version. Upstream publishes
# md5 only, so this is our own record: it makes a re-download verifiable
# against something we pinned, not only against upstream's md5.
EXPECT_SHA256="${EXPECT_SHA256:-7b6d5f9f9f3d29fab3c4ffb77fd155f397f3e07d228d66b68274ad0b7379f5f0}"

die(){ echo "error: $*" >&2; exit 1; }

# GitHub release downloads are flaky from time to time (connection resets
# mid-transfer). curl's own --retry does not cover every failure mode, so
# wrap the download in an explicit attempt loop.
fetch(){ # $1=url $2=out
    _n=0
    while [ "$_n" -lt 6 ]; do
        _n=$((_n + 1))
        if curl -fsSL --connect-timeout 30 --max-time 900 \
               --retry 3 --retry-all-errors --retry-delay 5 \
               -o "$2" "$1"; then
            return 0
        fi
        echo "    attempt $_n failed, retrying in 10s"
        sleep 10
    done
    return 1
}

mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/OpenListTeam/OpenList/releases/download/${OPENLIST_VERSION}"

echo "==> $ASSET $OPENLIST_VERSION"
echo "    downloading md5 sums"
fetch "$BASE/$CHECKSUM_FILE" "$TMP/md5" || die "could not fetch $CHECKSUM_FILE"

# The file is in md5sum binary-mode format: "<md5> *<filename>", so the
# filename is preceded by '*'. Upstream also prefixes the name with './'.
# Accept every combination.
WANT=$(awk -v a="$ASSET" '{ n=$2; sub(/^\*/,"",n); sub(/^\.\//,"",n); if (n==a) { print $1; exit } }' "$TMP/md5")
[ -n "$WANT" ] || die "no checksum entry for $ASSET in $CHECKSUM_FILE"

echo "    expected md5: $WANT"

if [ -f "$DEST/openlist" ]; then
    HAVE=$(sha256sum "$DEST/openlist" | awk '{print $1}')
    if [ -f "$DEST/openlist.sha256" ] && [ "$HAVE" = "$(cat "$DEST/openlist.sha256")" ]; then
        echo "==> already present and verified, nothing to do"
        exit 0
    fi
    echo "    existing binary differs, re-downloading"
fi

echo "    downloading $ASSET (~53 MB)"
fetch "$BASE/$ASSET" "$TMP/$ASSET" || die "download failed — retry, or set HTTPS_PROXY"

GOT=$(md5sum "$TMP/$ASSET" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || die "checksum mismatch: got $GOT want $WANT"

# The tarball contains exactly one file, "openlist", at the top level.
tar tzf "$TMP/$ASSET" | grep -qx 'openlist' || die "unexpected tarball layout"
tar xzf "$TMP/$ASSET" -C "$TMP" openlist || die "could not extract the binary"

install -m 0755 "$TMP/openlist" "$DEST/openlist"

GOTSHA=$(sha256sum "$DEST/openlist" | awk '{print $1}')
[ "$GOTSHA" = "$EXPECT_SHA256" ] || die "binary sha256 mismatch: got $GOTSHA want $EXPECT_SHA256"

# The binary must actually run here; a broken/truncated download that happens
# to hash correctly is not a thing, but a wrong-arch asset would be.
"$DEST/openlist" version >/dev/null 2>&1 || die "fetched binary does not execute on this host"

# The musl build must be static, otherwise it would depend on the NAS's libc.
if command -v file >/dev/null 2>&1; then
    file "$DEST/openlist" | grep -q 'statically linked' \
        || die "binary is not statically linked — it would depend on the NAS's libc"
fi

sha256sum "$DEST/openlist" | awk '{print $1}' > "$DEST/openlist.sha256"

echo "==> ok: $DEST/openlist"
"$DEST/openlist" version 2>&1 | sed -n 's/^Version: */    version /p'
ls -l "$DEST/openlist" | awk '{printf "    size %.1f MB\n", $5/1e6}'
echo "    sha256 $(cat "$DEST/openlist.sha256")"
