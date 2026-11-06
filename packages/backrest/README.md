# packages/backrest — the Backrest QPKG

Native-binary QPKG for the QNAP NAS. There is no Container Station dependency and
nothing is downloaded at install time — or at run time.

Decisions behind it: [`../../docs/backrest.md`](../../docs/backrest.md).

## Layout

```
qpkg.cfg              metadata: name/version, service script, port 9898, volume select 3
package_routines      install hooks (data dirs, chown, cron) + pre-remove (stop, cron)
shared/config.json    backrest config — version 6, no repos, auth disabled
shared/backrest.sh    start|stop|restart|status|rotate|remove
icons/                Backrest.gif 64x64, Backrest_gray.gif 64x64, Backrest_80.gif 80x80
x86_64/backrest       the payload; fetched, never committed
x86_64/restic         the bundled restic; fetched, never committed
```

Icons are generated from the upstream backrest mark (`webui/assets/favicon.png`,
GPL-3.0) by `scripts/make-icons.sh`, flattened onto white so the dark logo stays
visible on a dark App Center theme.

`shared/` lands at `$SYS_QPKG_DIR`, so `config.json` is protected by
`QPKG_CONFIG="config.json"` (`.qdkorig`/`.qdksave` on upgrade) and `backrest.sh` is
the `QPKG_SERVICE_PROGRAM`.

## Two payloads, not one

Backrest is an orchestrator: it drives the `restic` binary as a subprocess. Left
alone it **downloads restic on first start** (`resticinstaller.FindOrInstallResticBinary`,
which is fatal if it fails). This package ships restic and points
`BACKREST_RESTIC_COMMAND` at it, so the NAS never reaches out to the internet at run
time.

Both binaries are **statically linked** (`CGO_ENABLED=0` upstream, and restic is a
static Go binary too), so the NAS's glibc 2.21 is not a constraint. The test harness
asserts the static linkage rather than assuming it.

## Build

```sh
scripts/fetch-backrest.sh    # verifies sha256 against both upstream checksum files
scripts/build-qpkg.sh backrest  # -> packages/backrest/build/Backrest_1.14.1_x86_64.qpkg
```

`fetch-backrest.sh` verifies the backrest tarball against
`backrest_<version>_checksums.txt` and the restic `.bz2` against restic's own
`SHA256SUMS`. It decompresses restic with `python3` — `bunzip2` is not a given on a
build host (the linuxbrew one on this host is broken) and python3 is already a
dependency of the test harness.

## What the service script guarantees

- `Enable` is checked before start, so a disabled app is not restarted at boot.
- The bundled restic must be present and executable, else start fails. It never
  falls back to letting backrest download one.
- All paths handed to the app are absolute and inside `$QPKG_ROOT`
  (`BACKREST_CONFIG`, `BACKREST_DATA`, `RESTIC_CACHE_DIR`, `HOME`), so they stay
  valid across a volume migration.
- `BACKREST_PORT=":$PORT"` — the upstream default is `127.0.0.1:9898`, which is
  unreachable from a browser on the LAN.
- It waits for the **listen socket**, not just the pid: QTS returns from `start` and
  immediately offers the UI, and a client in that window gets ECONNREFUSED.
- `stop` sends **SIGINT** first. Backrest traps `os.Interrupt` and shuts its sqlite
  connections down in order; it does *not* trap SIGTERM, which would kill it
  mid-transaction.
- Previous run's log is preserved as `backrest.log.1` on restart; a daily cron
  `rotate` enforces a 10 MB ceiling.
- `remove` stops the service; the uninstaller additionally deletes the cron line via
  `PKG_PRE_REMOVE`.

## Verifying a build without a NAS

```sh
scripts/test-backrest.sh
```

45 assertions: the package structure, both payloads present and statically linked,
then the real service script driven against a fake root with stubbed
`/sbin/getcfg` and `/sbin/write_log` — start → `/`, `/metrics` and the
`/v1.Backrest/GetConfig` RPC all 200 → the bundled restic was used and nothing was
downloaded → `rotate` fires above the ceiling and not below it → `stop` closes the
port and removes the pid file. It runs twice, the second time with a `PATH`
containing no `setsid`.

## Not done yet

- Unsigned. QTS requires App Center → "Allow installation of applications without a
  valid digital signature", or a GPG/QNAP signing step.
- **Installed and enabled** on the NAS (2026-11-06). Verified from the LAN: `/`
  answers 200 and `POST /v1.Backrest/GetConfig` returns the config with
  `"instance":"backrest"` and a generated identity key — i.e. the shipped
  `config.json` was read and rewritten by the app on the NAS, which is the
  `QPKG_CONFIG` path doing its job.
- The UI's own flows (creating a repo, running a backup, restoring) are **not**
  exercised — only the HTTP surface, the service lifecycle and the restic wiring.
- The bundled restic is pinned to the version backrest requires
  (`RequiredResticVersion` upstream). A backrest upgrade that bumps that version
  needs `RESTIC_VERSION` updated in `scripts/fetch-backrest.sh`.
- Authentication is **disabled** by default (upstream's default). The service script
  logs a warning on every start; create a user in the Backrest UI before exposing
  the port to anything untrusted. The warning is visible in the NAS log on every
  start, and `GET /v1.Backrest/GetConfig` reports `"auth":{"disabled":true}`.
