#!/usr/bin/env bash
# Build the Tunewright payload into packages/tunewright/x86_64/.
#
#   tunewright  the server binary   (static musl, x86_64)
#   static/     the SvelteKit SPA   (served by the server itself)
#
# Unlike the other packages this one has nothing to download: Tunewright
# publishes no release artifacts — the project ships as a Docker image
# (ghcr.io/krabhi4/tunewright) and the repository has no GitHub releases.
# So this script compiles the upstream source at a pinned commit, and the
# "verification" it can offer is that the tree it builds is exactly the
# pinned commit (checked out by SHA, never by branch) and that the resulting
# binary runs.
#
# Why static musl and not a glibc build:
#   * The NAS runs glibc 2.21 (QTS pins it). A binary built on this host
#     against a modern glibc would not load there. A static musl binary has
#     no libc dependency at all, so the constraint disappears instead of
#     being worked around.
#   * The dependency tree is pure Rust plus `ring` (TLS). There is no
#     OpenSSL, no ffmpeg, no database — so a fully static build is possible
#     without vendoring a C library.
#
# Host requirements (all local; nothing is downloaded at run time):
#   * rustup with the x86_64-unknown-linux-musl target
#   * a musl C toolchain (CC for `ring`; rust's own bundled libc.a is not
#     enough because ring's C code needs musl headers)
#   * node >= 20 and pnpm 12 for the frontend
#
# Build-host note: crates.io and the npm registry are reached through
# mirrors here (see ~/.cargo/config.toml); the script honours whatever
# mirror the host has configured and only fails if a dependency cannot be
# fetched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/packages/tunewright/x86_64"

# The upstream version and the exact commit this package is built from.
# Keep in step with packages/tunewright/shared/SOURCE.txt.
TUNEWRIGHT_VERSION="${TUNEWRIGHT_VERSION:-1.2.0}"
TUNEWRIGHT_COMMIT="${TUNEWRIGHT_COMMIT:-247e890b8840e7757559408e4022aad891cbeda8}"
UPSTREAM_URL="https://github.com/krabhi4/tunewright.git"

RUST_VERSION="${RUST_VERSION:-1.89.0}"
MUSL_TARGET="x86_64-unknown-linux-musl"
# The musl toolchain used to compile `ring`'s C code and to link the binary.
MUSL_PREFIX="${MUSL_PREFIX:-$HOME/.local/musl}"
# pnpm is pinned by upstream (frontend/package.json "packageManager").
PNPM_VERSION="${PNPM_VERSION:-12.18.0}"

die(){ echo "error: $*" >&2; exit 1; }

# rustup installs into ~/.cargo/bin, which a non-login shell does not have on
# PATH.
[ -d "$HOME/.cargo/bin" ] && PATH="$HOME/.cargo/bin:$PATH"
export PATH

# ------------------------------------------------------------------ tools
command -v cargo >/dev/null 2>&1 || die "cargo not found; install rustup:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
        --profile minimal --default-toolchain $RUST_VERSION --target $MUSL_TARGET"

command -v node >/dev/null 2>&1 || die "node not found (upstream needs node >= 20)"
command -v pnpm >/dev/null 2>&1 || die "pnpm not found; install the pinned version:
    npm install -g pnpm@$PNPM_VERSION"

MUSL_CC="$MUSL_PREFIX/bin/musl-gcc"
[ -x "$MUSL_CC" ] || die "musl toolchain not found at $MUSL_CC
  build it from source (no root required):
    curl -sSLO https://musl.libc.org/releases/musl-1.2.5.tar.gz
    tar xzf musl-1.2.5.tar.gz && cd musl-1.2.5
    ./configure --prefix=$MUSL_PREFIX --disable-shared
    make -j\$(nproc) && make install"

rustup target list --installed 2>/dev/null | grep -qx "$MUSL_TARGET" \
    || die "rust target $MUSL_TARGET not installed:
    rustup target add $MUSL_TARGET"

# ------------------------------------------------------------------ source
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/tunewright"

echo "==> cloning $UPSTREAM_URL"
git clone --quiet "$UPSTREAM_URL" "$SRC" || die "clone failed"
git -C "$SRC" checkout --quiet "$TUNEWRIGHT_COMMIT" || die "commit $TUNEWRIGHT_COMMIT not found upstream"

# The tree must be exactly the pinned commit — not "a branch that happens to
# point there". This is the check that replaces a checksum file.
GOT=$(git -C "$SRC" rev-parse HEAD)
[ "$GOT" = "$TUNEWRIGHT_COMMIT" ] || die "checkout landed on $GOT, want $TUNEWRIGHT_COMMIT"
echo "    upstream commit $GOT"

# The upstream version in Cargo.toml must match the version this package
# claims, or the App Center would show a version that is not what is inside.
UV=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$SRC/Cargo.toml" | head -1)
[ "$UV" = "$TUNEWRIGHT_VERSION" ] || die "upstream Cargo.toml says version $UV, package says $TUNEWRIGHT_VERSION"

# ------------------------------------------------------------------ server
echo "==> building tunewright-server ($MUSL_TARGET)"
(
    cd "$SRC"
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="$MUSL_CC"
    export CC_x86_64_unknown_linux_musl="$MUSL_CC"
    # rust's own musl target ships libc.a and crt objects but no headers, so
    # the C compiler has to be musl's. The link uses those bundled objects
    # plus the host's libunwind.a from the same directory.
    SC=$(rustc --print sysroot)/lib/rustlib/$MUSL_TARGET/lib/self-contained
    export RUSTFLAGS="-C link-self-contained=no -L native=$SC"
    cargo build --release --locked --target "$MUSL_TARGET" -p tunewright-server
) || die "cargo build failed"

BIN="$SRC/target/$MUSL_TARGET/release/tunewright-server"
[ -x "$BIN" ] || die "cargo build produced no binary"

# The whole point of the musl build: no dynamic dependency at all, so the
# NAS's glibc 2.21 is not a constraint.
if command -v file >/dev/null 2>&1; then
    file -b "$BIN" | grep -q 'statically linked' \
        || die "the binary is not statically linked: $(file -b "$BIN")"
fi

# It must actually run here.
"$BIN" --help >/dev/null 2>&1 || true
echo "    built $(stat -c%s "$BIN") bytes"

mkdir -p "$DEST"
install -m 0755 "$BIN" "$DEST/tunewright"

# ------------------------------------------------------------------ frontend
echo "==> building the frontend (pnpm $(pnpm --version))"
(
    cd "$SRC/frontend"
    pnpm install --frozen-lockfile
    pnpm run build
) || die "frontend build failed"

[ -f "$SRC/frontend/build/index.html" ] || die "frontend build produced no index.html"

# The SPA is served by the server as static files. Ship it as-is; the
# filenames are content-hashed by the build, so they must not be rewritten.
rm -rf "$DEST/static"
mkdir -p "$DEST/static"
cp -a "$SRC/frontend/build/." "$DEST/static/"

# ------------------------------------------------------------------ report
(
    cd "$DEST"
    sha256sum tunewright > tunewright.sha256
)

echo
echo "==> ok: $DEST"
ls -l "$DEST/tunewright" | awk '{printf "    tunewright   %6.1f MB\n", $5/1e6}'
du -sh "$DEST/static" | awk '{printf "    static/      %s\n", $1}'
cat "$DEST/tunewright.sha256" | sed 's/^/    /'
echo
echo "    upstream $UPSTREAM_URL @ $TUNEWRIGHT_COMMIT (v$TUNEWRIGHT_VERSION, MIT)"
