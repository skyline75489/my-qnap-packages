#!/usr/bin/env bash
# Build the zot .qpkg with QNAP's qbuild.
#
# qbuild is not packaged for Fedora; .tools/QDK is the upstream QDK source
# tree. Its repo layout differs from the installed layout, so QDK_SCRIPTS_DIR
# and QDK_TEMPLATE_DIR have to be pointed at shared/ explicitly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QDK="${QDK_PATH:-$REPO_ROOT/.tools/QDK}"
PKG_DIR="$REPO_ROOT/packages/zot"

die(){ echo "error: $*" >&2; exit 1; }

[ -x "$QDK/shared/bin/qbuild" ] || die "qbuild not found at $QDK/shared/bin/qbuild
  fetch it with:
    mkdir -p .tools && gh api repos/qnap-dev/QDK/tarball/master > .tools/qdk.tar.gz
    mkdir -p .tools/QDK && tar xzf .tools/qdk.tar.gz -C .tools/QDK --strip-components=1"

[ -f "$PKG_DIR/x86_64/zot" ] || die "payload missing: run scripts/fetch-zot.sh first"

export QDK_SCRIPTS_DIR="$QDK/shared/scripts"
export QDK_TEMPLATE_DIR="$QDK/shared/template"

# qbuild shells out to `qpkg_encrypt` to append the QPKG header checksum. On a
# NAS that binary is /sbin/qpkg; on a Linux build host it has to be compiled
# from QDK's src/. Without it the package is written without its checksum and
# QTS will reject the install.
if [ ! -x "$QDK/src/bin/qpkg_encrypt" ] && [ ! -x "/sbin/qpkg" ]; then
    echo "==> building qpkg_encrypt"
    ( cd "$QDK/src" && make ) || die "could not build qpkg_encrypt"
fi
export PATH="$QDK/src/bin:$PATH"

# Icons are optional — qbuild substitutes defaults when icons/ is absent.
cd "$PKG_DIR"

echo "==> qbuild ($("$QDK/shared/bin/qbuild" -V))"
rm -rf build

# --strict: a truncated QPKG_VER or a missing service program should fail the
# build rather than ship a subtly broken package.
"$QDK/shared/bin/qbuild" --strict "$@" || die "qbuild failed"

echo
ls -l build/*.qpkg 2>/dev/null | awk '{printf "==> %s (%.1f MB)\n", $9, $5/1e6}'
