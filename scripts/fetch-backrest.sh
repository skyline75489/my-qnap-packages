#!/usr/bin/env bash
# Fetch the pinned Backrest release binary and its restic helper into
# packages/backrest/x86_64/.
#
# Two payloads, two upstreams, both checksum-verified against files published
# by the projects themselves:
#
#   backrest  github.com/garethgeorge/backrest  (GPL-3.0) — static Go binary
#   restic    github.com/restic/restic          (BSD-3)  — static Go binary
#
# restic is shipped rather than left to Backrest because Backrest downloads a
# restic binary on first start if it cannot find one. This package must never
# reach out to the internet at runtime.
#
# Both binaries are statically linked, so the NAS's glibc 2.21 is not a
# constraint here — see docs/qpkg-service-packaging.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKREST_VERSION="${BACKREST_VERSION:-v1.14.1}"
# The restic version Backrest requires. Keep in step with
# RequiredResticVersion in upstream internal/resticinstaller/resticinstaller.go.
RESTIC_VERSION="${RESTIC_VERSION:-0.19.1}"
DEST="$REPO_ROOT/packages/backrest/x86_64"

# The only architecture this package targets. QTS reports uname -m = x86_64.
ASSET="backrest_Linux_x86_64.tar.gz"

die(){ echo "error: $*" >&2; exit 1; }

mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- backrest
BASE="https://github.com/garethgeorge/backrest/releases/download/${BACKREST_VERSION}"

echo "==> backrest $BACKREST_VERSION ($ASSET)"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/checksums" \
    "$BASE/backrest_${BACKREST_VERSION#v}_checksums.txt" \
    || die "could not fetch the checksum file"

WANT=$(awk -v a="$ASSET" '{ n=$2; sub(/^\*/,"",n); if (n==a) { print $1; exit } }' "$TMP/checksums")
[ -n "$WANT" ] || die "no checksum entry for $ASSET in backrest_${BACKREST_VERSION#v}_checksums.txt"
echo "    expected sha256: $WANT"

# The published checksum covers the tarball, not the extracted binary, so the
# tarball is always re-downloaded and re-verified rather than trusting a
# binary left over from an earlier run.
echo "    downloading $ASSET"
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TMP/$ASSET" "$BASE/$ASSET" \
    || die "download failed — retry, or set HTTPS_PROXY"

GOT=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || die "checksum mismatch: got $GOT want $WANT"

tar xzf "$TMP/$ASSET" -C "$TMP" backrest || die "tarball does not contain 'backrest'"
install -m 0755 "$TMP/backrest" "$DEST/backrest"

# The binary must actually run here; a wrong-arch asset would not.
"$DEST/backrest" --version >/dev/null 2>&1 || die "fetched backrest binary does not execute on this host"

# ------------------------------------------------------------------ restic
RBASE="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}"
RBZ2="restic_${RESTIC_VERSION}_linux_amd64.bz2"

echo "==> restic $RESTIC_VERSION ($RBZ2)"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/SHA256SUMS" "$RBASE/SHA256SUMS" \
    || die "could not fetch restic SHA256SUMS"

RWANT=$(awk -v a="$RBZ2" '{ n=$2; sub(/^\*/,"",n); if (n==a) { print $1; exit } }' "$TMP/SHA256SUMS")
[ -n "$RWANT" ] || die "no checksum entry for $RBZ2 in restic SHA256SUMS"
echo "    expected sha256: $RWANT"

echo "    downloading $RBZ2"
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TMP/$RBZ2" "$RBASE/$RBZ2" \
    || die "restic download failed — retry, or set HTTPS_PROXY"

RGOT=$(sha256sum "$TMP/$RBZ2" | awk '{print $1}')
[ "$RGOT" = "$RWANT" ] || die "restic checksum mismatch: got $RGOT want $RWANT"

# bunzip2 is not a given on a build host (the linuxbrew one on this host is
# broken), and python3 is already a dependency of the test harness, so
# decompress with python3.
python3 - "$TMP/$RBZ2" "$TMP/restic" <<'PY'
import bz2, hashlib, sys
src, dst = sys.argv[1], sys.argv[2]
data = bz2.decompress(open(src, 'rb').read())
open(dst, 'wb').write(data)
print("    decompressed sha256:", hashlib.sha256(data).hexdigest())
PY

install -m 0755 "$TMP/restic" "$DEST/restic"
"$DEST/restic" version >/dev/null 2>&1 || die "fetched restic binary does not execute on this host"

# ------------------------------------------------------------------ report
echo
echo "==> ok: $DEST"
"$DEST/backrest" --version 2>&1 | sed -n 's/^backrest version: \(.*\)$/    backrest \1/p'
"$DEST/restic" version 2>&1 | sed -n 's/^restic \(.*\)$/    restic \1/p'
for f in backrest restic; do
    ls -l "$DEST/$f" | awk -v n="$f" '{printf "    %-9s %6.1f MB\n", n, $5/1e6}'
done
