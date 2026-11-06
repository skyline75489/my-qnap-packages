#!/usr/bin/env bash
# Publish a built .qpkg as a GitHub release.
#
#   scripts/release.sh <package> [--repo owner/name] [--tag TAG]
#                                   [--title TITLE] [--notes FILE]
#                                   [--dry-run] [--yes]
#
# A GitHub release is just a set of downloadable assets, so a .qpkg needs no
# special handling: it is uploaded as a file. What this script adds is the part
# that is easy to get wrong:
#
#   * it refuses to publish a package whose harness has not passed
#   * it publishes a sha256 of the exact artifact, because QPKG builds are NOT
#     reproducible and a "reproducible" digest would be a lie
#   * it states the upstream project, version and licence in the release notes,
#     and ships the upstream licence text and a source pointer inside the
#     package, which is what the GPL/AGPL require of a redistributor
#   * it asks before doing something irreversible and public
#
# Requires the GitHub CLI, authenticated:
#   gh auth login
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PKG=""
REPO=""
TAG=""
TITLE=""
NOTES=""
DRY_RUN=0
ASSUME_YES=0

die(){ echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   REPO=${2:?--repo needs owner/name}; shift 2 ;;
        --tag)    TAG=${2:?--tag needs a value}; shift 2 ;;
        --title)  TITLE=${2:?--title needs a value}; shift 2 ;;
        --notes)  NOTES=${2:?--notes needs a file}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)  [ -z "$PKG" ] || die "unexpected argument: $1"; PKG=$1; shift ;;
    esac
done

[ -n "$PKG" ] || die "usage: scripts/release.sh <package> [options]"
PKG_DIR="$REPO_ROOT/packages/$PKG"
[ -d "$PKG_DIR" ] || die "no such package: $PKG"

# ---------------------------------------------------------------- inputs
# Version and port come from the package's own qpkg.cfg, so the release notes
# cannot drift from what was actually packaged.
cfgval(){ sed -n "s/^$1=\"\\(.*\\)\"/\\1/p" "$PKG_DIR/qpkg.cfg" | head -1; }
VERSION=$(cfgval QPKG_VER)
PORT=$(cfgval QPKG_SERVICE_PORT)
LICENCE=$(cfgval QPKG_LICENSE)
NAME=$(cfgval QPKG_NAME)
SRC="$PKG_DIR/shared/SOURCE.txt"
[ -f "$SRC" ] || die "missing $SRC — the release notes need the upstream source pointer"

srcval(){ sed -n "s/^$1:[[:space:]]*//p" "$SRC" | head -1; }
UP_NAME=$(srcval name);      UP_VER=$(srcval version)
UP_URL=$(srcval url);        UP_TAG=$(srcval tag_url)
UP_LIC=$(srcval licence);    UP_PAYLOAD=$(srcval payload)
UP_HELPER=$(srcval helper);  UP_HELPER_URL=$(srcval helper_url)
UP_HELPER_LIC=$(srcval helper_licence)

[ -n "$VERSION" ] || die "could not read QPKG_VER from $PKG_DIR/qpkg.cfg"
[ -n "$UP_VER" ] || die "could not read version from $SRC"

