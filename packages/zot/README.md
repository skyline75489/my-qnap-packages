# packages/zot — the zot QPKG

Native-binary QPKG for the QNAP NAS. There is no Container Station dependency and
nothing is downloaded at install time.

Decisions behind it: [`../../docs/zot-config.md`](../../docs/zot-config.md) (extensions,
logging), [`../../docs/zot-storage.md`](../../docs/zot-storage.md) (where data lives),
[`../../docs/static-linking.md`](../../docs/static-linking.md) (why the upstream binary
is enough).

## Layout

```
qpkg.cfg              metadata: name/version, service script, port 5050, volume select 3
package_routines      install hooks (data dirs, chown, cron) + pre-remove (stop, cron)
shared/config.json    zot config — relative paths, level warn, no sync, no cve
shared/zot.sh         start|stop|restart|status|rotate|remove
x86_64/zot            the payload; fetched, never committed
```

`shared/` lands at `$SYS_QPKG_DIR`, so `config.json` is protected by
`QPKG_CONFIG="config.json"` (`.qdkorig`/`.qdksave` on upgrade) and `zot.sh` is the
`QPKG_SERVICE_PROGRAM`.

## Build

```sh
scripts/fetch-zot.sh     # verifies sha256 against the release checksums file
scripts/build-qpkg.sh    # -> packages/zot/build/Zot_2.1.22_x86_64.qpkg
```

Both need network. `github.com` is unreliable from here — if the fetch stalls, set
`HTTPS_PROXY=socks5h://192.168.1.204:1080`. `scripts/build-qpkg.sh` compiles
`qpkg_encrypt` from the QDK tree on first run; without it the package ships with no
checksum trailer (see `docs/qpkg-spec.md`).

## What the service script guarantees

- `Enable` is checked before start, so a disabled app is not restarted at boot.
- `cd "$QPKG_ROOT"` before exec, because `config.json` uses relative storage/log
  paths. This is what makes the same config valid on any volume and across a volume
  migration.
- `data/storage` is created before start — zot nil-derefs instead of erroring if the
  storage root is missing.
- Previous run's log is preserved as `zot.log.1` on restart; a daily cron `rotate`
  enforces a 10 MB ceiling.
- `stop` waits for graceful exit, then SIGKILLs, then `sync`.
- `remove` stops the service; the uninstaller additionally deletes the cron line via
  `PKG_PRE_REMOVE`.

## Verifying a build without a NAS

`qbuild --extract` truncates large data archives, so it is not a trustworthy check.
Decompress the two gzip streams inside the `.qpkg` directly (offsets in
`docs/qpkg-spec.md`), confirm `zot` is mode 0755 and the expected size, then drive
`zot.sh` against a fake root with stubbed `/sbin/getcfg` and `/sbin/write_log`.

That test exercised: start → `/v2/`, `/`, `/metrics` all 200 → `skopeo copy` push →
catalog → `rotate` fires above the ceiling and not below it → `stop` closes the port
and removes the pid file.

## Not done yet

- Unsigned. QTS requires App Center → "Allow installation of applications without a
  valid digital signature", or a GPG/QNAP signing step.
- Not installed on the NAS. No `.qpkg` has been run against real QTS.
- Icons are omitted; App Center falls back to defaults.
