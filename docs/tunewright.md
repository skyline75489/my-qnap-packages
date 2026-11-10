# The Tunewright package

Tunewright is a self-hosted web app for batch-editing audio file metadata: tags,
cover art, filenames, and MusicBrainz/Apple Music lookup. Upstream ships it as a
single Docker container with no database.

This package runs it on the NAS as a native binary: a statically linked Rust server
plus the SvelteKit SPA it serves. No Container Station, no runtime downloads.

## Using this package as the Rust template

The general method lives in [qpkg-service-packaging.md](qpkg-service-packaging.md)
— §2.5 (a project with no release artifact), §3.4 (building Rust statically
against musl). This package is the worked example of both, so the parts worth
copying are:

| Step | Here |
|---|---|
| Upstream publishes nothing to download | `scripts/fetch-tunewright.sh` pins commit `247e890` and asserts it (§2.5) |
| Build the server statically | `cargo build --release --locked --target x86_64-unknown-linux-musl` with a musl C toolchain (§3.4) |
| Build the frontend | `pnpm install --frozen-lockfile && pnpm run build`; the result is a directory of static files |
| Ship both, one process | `x86_64/tunewright` + `x86_64/static/`, the server pointed at the SPA with `TUNEWRIGHT_STATIC_DIR` |
| Configuration | environment variables only; the service script is the whole configuration layer |
| State | the user's own files stay outside the package; the account database goes in `$QPKG_ROOT/data/state` |
| First-run safety | the app's own one-time setup token, surfaced by the service script's log |
| Verification | `scripts/test-tunewright.sh` — 81 assertions, the Rust-specific ones being the static linkage, the absence of a dynamic interpreter, and the SPA actually being served |

## Upstream facts that shaped the package

| Fact | Consequence |
|---|---|
| The project publishes **no release artifacts** — only a Docker image (`ghcr.io/krabhi4/tunewright`), and the repository has no GitHub releases | There is nothing to download and verify. The package builds the upstream source at a pinned commit. See below. |
| The backend is Rust (axum + tokio), the frontend is a SvelteKit SPA built with `adapter-static` | The SPA is a directory of static files. It ships as-is and the server serves it — no second process, no reverse proxy. |
| The dependency tree is pure Rust plus `ring` (TLS via rustls) | No OpenSSL, no ffmpeg, no database server. A fully static build is possible. |
| Configuration is entirely environment variables | The service script is the configuration layer; there is no config file format to parse. |
| The server traps SIGINT and SIGTERM and drains connections for up to 25 s | `stop` sends SIGTERM and waits; a second signal makes it exit immediately. |
| Until the first admin account exists, `/api/v1/auth/setup` hands the account to the first caller | The app generates a one-time setup token when it binds a non-loopback address. The service script logs where to find it. |

## Building from source, and verifying that

`docs/publishing.md` and the other packages rely on an upstream checksum file to
prove the payload is the thing upstream published. Tunewright has no such file, so
the check is different: the build pins a **commit**, not a branch or a tag.

`scripts/fetch-tunewright.sh`:

1. clones the repository,
2. checks out the pinned commit by SHA and asserts `git rev-parse HEAD` is exactly
   that SHA (a branch could move under it; a SHA cannot),
3. asserts the upstream `Cargo.toml` version matches the version the package
   claims, so the App Center cannot show a version that is not what is inside,
4. builds the server and the frontend,
5. asserts the resulting binary is statically linked and runs it.

What this does **not** prove: that the commit is upstream's work rather than
somebody's. The pin is a review question for a human, and the commit URL is in
`SOURCE.txt` and in the release notes for exactly that reason.

The other packages fetch a prebuilt binary; this one compiles it. The build-host
requirements are therefore higher: rustup with the `x86_64-unknown-linux-musl`
target, a musl C toolchain, node ≥ 20 and pnpm 12. The script checks for each of
them and prints the exact command to install what is missing.

## Static musl instead of a glibc build

The NAS runs glibc 2.21 (QTS pins it deliberately). A Rust binary built on a modern
host against a modern glibc would not load there — the usual fix is to build in an
old container.

The better answer here is to remove the constraint: build against **musl** and link
statically. The result has no dynamic interpreter and no libc dependency at all, so
it runs on any Linux, whatever its glibc. The test harness asserts this
(`file` says "statically linked", `readelf` finds no interpreter) rather than
assuming it.

