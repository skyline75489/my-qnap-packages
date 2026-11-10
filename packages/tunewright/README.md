# packages/tunewright — the Tunewright QPKG

Native-binary QPKG for the QNAP NAS. There is no Container Station dependency and
nothing is downloaded at install time — or at run time.

Decisions behind it: [`../../docs/tunewright.md`](../../docs/tunewright.md).

## Layout

```
qpkg.cfg                 metadata: name/version, service script, port 8081, volume select 3
package_routines         install hooks (data dirs, chown, cron) + pre-remove (stop, cron)
shared/tunewright.conf   the app config: music library, port, bind address, setup token
shared/tunewright.sh     start|stop|restart|status|rotate|remove
shared/LICENSE           the upstream MIT licence text
shared/SOURCE.txt        the exact upstream commit this package was built from
icons/                   Tunewright.gif 64x64, Tunewright_gray.gif 64x64, Tunewright_80.gif 80x80
x86_64/tunewright        the server binary; built, never committed
x86_64/static/           the SvelteKit SPA the server serves; built, never committed
```

Icons are generated from the upstream favicon (`frontend/static/favicon.svg`, MIT) by
`scripts/make-icons.sh`, in its light-mode colours and flattened onto white so the
mark stays visible on a dark App Center theme.

`shared/` lands at `$SYS_QPKG_DIR`, so `tunewright.conf` is protected by
`QPKG_CONFIG="tunewright.conf"` (`.qdkorig`/`.qdksave` on upgrade: your edited
config is kept, a pristine one is replaced) and `tunewright.sh` is the
`QPKG_SERVICE_PROGRAM`.

## One program, not two

Tunewright upstream is a Rust server plus a SvelteKit frontend, shipped as a Docker
image with the frontend baked into `/srv/static`. This package does the same thing
without a container: the server binary is in `x86_64/` and the built SPA is in
`x86_64/static/`, and the service script points `TUNEWRIGHT_STATIC_DIR` at it. The
server serves the SPA and the REST API on the same port, so there is no second
process and no reverse proxy.

## Built from source, statically linked

Upstream publishes **no release artifacts** — the project is distributed as a Docker
image and the repository has no GitHub releases. So `scripts/fetch-tunewright.sh`
clones the repository, checks out the pinned commit, and builds both halves:

- the server with `cargo build --release --target x86_64-unknown-linux-musl`
- the frontend with `pnpm install --frozen-lockfile && pnpm run build`

The binary is **statically linked** against musl, so the NAS's glibc 2.21 is not a
constraint at all: the file has no dynamic interpreter and no libc dependency. That
is possible because the dependency tree is pure Rust plus `ring` (TLS) — there is no
OpenSSL, no ffmpeg and no database server. The test harness asserts the static
linkage and the absence of a dynamic interpreter rather than assuming them.

`fetch-tunewright.sh` verifies what it can: the tree it builds is exactly the pinned
commit (checked out by SHA, never by branch), the upstream `Cargo.toml` version
matches the version the package claims, and the built binary runs.

## What the service script guarantees

- `Enable` is checked before start, so a disabled app is not restarted at boot.
- The music library must exist, or start fails with the path it looked for. The app
  would otherwise start against an empty directory and look like it had lost the
  library.
- The account database (`users.json`) is **not** written into the music library:
  `TUNEWRIGHT_STATE_DIR` points at `$QPKG_ROOT/data/state`. The library is the
  user's own files.
- The port, the bind address and the setup token are read from
  `tunewright.conf`, and the port defaults to the one QTS knows about
  (`Web_Port`), so the App Center's "Web UI" link cannot drift from the port the
  app listens on.
- `TMPDIR` points at `$QPKG_ROOT/data/tmp`. QTS's `/tmp` is a small tmpfs.
- It waits for the **listen socket**, not just the pid: QTS returns from `start` and
  immediately offers the UI, and a client in that window gets ECONNREFUSED.
- `stop` sends **SIGTERM** first. The server drains open connections for up to 25 s
  before it exits, so a request in flight is not cut off mid-write. A second
  SIGTERM makes it exit immediately; SIGKILL is the last resort.
- Previous run's log is preserved as `tunewright.log.1` on restart; a daily cron
  `rotate` enforces a 10 MB ceiling.
- `remove` stops the service; the uninstaller additionally deletes the cron line via
  `PKG_PRE_REMOVE`.

## First start: claiming the admin account

Tunewright hands the first admin account to whoever calls `/api/v1/auth/setup`
first. Because the app binds a non-loopback address by default, it refuses that
race: it generates a one-time setup token, prints it to the package log, and
requires it. Read it with

```sh
/sbin/getcfg Tunewright Install_Path -f /etc/config/qpkg.conf
tail -n 50 <install path>/data/log/tunewright.log
```

or pin your own in `tunewright.conf` (`SETUP_TOKEN=`). The test harness asserts
both halves: setup without the token is refused (403) and setup with it succeeds.

On this NAS the library is the **`Audio` share**, so `MUSIC_DIR` was set to
`/share/Audio/Music` (the QNAP default share `Multimedia` is a different volume).
See `docs/nas-topology.md`.

## Build

```sh
scripts/fetch-tunewright.sh       # builds the payload from the pinned upstream commit
scripts/build-qpkg.sh tunewright  # -> packages/tunewright/build/Tunewright_1.2.0_x86_64.qpkg
```

The build host needs rustup (with the `x86_64-unknown-linux-musl` target), a musl C
toolchain, node ≥ 20 and pnpm 12. The script says so if something is missing.

## Verifying a build without a NAS

```sh
scripts/test-tunewright.sh
```

81 assertions: the package structure, the binary present, statically linked and
without a dynamic interpreter, the SPA shipped, no downloader in the payload, then
the real service script driven against a fake root with stubbed `/sbin/getcfg` and
`/sbin/write_log` — start → the health endpoint, the SPA and the asset files all
200 → the environment the app was handed (library, state dir, static dir, TMPDIR) →
the account database is not in the music library → a setup token was generated →
setup without it is refused and with it succeeds → an authenticated file listing
sees the library → nothing was downloaded → `rotate` fires above the ceiling and
not below it → `stop` closes the port and removes the pid file. It runs twice, the
second time with a `PATH` containing no `setsid`, plus an edge-case phase: a
missing music library is created (with a warning) and an unusable one fails the
start loudly instead of serving an empty library.

## Not done yet

- Unsigned. QTS requires App Center → "Allow installation of applications without a
  valid digital signature", or a GPG/QNAP signing step.
- **Installed and enabled** on the NAS (2026-11-10). Verified from the LAN:
  `/api/v1/health` returns `{"status":"ok","version":"1.2.0"}` and `/` answers 200
  with `text/html` — i.e. the static musl binary loaded on the NAS's glibc 2.21
  and is serving the SPA that shipped inside the package. App Center reports
  Tunewright 1.2.0, installed, enabled, status *complete*.
- The service runs as **root** (QTS runs the service script as root), so the app
  writes tags in the music library as root. Files it rewrites may end up
  root-owned. Running it as the library's owner would need a privilege drop in
  the service script, which is not implemented.
- The MusicBrainz / Apple Music lookups need a CA bundle on the NAS
  (`/etc/ssl/certs/ca-certificates.crt`); the service script warns at start if it
  cannot find one. The lookups themselves were not exercised against the real
  services.
- The MCP endpoint (`/mcp`, OAuth) is shipped but untested here.
- Tag *writing* was not exercised: the harness only reads (the listing, the auth
  flow). Writing tags touches the user's own files and needs a real library.
