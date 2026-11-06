# packages/openlist — the OpenList QPKG

Native-binary QPKG for the QNAP NAS. No Container Station, nothing downloaded at
install or at start time.

OpenList (fork of AList) is a file-list / storage-gateway program: it mounts cloud
and local backends (OneDrive, Google Drive, S3, SMB, …) and serves them over a web
UI, WebDAV, S3 and FTP. This package ships the upstream Linux binary and lets QTS
start it like any other service.

Decisions behind it: [`../../docs/openlist.md`](../../docs/openlist.md).

## Layout

```
qpkg.cfg              metadata: name/version, service script, port 5244, volume select 3
package_routines      install hooks (data dirs, chown, cron) + pre-remove (stop, cron)
shared/openlist.sh    start|stop|restart|status|rotate|remove
shared/openlist.env   commented template for environment overrides (optional)
icons/                OpenList.gif 64x64, OpenList_gray.gif 64x64, OpenList_80.gif 80x80
x86_64/openlist       the payload; fetched, never committed
```

Icons are generated from the upstream OpenList mark (`OpenListTeam/Logo`
`logo/256x256.png`, **CC BY-NC-SA 4.0**) by `scripts/make-icons.sh`, flattened onto
white so the light logo stays visible on a dark App Center theme.

There is **no shipped `config.json`**. OpenList creates `data/config.json` on first
start, including a random `jwt_secret`. Shipping one would ship a known secret to
every install, so the package ships none.

## Build

```sh
scripts/fetch-openlist.sh   # verifies md5 against upstream + sha256 against our pin
scripts/build-qpkg.sh openlist   # -> packages/openlist/build/OpenList_4.2.9_x86_64.qpkg
scripts/test-openlist.sh    # 43 assertions, no NAS needed
```

`github.com` is unreliable from here — set `HTTPS_PROXY=http://192.168.1.208:8888`
if a fetch stalls.

The payload is the **musl** build (`openlist-linux-musl-amd64`), which upstream
links statically. It therefore does not care about the NAS's glibc 2.21 at all.

## What the service script guarantees

- `Enable` is checked before start, so a disabled app is not restarted at boot.
- `cd "$QPKG_ROOT"` before exec: the paths OpenList puts in its config
  (`data/data.db`, `data/temp`, `data/log/log.log`) are relative to the working
  directory, which is what makes the package survive a volume migration.
- The listen port is pinned through `OPENLIST_HTTP_PORT`, taken from
  `QPKG_WEB_PORT`. The service and the QTS proxy cannot drift apart.
- `data/`, `data/log` and `data/temp` are created before start with `umask 077`:
  the sqlite database, the `jwt_secret` and (on first start) the admin password
  are not world-readable on a multi-user NAS. Upstream writes `config.json` with
  mode 0777; the script takes the permissions back to 0600.
- Previous run's console log is preserved as `console.log.1` on restart; a daily
  cron `rotate` enforces a 10 MB ceiling. OpenList rotates its own
  `data/log/log.log` itself.
- `stop` waits for graceful exit, then SIGKILLs, then `sync` (the database is in
  WAL mode).
- `remove` stops the service; the uninstaller additionally deletes the cron line
  via `PKG_PRE_REMOVE`.

## First start

OpenList v4 does **not** create an admin account on its own. Two ways:

1. Open the web UI — the setup wizard asks for the admin password.
2. Edit the shipped `$SYS_QPKG_DIR/openlist.env` template and set a password:

   ```sh
   OPENLIST_ADMIN_PASSWORD=<password>
   ```

   The service script sources that file (with `set -a`, so the variables are
   exported) and OpenList then creates `admin` with that password and prints it
   once to `data/log/console.log`; the script copies that line to the QTS system
   log.

## Not done yet

- Unsigned. QTS requires App Center → "Allow installation of applications without a
  valid digital signature", or a GPG/QNAP signing step.
- **Installed and enabled** on the NAS (2026-11-06). Verified from the LAN: `/` and
  `/api/public/settings` answer 200, and the package's own `config.json` and
  `data/` tree are in place.
- Only `x86_64`. The upstream musl builds also exist for arm64/386/arm, but the
  QNAP `arm-x41` mapping has not been worked out.