Two details that are easy to get wrong:

- `ring` compiles C code, so the C compiler must be musl's (`musl-gcc`), not the
  host's gcc — otherwise the C objects are built against glibc headers and linked
  into a musl binary.
- rust's musl target ships `libc.a` and the crt objects but **no headers**, and
  it wants a `libunwind.a` that is not in the host's search path. The build points
  `-C link-self-contained=no` at the target's own `self-contained` directory for
  the latter.

musl itself is built from source into `~/.local/musl` by the build instructions in
the script — no root required, which matters because a build host is not usually
root.

## Ports

8081. It is not used by QTS itself (5000 is the QTS portal, hence not 5000 here)
and collides with nothing else this NAS runs (5050 zot, 5244 OpenList, 9898
Backrest).

The port lives in two places that must agree: `QPKG_SERVICE_PORT`/`QPKG_WEB_PORT`
in `qpkg.cfg` — which is what the App Center's "Web UI" link uses — and
`PORT=` in `tunewright.conf`. The service script reads `Web_Port` from
`/etc/config/qpkg.conf` and lets `tunewright.conf` override it, so the two can be
changed in one place.

## Paths

| What | Where | Why |
|---|---|---|
| The music library | `MUSIC_DIR` in `tunewright.conf`, default `/share/Multimedia/Music` | The app's data directory. It is the user's own files, so it is deliberately **not** under `$QPKG_ROOT`. On this NAS it is `/share/Audio/Music` — see `docs/nas-topology.md`. |
| The account database | `TUNEWRIGHT_STATE_DIR`, default `$QPKG_ROOT/data/state` | `users.json` and `mcp_auth.json`. Keeping them out of the music library matters: the library is a media folder, and a NAS with a file browser would show `users.json` sitting in the user's music. |
| The SPA | `TUNEWRIGHT_STATIC_DIR` = `$QPKG_ROOT/static` | Ships inside the package, so there is no runtime download and no missing-assets failure mode. |
| Logs | `$QPKG_ROOT/data/log/tunewright.log` | Rotated by a daily cron job at a 10 MB ceiling. |
| `TMPDIR` | `$QPKG_ROOT/data/tmp` | QTS's `/tmp` is a small tmpfs. |

`STATE_DIR` in `tunewright.conf` can be pointed outside the package if the
accounts should survive an uninstall: `$QPKG_ROOT/data` is wiped on uninstall
(`rsync --delete` + `rm -rf`), which is fine for logs and caches but not for a
password database.

## The first admin account

Upstream's first-run flow is a race: whoever reaches `/api/v1/auth/setup` first
becomes the super-admin. Upstream guards it — when the server binds a
non-loopback address and no `TUNEWRIGHT_SETUP_TOKEN` is set, it generates a random
token, prints it to the log and requires it. That behaviour is kept as it is; the
package only makes sure the token is *findable*: the service script logs the
configuration at every start, and the harness asserts that setup without the token
is refused with 403 and with it succeeds.

Setting `SETUP_TOKEN=` in `tunewright.conf` pins the token to a value of your own.

## The service runs as root

QTS runs a package's service script as root, and the app is handed the music
library to write tags into. Files the app rewrites may therefore end up
root-owned, which is a nuisance in a media share.

Dropping privileges to the library's owner would fix that, but it is not
implemented here: the ownership of the library is not known at install time (the
volume is chosen by the admin), and a wrong drop is worse than root. This is
recorded as an open item in the package README, not silently ignored.

## What is not covered

- The package **is installed and enabled** on the NAS (2026-11-10). Verified from
  the LAN: `/api/v1/health` returns `{"status":"ok","version":"1.2.0"}` and `/`
  answers 200 `text/html` — the static musl binary loaded on glibc 2.21 and is
  serving the SPA that shipped inside the package. App Center reports 1.2.0,
  installed, enabled, status *complete*.
- Tag *writing* was not exercised by the harness — it reads (listing, auth),
  because writing touches the user's own files.
- The MusicBrainz and Apple Music lookups need a CA bundle on the NAS; the
  service script warns at start if it cannot find one, but the lookups themselves
  were not run against the real services.
- The MCP endpoint (`/mcp`, with its OAuth dance) ships but is untested.
- The upstream Docker image runs as uid 65532. This package runs as root — see
  above.
