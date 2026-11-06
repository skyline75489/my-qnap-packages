# QPKG troubleshooting — field notes

Everything here was actually hit while building and installing the zot package on
QTS 5.2.9. Organised symptom-first, because that is how you arrive at it.

Format reference lives in [qpkg-spec.md](qpkg-spec.md). This file is the *what broke
and why* companion.

---

## First five commands

Run [`scripts/debug-zot-qpkg.sh`](../scripts/debug-zot-qpkg.sh) on the NAS first — it
is read-only and prints all of this at once. Manually:

```sh
/sbin/getcfg Zot Enable -u -d FALSE -f /etc/config/qpkg.conf   # is it even enabled?
/sbin/getcfg Zot Install_Path -f /etc/config/qpkg.conf         # where did it land?
ps | grep [z]ot                                                 # process alive?
netstat -tln | grep 5050                                        # socket bound?
tail -30 <Install_Path>/data/log/console.log                    # startup panic
```

Most "it's broken" reports resolve in the first two.

---

## Install and start

### Restarting a package

**Symptom:** you changed a config file, or the app is wedged, and you want it back
without rebooting the NAS.

**Fix:** use the init script QTS generates at install time. Confirmed working on
QTS 5.2.9 with all three packages installed:

```sh
/etc/init.d/zot.sh restart
/etc/init.d/openlist.sh restart
/etc/init.d/backrest.sh restart
```

It checks `Enable` and then calls the package's own service script with `stop`
followed by `start` — which is exactly what the scripts implement, so
`restart` is a clean stop and start, not a kill.

Calling the package script directly works too, and is what the init script ends up
doing:

```sh
sh "$(/sbin/getcfg Backrest Install_Path -f /etc/config/qpkg.conf)/backrest.sh" restart
```

**Two things to expect:**

- A **disabled** package refuses to start (`<Name> is disabled.`) and exits 1.
  That is the `Enable` check, not a crash — enable it in App Center first.
- Backrest's stop sends **SIGINT**, not SIGTERM: Backrest traps `os.Interrupt` and
  closes its sqlite connections in order, and does not trap SIGTERM at all. Its
  restart therefore takes a second or two.

App Center has no dedicated restart button; stop and start are two clicks.

### Backup fails with "no space left on device"

**Cause:** QTS's `/tmp` is a small tmpfs, and restic writes its in-progress pack
files to `os.TempDir()` while a backup runs (restic
`internal/repository/packer_manager.go`: `fs.TempFile("", "restic-temp-pack-")`).
A backup that outgrows the tmpfs dies **while saving the snapshot**:

```
Fatal: unable to save snapshot: Write: write /tmp/restic-temp-pack-37230858: no space left on device
```

No snapshot is created, so it reads like a repository fault rather than a
disk-space one.

**Confirm:**

```sh
df -h /tmp          # the tmpfs is the one that filled up
```

