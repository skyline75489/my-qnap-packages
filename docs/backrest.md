# The Backrest package

Backrest is a web UI and orchestrator for [restic](https://restic.net). This package
runs it natively on the NAS — no Container Station, no downloads at install or run
time.

The packaging decisions are recorded here because most of them are not obvious from
the upstream project, and one of them is a rule rather than a preference.

## Upstream facts that shaped the package

Measured against `garethgeorge/backrest` v1.14.1 and `restic/restic` v0.19.1.

| Fact | Consequence |
|---|---|
| Both binaries are **statically linked** (`CGO_ENABLED=0` upstream; restic is a static Go binary) | The NAS's glibc 2.21 is a non-issue. No sysroot, no shared libraries, no `LD_LIBRARY_PATH`. |
| The web UI is **embedded in the binary** (`webui` package, gzip-compressed with `statigz`) | There is no asset directory to ship. One binary, one port. |
| The database is **pure Go** (`ncruces/go-sqlite3`, a WASM SQLite) | No `CGO`, no `libsqlite3` to package. |
| Backrest **downloads restic on first start** if it cannot find one (`resticinstaller.FindOrInstallResticBinary`, fatal on failure) | restic must be bundled, and the download must be prevented. See below. |
| Backrest is **GPL-3.0** | Redistribution conditions; the source is public and the licence text ships with the package. |
| Configuration is a **single protobuf-JSON file** that holds the repo definitions **and the restic repository passwords** | It must survive an upgrade → `QPKG_CONFIG`, and the upgrade-safe `.qdkorig`/`.qdksave` lifecycle. |
| Backrest handles **SIGINT** (`os.Interrupt`) but **not SIGTERM** | `stop` sends SIGINT first so sqlite is closed cleanly; SIGTERM would kill it mid-transaction. |
| Configuration is read from `BACKREST_CONFIG`, data from `BACKREST_DATA`, the listen address from `BACKREST_PORT`, the restic binary from `BACKREST_RESTIC_COMMAND` | No config file rewriting, no guessing XDG paths, no second binary lookup. |

## The no-runtime-download rule

This repo's packages do not download anything at run time: the NAS may be offline,
and an unattended download is an unreviewed binary running as root.

Backrest breaks that rule by default — it downloads a restic binary on first start
and treats failure to do so as fatal. So:

- restic **is shipped**, pinned to the version backrest requires
  (`RequiredResticVersion` in upstream `internal/resticinstaller/`), verified against
  restic's own `SHA256SUMS`.
- The service script sets `BACKREST_RESTIC_COMMAND` to the bundled copy, which is
  the first thing backrest checks.
- The service script **refuses to start** if the bundled restic is missing, rather
  than letting backrest fall back to downloading one.
- The test harness asserts that no restic was downloaded and that none was
  self-installed.

A backrest upgrade that bumps `RequiredResticVersion` needs `RESTIC_VERSION` updated
in `scripts/fetch-backrest.sh`. The harness catches the mismatch: backrest logs
`restic binary ... may not be supported by backrest` when it rejects the version.

## Ports

Backrest's upstream default is `127.0.0.1:9898` — loopback only, so a browser on the
LAN cannot reach it. The package binds `:9898` (all interfaces) instead.

9898 is backrest's own default and collides with nothing QTS uses. Port 5000 is the
QTS portal and is never used here.

## Paths

Everything the app writes lives under `$SYS_QPKG_DIR/data`:

| Path | Contents |
|---|---|
| `data/oplog.sqlite` | operation log (what ran, when, with what result) |
| `data/kvdb.sqlite` | peer/key state |
| `data/jwt-secret` | generated on first start, mode 0600 |
| `data/tasklogs/`, `data/processlogs/` | per-task logs |
| `data/log/backrest.log` | stdout of the service, rotated by cron |
| `data/restic-cache/` | restic's own cache |
| `data/home/` | `HOME` for the service; restic's config and cache |

`config.json` sits next to the service script, not in `data/`, because it is the
user's configuration — and it holds the repository passwords.

**Everything under `data/` dies on uninstall** (`rsync --delete` + `rm -rf`). That
is acceptable here: the operation log and caches are rebuildable, and the actual
backup data lives wherever the user pointed restic (outside the QPKG directory).
The configuration does not live there, so a reinstall keeps the repository
definitions — but only if the config is handled by `QPKG_CONFIG`, which is why it is.

## Authentication

Upstream ships with authentication **disabled**, and the default config here keeps
that. The API can delete backups, so this matters: the service script logs a warning
on every start, and the package README says to create a user in the UI.

Shipping `auth.disabled: true` with no users would have been worse: the middleware
would demand a bearer token, and with no user to log in as, the UI would be a dead
end. Disabled-but-warned is the upstream behaviour with a loud label on it.

## Version pinning

| Component | Version | Source |
|---|---|---|
| backrest | v1.14.1 | GitHub release tarball, `backrest_1.14.1_checksums.txt` |
| restic | 0.19.1 | GitHub release `.bz2`, restic's `SHA256SUMS` |

Both are verified at fetch time. The decompressed restic is not covered by the
published checksum (the checksum is for the `.bz2`), so the `.bz2` is the thing that
is verified and the decompressed file is what gets installed.

Decompression uses `python3` rather than `bunzip2`: `bunzip2` is not a given on a
build host — the linuxbrew one on this host fails with `cannot execute: required
file not found` — and python3 is already a dependency of the test harness.

## What is not covered

- The UI's own flows (creating a repo, running a backup, restoring) are not
  exercised by the harness — only the HTTP surface, the service lifecycle, and the
  restic wiring.
- Video/large-file behaviour, S3 and SFTP backends are untested.
- The package **is** installed and enabled on the NAS (2026-11-06): `/` answers 200
  and `POST /v1.Backrest/GetConfig` returns the config with the generated identity,
  which shows the shipped `config.json` was read and rewritten on the NAS.
