# AGENTS.md

Instructions for anyone — agent or human — working in this repo. Read this first; it
is the map. Details live in `docs/`.

## What this repo is

A **method** for packaging third-party services as QPKG packages for a QNAP NAS,
plus three worked examples of it.

The packages share two constraints, and those constraints are the reason the repo
exists:

- **No container runtime dependency.** A container-based package needs a working
  registry to pull its own image — circular when the package *is* the registry. It
  also couples uptime to Container Station and to images surviving an App Center
  reinstall.
- **No runtime downloads.** The NAS may be isolated, and an unattended download is an
  unreviewed binary. If an app insists on fetching something at first start, that
  something gets **bundled** instead.

**Not every service belongs in a QPKG.** Before starting a new package, work
through `docs/qpkg-service-packaging.md`: deciding QPKG vs container, auditing an
upstream project's native libraries and external tools, and building something that
runs on the NAS's glibc 2.21. A service that needs a database server or a
multi-process runtime belongs in Container Station — say so rather than building it.

The worked examples, each a different shape of problem: **zot** (prebuilt static
binary, JSON config), **OpenList** (static musl binary, self-generated config),
**Backrest** (two static binaries, a helper that would otherwise be downloaded),
**PicoClaw** (two static binaries, the app's own state is user configuration).
Per-package decisions live in each package's README and in `docs/<name>.md`.

## Ground rules

1. **Build freely, install only on instruction.** The `scripts/fetch-*` and
   `scripts/build-*` scripts are local and safe. Installing on the NAS, restarting
   services there, or touching anything else in the deployment is the user's call.
2. **Never re-add `sync` or a `cve` block to the zot config.** Both are recorded
   decisions with reasons, not oversights — see `docs/zot-config.md`. `sync` off keeps
   the bootstrap layer free of upstream TLS and proxy concerns; the `cve` block forces
   2h scanning and a 3.1 GB Trivy DB even when set to `0`.
3. **Never commit the payload, `build/`, or `.tools/`.** All gitignored. Check
   `git status` before committing; the zot payload alone is 226 MB.
4. **Do not trust `qbuild`'s success output.** It reports success for packages missing
   their checksum, and its `--extract` corrupts large archives. Verify per the
   standard below.
5. **Data under `$QPKG_ROOT/data` dies on uninstall** (`rsync --delete` + `rm -rf`).
   That is intentional for these packages (caches and rebuildable state), but never
   put anything there that cannot be rebuilt. User configuration and credentials
   belong next to the service script, protected by `QPKG_CONFIG`.
6. **Keep the method general and the deployment separate.** `docs/` and this file
   describe *how to package a service*; addresses, ports and what happens to be
   installed belong in `docs/nas-topology.md`. A fact that only holds for one
   deployment does not belong in the ground rules.
7. **Publish only what the harness verified.** `scripts/release.sh` runs the
   harness and refuses to publish on failure. It also refuses a package that does
   not ship its upstream `LICENSE` and `SOURCE.txt`, and it publishes a digest of
   the artifact rather than a claim of reproducibility — QPKG builds are not
   reproducible. See `docs/publishing.md`.
8. **The repo's own work is MIT; the payloads are not.** The scripts, scaffolding
   and docs are MIT (`LICENSE` at the root). Each package redistributes an
   upstream binary under *that* project's licence, and must ship the upstream
   `LICENSE` text plus a `SOURCE.txt` naming the exact upstream version.
9. **QTS runs a package's service script as root. Ask what the app does with
   that.** An app that executes commands — an LLM agent, a script runner, a
   plugin host — turns model output, a webhook or a web page into root code
   execution on the NAS. Before packaging one, find out which *capability* is
   the dangerous one: an agent that can read files is often confined by the
   app itself, while the shell tool is the hole. Grant the safe capability
   explicitly (an allow list of paths) and take away the dangerous one
   (`exec` off by default, a sandbox for what remains), and drop privileges as
   defence in depth rather than as the fix. The PicoClaw package is in the repo
   unpublished for exactly this reason — see `docs/picoclaw.md`.

## Verification standard

"Done" means all three, not the first:

```sh
scripts/fetch-zot.sh        # payload sha256 verified against upstream checksums
scripts/build-qpkg.sh       # builds; its output alone proves nothing
scripts/test-package.sh     # 33 assertions: structure, runtime, detach branches
```

For the OpenList package the same three steps are `scripts/fetch-openlist.sh`,
`scripts/build-qpkg.sh openlist` and `scripts/test-openlist.sh` (43 assertions).
For the Backrest package: `scripts/fetch-backrest.sh`,
`scripts/build-qpkg.sh backrest` and `scripts/test-backrest.sh` (45 assertions).
For the PicoClaw package: `scripts/fetch-picoclaw.sh`,
`scripts/build-qpkg.sh picoclaw` and `scripts/test-picoclaw.sh` (117 assertions).

`test-package.sh` is the real gate, and so are its siblings for the other
packages. Each plants the payload in a fake root with stubbed QTS helpers
(`/sbin/getcfg`, `/sbin/write_log`) and drives the actual service script:
start → readiness → the app's own HTTP surface → status → rotate → stop. Each runs
twice, the second time with a `PATH` containing no `setsid`, which is the regression
test for the bug that cost three round trips on the real NAS.

A new package needs the same three scripts under the same names, and its harness
must assert what is *specific* to it — for Backrest, that the bundled helper was
used and that nothing was downloaded.

Anything not covered there must be stated as unverified, not implied.

**Do not let the test scripts inherit `PORT` from the environment.** A dev host
often has `PORT` set to something else; the tests would then talk to a foreign
service and report nonsense failures. Every test script uses `TEST_PORT`.

## Doc map

| Read | When |
|---|---|
| **docs/qpkg-service-packaging.md** | Starting a new package: does it belong in a QPKG, what does it depend on, how to build it against glibc 2.21 |
| **docs/troubleshooting.md** | Something is broken. Symptom → cause → fix, from real failures |
| **docs/qpkg-spec.md** | Working on the format itself: layout, `qpkg.cfg`, hook asymmetry, `qbuild`, build-host gotchas |
| **docs/static-linking.md** | Verifying a payload's linkage — measured, not assumed |
| **docs/publishing.md** | Publishing a package as a GitHub release: the gates, the digest, the licence obligations |
| **docs/nas-topology.md** | Deployment state for one particular NAS: addresses, ports, what is installed |
| **docs/zot-config.md** | Touching extensions, logging, or rotation |
| **docs/zot-storage.md** | Storage paths, install volume vs storage volume, uninstall semantics |
| **docs/zot-binary-notes.md** | Release assets, the `-minimal` build, linkage, payload size |
| **docs/openlist.md** | The OpenList package: env vars, config paths, first start, licensing |
| **docs/backrest.md** | The Backrest package: why restic is bundled, ports, paths, authentication |
| **docs/picoclaw.md** | The PicoClaw package: the web console, the config seeds, the dashboard password |
| **packages/*/README.md** | What's inside each package and how its service script behaves |

## Commands

```sh
scripts/fetch-zot.sh                     # payload -> packages/zot/x86_64/zot (sha256-checked)
scripts/fetch-openlist.sh                # payload -> packages/openlist/x86_64/openlist (md5 + sha256)
scripts/fetch-backrest.sh                # payloads -> packages/backrest/x86_64/{backrest,restic} (sha256)
scripts/fetch-picoclaw.sh                # payloads -> packages/picoclaw/x86_64/{picoclaw,picoclaw-launcher} (sha256)
scripts/make-icons.sh <logo.png> <dir> [name]   # regenerate App Center icons (icons/ is committed)
scripts/build-qpkg.sh [package]          # qbuild --strict; needs .tools/QDK
scripts/test-package.sh [pkg.qpkg]       # verify the zot package without a NAS
scripts/test-openlist.sh [pkg.qpkg]      # verify the OpenList package without a NAS
scripts/test-backrest.sh [pkg.qpkg]      # verify the Backrest package without a NAS
scripts/test-picoclaw.sh [pkg.qpkg]      # verify the PicoClaw package without a NAS
scripts/debug-zot-qpkg.sh                # READ-ONLY, runs ON the NAS as root
scripts/release.sh <package>             # publish a built .qpkg as a GitHub release
```

The build needs QDK unpacked at `.tools/QDK` (gitignored) and, on a non-NAS host,
`qpkg_encrypt` compiled from its `src/` — `build-qpkg.sh` does that automatically. It
also sets `QDK_SCRIPTS_DIR`/`QDK_TEMPLATE_DIR` because the QDK *repo* keeps them under
`shared/` while an installed QDK does not.

## QTS facts that shape every package

These are properties of the target, not of any one service. They are the ones that
have actually bitten.

- **The target is x86_64**, QTS 5.2.9, glibc **2.21** — QTS pins it deliberately, so
  build targets must not assume a newer libc. Verify a payload's requirement with
  `objdump -T <binary> | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3`; every symbol
  must be ≤ 2.21.
- **Port 5000 is the QTS portal.** Packages here use 5050, 5244 and 9898.
- **`/tmp` is a small tmpfs.** Anything that writes temporary files has to be
  pointed elsewhere — `TMPDIR` for a program that respects it, an explicit cache
  directory otherwise. restic writes its in-progress pack files to `os.TempDir()`,
  so a backup that outgrows the tmpfs dies with "no space left on device" while
  saving the snapshot. See `docs/troubleshooting.md`.
- **QTS has no `systemd`, no `nohup`, and often no `setsid` on `PATH`.** Daemonising
  means probing absolute paths for `setsid`, then `/bin/busybox setsid`, then
  `sh -c` with `trap '' HUP`. Never rely on `command -v` alone.
- **A failed start leaves the app silently disabled.** If a port refuses connections,
  check `getcfg <Name> Enable` before anything else.
- **A fresh install is disabled by design**, and QTS still runs the init script at
  boot when disabled — which is why every service script checks `Enable` first.
- **Install hooks are functions; removal hooks are variables.** A `PKG_POST_INSTALL`
  *variable* is accepted and silently ignored. This is the single easiest thing to
  get wrong.
- **QTS generates `/etc/init.d/<name>.sh`** at install time; `restart` there calls the
  package's own script with stop then start.
- Arch support is `x86_64`, `x86`, `arm_64`, `arm-x41` only.

## Build-host facts

- **The build host cannot reach `docker.io`, `proxy.golang.org`, or `go.dev`.** Use
  `quay.io` for base images, `goproxy.cn` for Go modules, and the aliyun mirror family
  for CentOS/EPEL archives and the Go tarball. `github.com` and `nodejs.org` work.
  Check reachability before designing a build around an endpoint.

## Package layout

```
packages/<name>/
  qpkg.cfg            metadata (name <=20 chars, version <=10)
  package_routines    install hooks as FUNCTIONS; removal hooks as VARIABLES
  shared/             config, service script -> installed at $QPKG_ROOT
  icons/              <Name>.gif 64x64, <Name>_gray.gif 64x64, <Name>_80.gif 80x80
  x86_64/             payload (gitignored)
```

`data/` is created imperatively in `pkg_install()`, never shipped, so upgrades leave it
alone.

## QPKG builds are not reproducible

Two builds of identical inputs differ by ~2 bytes and hash differently, because the
data archive's temp directory mtime lands in the tar. Verify by hashing the **extracted
members**, and never present a `.qpkg` hash as reproducible from source.