**Fix:** point `TMPDIR` at a real volume. restic 0.19.1 has **no** `--temp-dir`
flag (`unknown flag: --temp-dir`) — the feature was requested upstream in
[restic/restic#5572](https://github.com/restic/restic/issues/5572) and closed with
a documentation fix only ([#5600](https://github.com/restic/restic/pull/5600)) —
so the environment is the only knob, and it works because the parent process's
environment is inherited by the restic subprocess. The Backrest package sets
`TMPDIR=$QPKG_ROOT/data/tmp` for exactly this reason; per repository, the
Backrest UI's *Environment variables* field sets it for one repo only.

**The variable is `TMPDIR`** — no underscore. `TMP_DIR` is not read (verified:
pointing it at an unwritable directory changes nothing), and `TEMP` is Windows-only
(there the variable is `TMP`). A misspelt one is worse than none: it looks like
it is working while the package-level setting quietly covers for it.

**If `TMPDIR` appears to be ignored**, check what the process actually sees —
upstream had the same report ([restic/restic#4872](https://github.com/restic/restic/issues/4872)),
and the cause was a wrapper script resetting it:

```sh
tr '\0' '\n' < /proc/$(pgrep -f restic | head -1)/environ | grep TMPDIR
```

### Installed fine, port refuses connections

**Cause:** the start script exited non-zero, and **QTS records a failed start as
"stay disabled"**. The app looks installed in App Center; nothing is listening; no
error is surfaced anywhere in the UI. This is the single most misleading behaviour in
the whole system.

**Confirm:** `getcfg Zot Enable` returns `FALSE`. `/etc/init.d/zot.sh` exists but no
process is running. Start it by hand to see the real error:

```sh
sh /share/<VOL>/.qpkg/Zot/zot.sh start
```

**Fix:** whatever the manual start reports. Two actual causes we hit are the next two
entries.

### `nohup: command not found` (and `setsid` missing too)

**Cause:** QTS's init environment has **neither `nohup` nor `setsid`**. Worse, a
`command -v setsid` check can miss a binary that *does* exist, because the init-time
`PATH` is thin.

**Confirm:**

```sh
for c in /usr/bin/setsid /bin/setsid /usr/sbin/setsid /sbin/setsid; do [ -x $c ] && echo "FOUND $c"; done
echo "PATH=$PATH"
```

**Fix:** never rely on `PATH` or on `nohup`. Probe absolute paths first, then
`command -v`, then `/bin/busybox setsid`, then fall back to `sh -c` with
`trap '' HUP` (which is all `nohup` actually does). The zot package's `shared/zot.sh`
implements exactly that chain and logs which method won:

```
[Zot] detach method: setsid(/usr/bin/setsid)
```

### Service starts, then dies seconds later

**Cause:** QTS kills the start script's **process group** once the script returns. A
plain `cmd &` child dies with it. `nohup` does not protect against this either — it
only ignores SIGHUP.

**Fix:** the daemon must be in its own session: `setsid`. Note `$!` is then setsid's
pid, so the child has to write its own pid and `exec` in place to keep it:

```sh
"$SETSID" /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" serve "$3"' \
    zotdetach "$PIDF" "$BIN" "$CFG" </dev/null >>"$LOG" 2>>"$CONSOLE" &
```

**Confirm** it worked — the daemon should be its own session leader:

```sh
ps -o pid,ppid,sid,pgid,comm -p "$(cat <Install_Path>/data/zot.pid)"
# sid == pgid == pid  ->  detached properly
```

### Started, but connections are refused for a second or two

**Cause:** a live pid is not a bound socket. QTS returns from `start` and immediately
offers the UI; a client connecting in that window gets `ECONNREFUSED` — visually
identical to "not running".

**Fix:** `start` should poll for the listen socket before returning, and log it
(`listening on port 5050`). Make the timeout non-fatal: a large blob store can take a
while to reparse and the daemon does bind eventually.

### Fresh install does nothing until it is enabled

**Cause:** by design. A fresh install leaves the QPKG **disabled**; only upgrades
restore the previous enable state. QTS also still runs the init script at boot when
disabled, which is why every service script must check `Enable` first and bail —
otherwise a disabled app gets restarted on every reboot.

---

## Build-time traps

These all report success while producing something broken. That is the recurring
theme of the QDK toolchain.

### Package builds, but ships without its checksum

**Cause:** `qbuild` ends by shelling out to `qpkg_encrypt` (or `/sbin/qpkg` on a NAS)
to append a 100-byte checksum trailer. On a plain Linux build host neither exists and
the failure is **non-fatal**:

```
qbuild: line 1158: qpkg_encrypt: command not found
==> build/YourApp_1.0_x86_64.qpkg (65.4 MB)      <- and it still says success
```

**Fix:** compile it once from the QDK tree:

```sh
cd $QDK/src && make          # -> src/bin/qpkg_encrypt
export PATH=$QDK/src/bin:$PATH
```

### `qbuild --extract` produces a corrupt archive

**Cause:** a bug in the extractor. On a package that has the checksum trailer, it
writes a `data.tar.gz` that is short by a few KB — `gzip -t` fails with
`unexpected end of file`. **The package itself is fine.** Do not chase this.

**Fix:** verify by walking the container directly — a `.qpkg` is a shell header plus
two concatenated gzip streams plus the trailer:

```
offset      0 .. N1     shell header (arch check + volume selection)
offset     N1 .. N2     gzip: qinstall.sh, package_routines, qpkg.cfg, md5sum
offset     N2 .. N3     gzip: the data payload
offset     N3 .. EOF    100-byte checksum trailer
```

Decompress each stream independently and list the tar members. That is unambiguous
proof of contents and modes. See [qpkg-spec.md](qpkg-spec.md) for the exact header
offsets observed.

### `qbuild` can't find qinstall.sh or the template

**Cause:** the QDK **repo** stores them under `shared/`, while an installed QDK puts
them at the top level. `qbuild` derives `QDK_PATH` from its own location and expects
the installed layout.

**Fix:**

```sh
export QDK_SCRIPTS_DIR=$QDK/shared/scripts
export QDK_TEMPLATE_DIR=$QDK/shared/template
```

### Two builds of identical inputs produce different hashes

**Cause:** `qbuild` assembles the data archive in a fresh temp directory, and the
tar's `./` entry carries that directory's mtime. The compressed length shifts by a
couple of bytes; the package header embeds that length, and the trailer derives from
it.

**Consequence:** verify builds by hashing the **extracted members**, not the `.qpkg`.
Never document a `.qpkg` hash as reproducible from source.

### Install hooks silently do nothing

**Cause:** install hooks are **functions** (`pkg_init`, `pkg_install`,
`pkg_post_install`); removal hooks are **variables** (`PKG_PRE_REMOVE`, …) inlined
into the generated uninstaller at build time. Writing `PKG_POST_INSTALL` — which looks
completely plausible — is accepted and ignored.

**Fix:** if install-time code isn't running, check it's a function. And anything in a
removal block that must evaluate at *removal* time needs escaping: `\$VAR`,
`\$(command)`.

### Package name or version silently truncated

`QPKG_NAME` is capped at **20 chars**, `QPKG_VER` at **10**, and values containing
whitespace are cut at the first space with only a warning. Build with `--strict` if
you want these to be fatal.

---

## Runtime and config

### CVE scanning runs even though it was set to "off"

**Cause:** `search.cve.updateInterval: "0"` does **not** disable it. In
`pkg/cli/server/root.go`, the mere presence of a `cve` block forces the interval up
to a 2h minimum, auto-creates the Trivy config, and defaults the DB source to
`ghcr.io/aquasecurity/trivy-db`.

Measured cost on a host that couldn't reach ghcr.io: a failing scan every 2 hours,
~11k log lines, ~35k errors, and a **3.1 GB** `_trivy` directory.

**Fix:** omit the `cve` block entirely. The log then says
`cve config not provided, skipping cve-db update`.

### Log grows without bound

zot has no built-in rotation and nothing on QTS rotates it for you. Measured at
`level: info`: 73 MB in 2.7 days ≈ **27 MB/day ≈ 9.9 GB/year**, dominated by
per-request logging.

**Fix:** `level: warn` is the real control. Add a size cap on a timer — rotate **on a
schedule**, not at service start, because a NAS service runs for months and a
start-triggered rotation never fires. Install a cron line into
`/etc/config/crontab` then `crontab /etc/config/crontab` and restart `crond.sh`.

### Local config edits vanish on upgrade

**Cause:** expected. `QPKG_CONFIG` files follow the `.qdkorig` / `.qdksave` lifecycle:
an unrecorded change is renamed `.qdkorig`, a user-customised one `.qdksave`, and the
package's version is installed.

**Fix:** that is the intended safety behaviour — recover from `.qdksave`. To adopt a
pre-existing config without it being flagged, call `add_qpkg_config FILE MD5` in
`pkg_init()`. To acknowledge a programmatic migration, use `set_qpkg_config`.

### Uninstall deletes the data directory

**Cause:** the generated uninstaller runs `rsync -a --delete /tmp/qpkg_blankdir
"$SYS_QPKG_DIR"` and then `rm -fr "$SYS_QPKG_DIR"`. There is no keep-data option.

**Fix:** nothing under `$SYS_QPKG_DIR` survives. Put anything that must outlive the
package outside it — a share resolved via `get_share_path`, or a directory on the
volume root. `PKG_PRE_REMOVE` runs *before* the wipe, so it is the only rescue point,
but a large move there is fragile.

Note the cookbook's "run-time data directory" recipe (`mkdir` in `pkg_install`) makes
a directory **upgrade**-safe, not uninstall-safe. Different problems.

### Install aborts with "Wrong architecture"

`qbuild` bakes a CPU-match regex into the header; QTS checks it against `uname -m`
before extracting. Only these are supported: `x86_64`, `x86`, `arm_64`, `arm-x41`.
64-bit only in practice — most modern upstream binaries don't ship 32-bit ARM.

### QTS refuses the package as unsigned

Locally built packages have no signature. App Center → settings → **"Allow
installation of applications without a valid digital signature"**, or sign with GPG
(`qbuild --sign`) / QNAP internal code signing (requires a QNAP developer account).

---

## What QTS does, in order

Worth knowing when hooks fire:

```
init        pkg_init()                       before anything
check       QPKG_REQUIRE / QPKG_CONFLICT, then pkg_check_requirement()
pre-install QTS version check, config backup, service stop, then pkg_pre_install()
install     extract data + config, then pkg_install()
post-install obsolete-file cleanup, icons, init-script link, register in
            qpkg.conf, then pkg_post_install()
finish      generate .uninstall.sh, restore enable/start state
```

Uninstall: `stop` → `stop remove` → `PKG_PRE_REMOVE` → `rsync --delete` + `rm -fr` →
init symlinks/icons → `PKG_MAIN_REMOVE` → `PKG_POST_REMOVE`.
