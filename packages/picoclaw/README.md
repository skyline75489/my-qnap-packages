# packages/picoclaw — the PicoClaw QPKG

Native-binary QPKG for the QNAP NAS. There is no Container Station dependency and
nothing is downloaded at install time — or at run time.

Decisions behind it: [`../../docs/picoclaw.md`](../../docs/picoclaw.md).

## Layout

```
qpkg.cfg                metadata: name/version, service script, port 18800, volume select 3
package_routines        install hooks (data dirs, chown, cron) + pre-remove (stop, cron)
shared/picoclaw.sh      start|stop|restart|status|rotate|remove
shared/home/config.json  seed: the config the launcher fills in at first start
shared/home/.security.yml  seed: the secrets file — API keys and channel tokens
shared/LICENSE          the upstream MIT licence
shared/SOURCE.txt       which upstream version this was built from
icons/                  PicoClaw.gif 64x64, PicoClaw_gray.gif 64x64, PicoClaw_80.gif 80x80
x86_64/picoclaw         the CLI/agent; fetched, never committed
x86_64/picoclaw-launcher  the web console; fetched, never committed
```

Icons are generated from the upstream app icon (`web/backend/icon.png`, MIT) by
`scripts/make-icons.sh`, flattened onto white so the dark mark stays visible on a
dark App Center theme.

`shared/` lands at `$SYS_QPKG_DIR`, so `home/config.json` and `home/.security.yml`
are protected by `QPKG_CONFIG="home/config.json home/.security.yml"`
(`.qdkorig`/`.qdksave` on upgrade) and `picoclaw.sh` is the
`QPKG_SERVICE_PROGRAM`.

## Two payloads, not one

The upstream release tarball carries two binaries and they belong together:

| Binary | What it is |
|---|---|
| `picoclaw` | the CLI and the agent — `picoclaw agent`, `picoclaw gateway` |
| `picoclaw-launcher` | the web console and gateway manager — the long-running process this package runs |

The launcher finds the CLI **next to itself** (`utils.FindPicoclawBinary`), so
both are installed side by side in the package root. `PICOCLAW_BINARY` is set
explicitly anyway, because the fallback is `$PATH` and the QTS `PATH` is not ours.

Both binaries are **statically linked** (`CGO_ENABLED=0` upstream), so the NAS's
glibc 2.21 is not a constraint — `objdump -T` finds no `GLIBC_*` symbol in
either. The fetch script and the test harness both check this rather than
assuming it.

## The seeds, and why they are seeds

PicoClaw keeps its state in `PICOCLAW_HOME` (default `~/.picoclaw`):

| File | Holds |
|---|---|
| `config.json` | the model list, the channel settings, the gateway settings |
| `.security.yml` | API keys and channel tokens |
| `launcher-auth.db` | the dashboard password (SQLite, via `modernc.org/sqlite`) |
| `logs/`, `workspace/` | the launcher's logs and the agent's workspace |

The package ships a **minimal seed** of the first two and points the launcher at
them with `PICOCLAW_CONFIG`. At first start the launcher fills the seed in
locally — the config grows to the full default (30 models, every channel) and a
per-install channel token is generated. Nothing is downloaded, and no secret is
shipped: the seed's `.security.yml` has no token, and the one the launcher
generates differs on every install.

Listing both files in `QPKG_CONFIG` is what makes the user's edits survive an
upgrade. The mechanism is file-based (the QDK compares md5 sums), so a directory
would not do.

## What the service script guarantees

- `Enable` is checked before start, so a disabled app is not restarted at boot.
- Both binaries must be present and executable, else start fails. The launcher
  drives the CLI; without it, it would fall back to `$PATH`.
- All paths handed to the app are absolute and inside `$QPKG_ROOT`
  (`PICOCLAW_HOME`, `PICOCLAW_CONFIG`, `PICOCLAW_BINARY`, `HOME`, `TMPDIR`), so
  they stay valid across a volume migration.
- `TMPDIR` points at `$QPKG_ROOT/data/tmp`. QTS's `/tmp` is a small tmpfs, and
  the same reasoning that applies to restic applies here.
- `HOME` points at `$QPKG_ROOT/home`, so the agent's `~/.ssh` key and its caches
  stay on the volume instead of in `/root`.
- The console is bound to every interface with `-public` (upstream defaults to
  localhost, which is unreachable from a browser on the LAN). Set a
  `Listen_Host` entry in `/etc/config/qpkg.conf` to bind it to one address.
- It waits for the **listen socket**, not just the pid: QTS returns from `start`
  and immediately offers the UI, and a client in that window gets ECONNREFUSED.
- `stop` sends **SIGTERM** first. The launcher traps it and shuts its HTTP server
  and its SQLite database down in order.
- Previous run's log is preserved as `picoclaw.log.1` on restart; a daily cron
  `rotate` enforces a 10 MB ceiling on both the service log and the launcher's own.
- `remove` stops the service; the uninstaller additionally deletes the cron line via
  `PKG_PRE_REMOVE`.

## Build

```sh
scripts/fetch-picoclaw.sh      # verifies sha256 against upstream's checksums file
scripts/build-qpkg.sh picoclaw  # -> packages/picoclaw/build/PicoClaw_0.3.1_x86_64.qpkg
```

## Verifying a build without a NAS

```sh
scripts/test-picoclaw.sh
```

117 assertions: the package structure, both payloads present and statically linked,
the seeds carrying no secret — then the real service script driven against a fake
root with stubbed `/sbin/getcfg` and `/sbin/write_log`:

- start → `/` answers 302 and `/launcher-login` answers 200, while
  `/api/config` answers **401** — the API is not open before a dashboard password
  is set;
- the password flow works: the setup endpoint rejects a short password and a
  mismatch, accepts a real one, stores it as a **bcrypt (cost 12) hash** with no
  plaintext on disk, and a login then unlocks the API;
- the shipped config was **filled in locally** (a model list appeared) and a
  per-install channel token was **generated**;
- nothing was downloaded, and nothing unexpected appeared in the package root;
- `rotate` fires above the ceiling and not below it;
- `stop` closes the port and removes the pid file.

It runs three times: normally, with **every proxy variable pointed at a closed
port** (the console must still come up — this package must not need the internet
to serve its UI), and with a `PATH` containing no `setsid`.

## Not done yet

- Unsigned. QTS requires App Center → "Allow installation of applications without a
  valid digital signature", or a GPG/QNAP signing step.
- **Not installed on the NAS.** Nothing here has been exercised on real QTS.
- The dashboard password is not set by the package: the launcher prints
  "First-time setup: open /launcher-setup to create the dashboard password", and
  the service script repeats the warning in the package log. Set one at
  `http://<nas>:18800/launcher-setup` — at least 8 characters, and the two
  fields must match. Until then, `/api/*` refuses to answer, but the setup page
  itself is reachable by anyone who can reach the port.
- The agent itself is **not** exercised: no model is configured, no API key is
  set, and the `picoclaw gateway` process (which the launcher starts and stops
  from the web console) is never started by the package. The harness covers the
  web console, the service lifecycle and the config wiring.
- Only `x86_64` is packaged. Upstream also builds arm64, riscv64, armv6/7,
  mipsle, s390x and loong64; QTS supports `x86_64`, `x86`, `arm_64` and
  `arm-x41`, so `arm_64` is the obvious next one.
