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

## QTS's /tmp is small — restic needs TMPDIR

restic writes its **in-progress pack files** to the system temporary directory while
a backup is running:

```go
// restic internal/repository/packer_manager.go
tmpfile, err := fs.TempFile("", "restic-temp-pack-")   // -> os.CreateTemp("", ...)
```

`os.CreateTemp` with an empty directory uses `os.TempDir()`, which is `$TMPDIR` if it
is set and `/tmp` otherwise. On QTS, `/tmp` is a small tmpfs — a backup that outgrows
it dies like this:

```
Fatal: unable to save snapshot: Write: write /tmp/restic-temp-pack-37230858: no space left on device
```

The snapshot is never created, so it reads like a repository problem rather than a
disk-space one. Check `df -h /tmp` before believing the repository.

**The fix is `TMPDIR`.** restic 0.19.1 has no `--temp-dir` flag (`unknown flag:
--temp-dir`), so the environment is the only knob — and it works, because Backrest
passes its own environment to the restic subprocess (`restic.WithEnviron()`).

This package therefore sets, in the service script:

| Variable | Value | Why |
|---|---|---|
| `TMPDIR` | `$QPKG_ROOT/data/tmp` | The temp packs land on the storage volume, not the tmpfs |
| `RESTIC_CACHE_DIR` | `$QPKG_ROOT/data/restic-cache` | The cache is also real data, and it is large |

Verified on the build host by pointing `TMPDIR` at a read-only directory, which
reproduces the failure exactly:

```
Fatal: unable to save snapshot: open /tmp/rt2/ro/restic-temp-pack-68815701: permission denied
```

and with a writable `TMPDIR` the same backup completes.

**Per repo**, the Backrest UI exposes *Environment variables* on each repository
(`Repo.env`, applied as `restic.WithEnv`). That is the knob to use when the temp
files should live on a *different* volume from the package — for example a
dedicated cache volume:

```
TMPDIR=/share/CACHEDEV1_DATA/.restic-tmp
```

Per-repo `flags` cannot solve this: restic has no `--temp-dir`.

### What upstream says

The `--temp-dir` idea is a real upstream request, and the answer is instructive.

| Issue | State | Outcome |
|---|---|---|
| [restic/restic#5572](https://github.com/restic/restic/issues/5572) — *specifying temp directory* | closed 2025-11-17 | The reporter asked for exactly this: "add Global Flags command line option `--temp-dir` … similar to `--cache-dir`. It's odd that this important setting can only be controlled by an environment variable." |
| [restic/restic#5600](https://github.com/restic/restic/pull/5600) | merged 2025-11-17 | The maintainer closed the issue with this — but it **only fixed the documentation** (two `.rst` files, +4/−5 lines, about Windows `TMP` taking precedence over `TEMP`). **No flag was added.** |
| [restic/restic#4872](https://github.com/restic/restic/issues/4872) — *environment variable TMPDIR is ignored* | closed 2024-06-25 | A user's shell wrapper was resetting `TMPDIR=/tmp`; restic was working correctly. The maintainer's diagnostic — "check in `/proc/<restic-PID>/environ` whether the TMPDIR is set correctly" — is exactly the assertion this package's harness makes. |
| [restic/restic#21840](https://github.com/restic/restic/issues/21840) — *restic writes much data to the local drive* | **open** | The same complaint from the SD-card angle. Worth watching: if upstream ever changes its mind about a flag, it will land here first. |

So: as of restic **0.19.1** — the version this package ships — and on `master`,
**there is no `--temp-dir`**. Checked in the release tarball's `cmd/` and `doc/`
trees and in `cmd/restic/global.go` on `master`: no such flag, and no open PR for
one.

What upstream *does* document, in the "Temporary files" section of
`doc/manual_rest.rst`, is precisely the fix implemented here:

```
During some operations (e.g. backup and prune) restic uses temporary files to
store data. These files will, by default, be saved to the system's temporary
directory, on Linux this is usually located in /tmp/. To specify a different
directory for temporary files, set the appropriate environment variable. On
non-Windows operating systems, use the TMPDIR environment variable.

    $ export TMPDIR=/var/tmp/restic-tmp
    $ restic -r /srv/restic-repo backup ~/work
```

Two details worth knowing, both from upstream:

- **`TMPDIR` is not only about the temp packs.** `prune` and `check` also use
  temporary files, so a `prune` on a small tmpfs can fail the same way.
- **On Windows the variable is `TMP`**, not `TEMP` — that precedence mix-up is
  what PR #5600 fixed in the documentation. It does not affect Linux.

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
