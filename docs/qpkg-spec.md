# QPKG format and build notes

Verified against the QDK Developer Guide shipped in
[qnap-dev/QDK](https://github.com/qnap-dev/QDK) (`docs/QDK-Developer-Guide.md`,
1004 lines) and the Hello World example in
[qnap-dev/QDK-Guide](https://github.com/qnap-dev/QDK-Guide).
QNAP's public wiki pages 404 or redirect to the support portal, so the QDK repo is
the authoritative source.

## What a QPKG is

A `.qpkg` is a shell-metadata file (`qpkg.cfg`) plus an embedded generic installer
(`qinstall.sh`), a data archive, and optional package-specific install hooks
(`package_routines`). There is no container runtime involved anywhere in the
format. `qbuild` assembles it; QTS unpacks it into `.qpkg/<NAME>` on a volume.

Consequence: a QPKG can ship a native binary and needs no external service to be
installed or started.

## Build root layout

| Path | Purpose |
|---|---|
| `qpkg.cfg` | Metadata. Required. |
| `package_routines` | Install/removal hooks. Required file, may define no hooks. |
| `shared/` | Files common to all architectures. Added *before* arch files, so arch files override shared ones. |
| `arm-x41/`, `arm_64/`, `x86/`, `x86_64/` | Arch-specific trees. **A non-empty directory is what tells `qbuild` to build for that arch.** Remove unused ones. |
| `config/` | Full-path files — mirrors the target filesystem (e.g. `config/etc/foo.conf` → `/etc/foo.conf`). Only for files landing *outside* the QPKG dir. |
| `icons/` | `<NAME>.gif` 64×64 enabled, `<NAME>_gray.gif` 64×64 disabled, `<NAME>_80.gif` 80×80 dialog. Defaults used if absent. |
| `build/` | Default output dir. |

Arch set is `arm-x41`, `arm_64`, `x86`, `x86_64` — **no `arm-x19`/`arm-x31`** in the
current guide, despite those appearing in older example trees. `SYS_CPU_ARCH` is
derived from `uname -m`.

## qpkg.cfg constraints

`qbuild` refuses to build without `QPKG_NAME`, `QPKG_VER`, `QPKG_AUTHOR`.
Missing `QPKG_SERVICE_PROGRAM` is a warning only.

- `QPKG_NAME` ≤ **20 chars**, no whitespace.
- `QPKG_VER` ≤ **10 chars**, no whitespace.
- Values containing a space are truncated at the first space, with a warning.

Keys that matter for binary-payload packages:

| Key | Notes |
|---|---|
| `QPKG_SERVICE_PROGRAM` | Script path; invoked with `start`/`stop`/`restart`. Also the App Center start/stop button. |
| `QPKG_SERVICE_PIDFILE` | Path to the running process's PID file. |
| `QPKG_SERVICE_PORT` | Service port, recorded in `qpkg.conf`. |
| `QPKG_CONFIG` | Config file needing upgrade-safe handling. Repeatable. Enables the `.qdkorig`/`.qdksave` lifecycle. |
| `QPKG_TIMEOUT` | `"start_timeout,stop_timeout"` seconds (QTS ≥ 4.1.0). |
| `QPKG_RC_NUM` | *Ignored by QTS after reboot* — real number is reassigned from order in `qpkg.conf`, starting at 100. |
| `QTS_MINI_VERSION` / `QTS_MAX_VERSION` | Version gating, read from `/etc/default_config/uLinux.conf`. |
| `QPKG_REQUIRE` | Dependencies. Format: `"Name >= 1.2, Alt1 | Alt2, OPT/ipkgpkg"`. Aborts install with a system-log message if unmet. |
| `QPKG_CONFLICT` | Same syntax, no `|` support. |
| `QPKG_VOLUME_SELECT` | `0` default volume, `1` select on install, `2` select on migrate, `3` both, `4` select with no default. |

Web UI keys: `QPKG_WEBUI` (relative path, must start with `/`), `QPKG_WEB_PORT`
(`0`/empty = QTS web port 80; `-1` = system httpd 8080; `-2` = HTTP unsupported),
`QPKG_WEB_SSL_PORT` (same sentinel scheme).

Some `qpkg.conf` fields have **no** `qpkg.cfg` key (e.g. `Dependency`, `App_ID`,
`Win_*`, `Role_Delegation`). Set those directly in `pkg_post_install()` via
`$CMD_SETCFG`. Note `Dependency` in `qpkg.conf` is evaluated by QTS and is
separate from QDK's own `QPKG_REQUIRE` — setting one does not set the other.

## package_routines asymmetry

The asymmetry that causes silent failures:

**Install hooks are functions**, called only if defined, in this order:

| Function | Phase |
|---|---|
| `pkg_init()` | First, before anything else |
| `pkg_check_requirement()` | After built-in `QPKG_REQUIRE`/`QPKG_CONFLICT` checks |
| `pkg_pre_install()` | After config backup + service stop, before extraction |
| `pkg_install()` | After data/config extraction and config restore |
| `pkg_post_install()` | After obsolete-file cleanup, icons, init-script link, `register_qpkg` |

**Removal hooks are shell blocks inlined into the generated `.uninstall.sh`:**

```sh
PKG_PRE_REMOVE="{ ... }"    # before the QPKG dir is removed
PKG_MAIN_REMOVE="{ ... }"   # after dir / init symlinks / icons are removed
PKG_POST_REMOVE="{ ... }"   # final step
```

Two traps here:

1. Writing `PKG_POST_INSTALL` (a variable) is silently ignored — install hooks must
   be functions.
2. Removal blocks are expanded into the uninstall script **at build time**. Anything
   that must evaluate at removal time needs escaping: `\$VAR`, `\$(command)`.

To abort an install with an error from a hook, call `err_log "msg"` (writes to
stderr + system log, restores backed-up config, aborts).

## Runtime variables available in hooks

- `SYS_QPKG_DIR` — installed package dir, `$SYS_QPKG_INSTALL_PATH/$QPKG_NAME`
- `SYS_QPKG_INSTALL_PATH` — `$SYS_QPKG_BASE/.qpkg`
- `SYS_QPKG_BASE` — volume root containing the Public share, e.g. `/share/MD0_DATA`
- `SYS_QPKG_CONFIG_FILE` — `/etc/config/qpkg.conf`
- `SYS_CONFIG_DIR` — `/etc/config`
- `SYS_CPU_ARCH` — `arm-x41`/`arm_64`/`x86`/`x86_64`
- `SYS_QPKG_SERVICE_ENABLED` — desired state after install; hooks may override

Support functions: `log`, `warn_log`, `err_log`, `get_share_path`,
`add_qpkg_config`, `set_qpkg_config`, `extract_data`, `is_qpkg_enabled`,
`is_qpkg_not_installed`, and `is_{equal,unequal,less,less_or_equal,greater,greater_or_equal}`.

`CMD_*` aliases give absolute paths to busybox/coreutils so hooks don't depend on
`$PATH` (`CMD_GETCFG=/sbin/getcfg`, `CMD_SETCFG=/sbin/setcfg`, `CMD_WLOG`,
`CMD_MD5SUM`, `CMD_TAR`, `CMD_7Z`, …).

## Install/upgrade lifecycle

Phases: init → check → pre-install → install → post-install → finish.

- **Fresh install: the QPKG is disabled by default.**
- **Upgrade: previous enabled/disabled state is restored**, and the service is
  started if it was enabled — if start fails, state falls back to disabled.

Config file lifecycle, for each `QPKG_CONFIG` path (`store_config`, during
pre-install), comparing the live file's MD5 against the recorded original and the
new package's MD5:

| Live file | Result |
|---|---|
| Unchanged (matches either) | Left alone / restored unmodified |
| Changed, no prior record | Renamed to `<file>.qdkorig`, new file installed |
| Changed, differs from both | Renamed to `<file>.qdksave`, new file installed |

`add_qpkg_config FILE MD5` in `pkg_init()` adopts a pre-existing config so it isn't
flagged `.qdkorig` on first upgrade. `set_qpkg_config` updates the recorded MD5
after a programmatic migration.

## Init script contract

The QDK template's shape, and the reason for it:

```sh
start)
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi
    # start actions
    ;;
stop)
    # stop actions
    ;;
restart)
    $0 stop; $0 start
    ;;
*)
    echo "Usage: $0 {start|stop|restart|remove}"; exit 1
    ;;
```

The `Enable` check is mandatory. QDK has only two states (enabled/disabled); a
hand-written script that skips this check causes a **disabled service to be
restarted at reboot**, because QTS still runs the init script.

## qbuild

```
qbuild [--root DIR] [--create-env NAME] [--build-arch ARCH] [--build-version V]
       [--build-number N] [--build-dir DIR] [--force-config] [--exclude PATTERN]
       [--gzip|--bzip2|--7zip|--xz] [--sign] [--gpg-name ID] [--verify QPKG]
       [--extract QPKG [DIR]] [--query OPTION QPKG] [--strict] [-v|-q]
```

- `--build-arch` accepts `arm-x41`, `arm_64`, `x86`, `x86_64`; repeatable. Default
  is inferred from non-empty arch directories.
- One `.qpkg` per architecture is produced; a generic package results when no arch
  dirs are used.
- Built QPKGs embed a CPU-match regex derived from the arch.
- `--query dump|info|config|require|conflict|funcs` inspects a built package
  without extracting.
- `--create-env NAME` scaffolds from `$QDK_PATH/template`.
- `--force-config` is needed when `QPKG_CONFIG` files don't exist in the build tree
  (generated at install time).
- Compression default `gzip`; `xz` bundles a small xz toolchain for firmware
  lacking native xz.

QDK itself installs as a QPKG or a Debian package
(`qdk_2.5.3_<platform>.deb`), and puts `qbuild` at `/usr/share/QDK/bin`.

## Signing

- GPG: `--sign`, keyring at `/etc/config/qpkg.gpg` by default, `--import-key`,
  `--verify`. QDK 2.5.3 added using a specified GPG keyring when generating
  signatures.
- QNAP-internal code signing: `QNAP_CODE_SIGNING=1` +
  `QNAP_CODE_SIGNING_CSV` (default `build_sign.csv`). Requires a QNAP developer
  account; `qbuild` forces `codesigning.qnap.com:5001`.
- **Unsigned QPKGs install only after enabling App Center → "Allow installation of
  applications without a valid digital signature."**

## Notes for binary payloads

- Use `--pre-build`/`--post-build` to stage per-arch binaries into the right arch
  dir; they receive `(ARCH, ARCH_DIR)`.
- `--exclude` uses rsync semantics — use it to keep `.git`, build scratch, and
  stray files out of the data archive.
- `--strict` turns warnings into errors; worth enabling in CI so a truncated
  `QPKG_VER` or missing service program fails the build.