[ -n "$REPO" ] || REPO=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's#^(https://|git@)github.com[:/]#https://github.com/#; s#\.git$##')
[ -n "$REPO" ] || die "no repository: pass --repo owner/name"
REPO_SLUG=${REPO#https://github.com/}
REPO_SLUG=${REPO_SLUG%.git}

[ -n "$TAG" ] || TAG="$PKG-$VERSION"
[ -n "$TITLE" ] || TITLE="$NAME $VERSION — QPKG for QNAP QTS"

# The artifact. Refuse to publish something that was not built here.
QPKG=$(ls -1t "$PKG_DIR"/build/*.qpkg 2>/dev/null | head -1)
[ -n "$QPKG" ] || die "no .qpkg in $PKG_DIR/build — run scripts/build-qpkg.sh $PKG first"

# The harness is the gate. Publishing something unverified is exactly the
# failure mode this repo exists to prevent.
case "$PKG" in
    zot)      HARNESS="$REPO_ROOT/scripts/test-package.sh" ;;
    openlist) HARNESS="$REPO_ROOT/scripts/test-openlist.sh" ;;
    *)        HARNESS="$REPO_ROOT/scripts/test-$PKG.sh" ;;
esac
if [ -x "$HARNESS" ]; then
    echo "==> verifying with $(basename "$HARNESS")"
    if ! "$HARNESS" "$QPKG" > /tmp/release-harness.$$ 2>&1; then
        cat /tmp/release-harness.$$
        rm -f /tmp/release-harness.$$
        die "harness failed — refusing to publish"
    fi
    rm -f /tmp/release-harness.$$
    echo "    ok: $(basename "$HARNESS") passed"
else
    die "no harness at $HARNESS — refusing to publish unverified"
fi

# A public release is redistribution. The package must carry the upstream
# licence text and name the upstream source it was built from; the GPL and AGPL
# require both of the recipient of the binary.
PAYLOAD_MEMBER="./$(echo "$PKG" | tr '[:upper:]' '[:lower:]')"
MISSING=$(python3 - "$QPKG" "$PAYLOAD_MEMBER" <<'PY'
import sys, zlib, io, tarfile
pkg, marker = sys.argv[1], sys.argv[2]
d = open(pkg, 'rb').read()
offs, i = [], 0
while True:
    j = d.find(b'\x1f\x8b\x08', i)
    if j < 0: break
    offs.append(j); i = j + 1
for off in offs:
    try:
        o = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out = o.decompress(d[off:]) + o.flush()
        if not o.eof: continue
        names = set(tarfile.open(fileobj=io.BytesIO(out)).getnames())
        if marker in names:
            print(' '.join(sorted({'./LICENSE', './SOURCE.txt'} - names)))
            break
    except Exception:
        continue
PY
)
[ -z "$MISSING" ] || die "the package does not ship $MISSING — refusing to publish a copyleft binary without its licence and source pointer"

SHA=$(sha256sum "$QPKG" | awk '{print $1}')
BASE=$(basename "$QPKG")
SHA_FILE="$REPO_ROOT/packages/$PKG/build/$BASE.sha256"
printf '%s  %s\n' "$SHA" "$BASE" > "$SHA_FILE"

# ---------------------------------------------------------------- notes
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT

# Backticks inside double quotes would be command substitution; the fence is
# used as a variable instead.
FENCE='```'

if [ -n "$NOTES" ]; then
    cp "$NOTES" "$NOTES_FILE"
else
    {
        echo "## $NAME $VERSION — native-binary QPKG for QNAP QTS"
        echo
        echo "Installs as a QTS app: no Container Station, and nothing is downloaded"
        echo "at install or run time."
        echo
        echo "| | |"
        echo "|---|---|"
        echo "| Upstream | [$UP_NAME $UP_VER]($UP_URL) |"
        echo "| Upstream release | $UP_TAG |"
        echo "| Licence | $UP_LIC |"
        echo "| Architecture | x86_64 |"
        echo "| Requires | QTS 5.0.0+ (glibc 2.21) |"
        echo "| Port | $PORT |"
        echo "| Payload | $UP_PAYLOAD |"
        [ -n "$UP_HELPER" ] && echo "| Bundled helper | $UP_HELPER — $UP_HELPER_LIC |"
        echo
        echo "### Verify before installing"
        echo
        echo "$FENCE"sh
        echo "sha256sum -c $BASE.sha256"
        echo "$FENCE"
        echo
        echo "\`$BASE.sha256\` is the digest of the file in this release. QPKG builds are"
        echo "**not reproducible** — two builds of identical sources differ slightly — so"
        echo "this digest identifies *this* artifact, not a canonical build."
        echo
        echo "### Install"
        echo
        echo "1. App Center → Settings → *Allow installation of applications without a"
        echo "   valid digital signature* (these packages are unsigned)."
        echo "2. App Center → *Install* → upload the \`.qpkg\`."
        echo "3. Open the app's page and press *Start*. The service listens on port"
        echo "   $PORT."
        echo
        echo "### What is in the package"
        echo
        echo "The upstream licence text ships inside the package as \`LICENSE\`,"
        echo "and \`SOURCE.txt\` names the exact upstream version it was built from."
        if [ -n "$UP_HELPER" ]; then
            echo
            echo "The package also bundles $UP_HELPER, because the application would"
            echo "otherwise download it at first start. Its source is $UP_HELPER_URL"
            echo "($UP_HELPER_LIC)."
        fi
        echo
        echo "---"
        echo
        echo "Packaging method and build instructions:"
        echo "<https://github.com/$REPO_SLUG>"
    } > "$NOTES_FILE"
fi

# ---------------------------------------------------------------- publish
echo
echo "==> release"
echo "    repository: $REPO_SLUG"
echo "    tag:        $TAG"
echo "    title:      $TITLE"
echo "    asset:      $BASE ($(du -h "$QPKG" | cut -f1))"
echo "    sha256:     $SHA"

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "==> dry run; release notes would be:"
    echo
    cat "$NOTES_FILE"
    exit 0
fi

command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    printf "Publish to https://github.com/%s/releases/tag/%s ? [y/N] " "$REPO_SLUG" "$TAG"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) die "aborted" ;;
    esac
fi

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "==> release $TAG exists, replacing its assets"
    gh release upload "$TAG" "$QPKG" "$SHA_FILE" --repo "$REPO_SLUG" --clobber
    gh release edit "$TAG" --repo "$REPO_SLUG" --title "$TITLE" --notes-file "$NOTES_FILE"
else
    echo "==> creating release $TAG"
    gh release create "$TAG" "$QPKG" "$SHA_FILE" \
        --repo "$REPO_SLUG" --title "$TITLE" --notes-file "$NOTES_FILE" \
        --target "${TARGET_BRANCH:-main}"
fi

echo
echo "==> published"
gh release view "$TAG" --repo "$REPO_SLUG" 2>/dev/null | sed -n 's/^ *URL: */    /p' | head -1
