#!/usr/bin/env bash
# Fetch the pinned PicoClaw release binaries into packages/picoclaw/x86_64/.
#
# Upstream: github.com/sipeed/picoclaw (MIT) — "Tiny, Fast, and Deployable
# anywhere", a personal AI assistant written in Go.
#
# The release tarball carries TWO binaries and they belong together:
#
#   picoclaw           the CLI/agent — `picoclaw agent`, `picoclaw gateway`
#   picoclaw-launcher  the web console and gateway manager, which is the
#                      long-running process a service package wants
#
# The launcher finds the CLI next to itself, so both are installed side by
# side in the package root. The tarball is checksum-verified against the
# checksums file the project publishes with every release.
#
# Both binaries are statically linked (CGO_ENABLED=0 upstream), so the NAS's
# glibc 2.21 is not a constraint here — see docs/qpkg-service-packaging.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICOCLAW_VERSION="${PICOCLAW_VERSION:-v0.3.1}"
DEST="$REPO_ROOT/packages/picoclaw/x86_64"
SHARED="$REPO_ROOT/packages/picoclaw/shared"

# The only architecture this package targets. QTS reports uname -m = x86_64.
ASSET="picoclaw_Linux_x86_64.tar.gz"

die(){ echo "error: $*" >&2; exit 1; }

mkdir -p "$DEST" "$SHARED"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/sipeed/picoclaw/releases/download/${PICOCLAW_VERSION}"
SHORT="${PICOCLAW_VERSION#v}"

echo "==> picoclaw $PICOCLAW_VERSION ($ASSET)"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$TMP/checksums" \
    "$BASE/picoclaw_${SHORT}_checksums.txt" \
    || die "could not fetch the checksum file"

WANT=$(awk -v a="$ASSET" '{ n=$2; sub(/^\*/,"",n); if (n==a) { print $1; exit } }' "$TMP/checksums")
[ -n "$WANT" ] || die "no checksum entry for $ASSET in picoclaw_${SHORT}_checksums.txt"
echo "    expected sha256: $WANT"

echo "    downloading $ASSET"
# --retry-all-errors matters here: a plain --retry does not retry an SSL
# "unexpected eof while reading", which is how a long download through a
# proxy tends to die. -C - lets a retry resume instead of starting over.
curl -fL --retry 5 --retry-all-errors --retry-delay 3 -C - \
     --progress-bar -o "$TMP/$ASSET" "$BASE/$ASSET" \
    || die "download failed — retry, or set HTTPS_PROXY"

GOT=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
[ "$GOT" = "$WANT" ] || die "checksum mismatch: got $GOT want $WANT"

tar xzf "$TMP/$ASSET" -C "$TMP" \
    picoclaw picoclaw-launcher LICENSE \
    || die "tarball does not contain picoclaw, picoclaw-launcher and LICENSE"

install -m 0755 "$TMP/picoclaw"          "$DEST/picoclaw"
install -m 0755 "$TMP/picoclaw-launcher" "$DEST/picoclaw-launcher"

# The upstream licence travels with the binaries: MIT.
install -m 0644 "$TMP/LICENSE" "$SHARED/LICENSE"

# Both binaries must actually run here; a wrong-arch asset would not.
"$DEST/picoclaw" version >/dev/null 2>&1 \
    || die "fetched picoclaw binary does not execute on this host"
"$DEST/picoclaw-launcher" --help >/dev/null 2>&1 \
    || die "fetched picoclaw-launcher binary does not execute on this host"

# The whole point of the glibc constraint: these must be static, or the NAS
# (glibc 2.21) cannot load them. Checked here so the failure is at fetch
# time rather than on the NAS.
if command -v file >/dev/null 2>&1; then
    for b in picoclaw picoclaw-launcher; do
        file -b "$DEST/$b" | grep -q 'statically linked' \
            || die "$b is not statically linked: $(file -b "$DEST/$b")"
    done
fi

# ------------------------------------------------------------------ report
echo
echo "==> ok: $DEST"
"$DEST/picoclaw" version 2>&1 | sed -n 's/^🦞 picoclaw \(.*\)$/    picoclaw \1/p'
for f in picoclaw picoclaw-launcher; do
    ls -l "$DEST/$f" | awk -v n="$f" '{printf "    %-18s %6.1f MB\n", n, $5/1e6}'
done
