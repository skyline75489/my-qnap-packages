# AGENTS.md

Instructions for anyone — agent or human — working in this repo. Read this first; it
is the map. Details live in `docs/`.

## What this repo is

Builds QPKG packages for a QNAP NAS (QTS 5.2.9). Three packages today:

- **zot**, an OCI registry deployed as the K3s cluster's **cold backup** at
  `192.168.1.40:5050`. The primary registry is the fedora host at
  `192.168.1.3:5000`.
- **OpenList**, a file-list / storage gateway at `192.168.1.40:5244`. Installed
  and enabled on the NAS.
- **Backrest**, a restic backup orchestrator with a web UI at
  `192.168.1.40:9898`. Installed and enabled on the NAS.

The point of the packages is that they need no Container Station and no runtime
downloads: a registry that boots from an image registry is circular, so it ships as a
static binary that QTS starts directly.

**Not every service belongs here.** Before starting a new package, work through
`docs/qpkg-service-packaging.md`: deciding QPKG vs container, auditing an upstream
project's native libraries and external tools, and building something that runs on the
NAS's glibc 2.21. A service that needs a database server or a multi-process runtime
belongs in Container Station — say so rather than building it.

## Ground rules

1. **Build freely, install only on instruction.** `scripts/build-qpkg.sh` and
   `scripts/test-package.sh` are local and safe. Installing on the NAS, restarting
   services there, or touching the K3s nodes is the user's call.
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

`test-package.sh` is the real gate, and so are its siblings for the other
packages. Each plants the payload in a fake root with stubbed QTS helpers
(`/sbin/getcfg`, `/sbin/write_log`) and drives the actual service script:
start → readiness → the app's own HTTP surface → status → rotate → stop. Each runs
twice, the second time with a `PATH` containing no `setsid`, which is the regression
test for the bug that cost three round trips on the real NAS.

Anything not covered there must be stated as unverified, not implied.

**Do not let the test scripts inherit `PORT` from the environment.** A dev host
often has `PORT` set to something else; the tests would then talk to a foreign
service and report nonsense failures. Both test scripts use `TEST_PORT`.

## Doc map

| Read | When |
|---|---|
| **docs/troubleshooting.md** | Something is broken. Symptom → cause → fix, from real failures |
| **docs/qpkg-spec.md** | Working on the format itself: layout, `qpkg.cfg`, hook asymmetry, `qbuild`, build-host gotchas |
| **docs/qpkg-service-packaging.md** | Wrapping a new third-party service: QPKG vs container, dependency audit, building against glibc 2.21 |
| **docs/zot-config.md** | Touching extensions, logging, or rotation |
| **docs/zot-storage.md** | Storage paths, install volume vs storage volume, uninstall semantics |
| **docs/static-linking.md** | Why the upstream binary runs on glibc 2.21 unmodified (measured, not assumed) |
| **docs/zot-binary-notes.md** | Release assets, the `-minimal` build, linkage, payload size |
| **docs/openlist.md** | The OpenList package: env vars, config paths, first start, licensing |
| **docs/backrest.md** | The Backrest package: why restic is bundled, ports, paths, authentication |
| **packages/zot/README.md** | What's inside the zot package and how the service script behaves |
| **packages/openlist/README.md** | What's inside the OpenList package and how the service script behaves |
| **packages/backrest/README.md** | What's inside the Backrest package and how the service script behaves |

## Commands

```sh
scripts/fetch-zot.sh                     # payload -> packages/zot/x86_64/zot (sha256-checked)
scripts/fetch-openlist.sh                # payload -> packages/openlist/x86_64/openlist (md5 + sha256)
scripts/fetch-backrest.sh                # payloads -> packages/backrest/x86_64/{backrest,restic} (sha256)
scripts/make-icons.sh <logo.png> <dir> [name]   # regenerate App Center icons (icons/ is committed)
scripts/build-qpkg.sh [package]          # qbuild --strict; needs .tools/QDK
scripts/test-package.sh [pkg.qpkg]       # verify the zot package without a NAS
scripts/test-openlist.sh [pkg.qpkg]      # verify the OpenList package without a NAS
scripts/test-backrest.sh [pkg.qpkg]      # verify the Backrest package without a NAS
scripts/debug-zot-qpkg.sh                # READ-ONLY, runs ON the NAS as root
```

The build needs QDK unpacked at `.tools/QDK` (gitignored) and, on a non-NAS host,
`qpkg_encrypt` compiled from its `src/` — `build-qpkg.sh` does that automatically. It
also sets `QDK_SCRIPTS_DIR`/`QDK_TEMPLATE_DIR` because the QDK *repo* keeps them under
`shared/` while an installed QDK does not.

## Environment facts (verified, not assumed)

- **NAS is x86_64**, QTS 5.2.9, glibc **2.21** — QTS pins it deliberately, so build
  targets must not assume a newer libc. The upstream zot binary is static-PIE and
  needs only `/lib64/ld-linux-x86-64.so.2`.
- **Port 5000 is the QTS portal.** The packages use **5050** (zot), **5244**
  (OpenList) and **9898** (Backrest).
- **QTS has no `systemd`, no `nohup`, and often no `setsid` on `PATH`.** Daemonising
  means probing absolute paths for `setsid`, then `/bin/busybox setsid`, then
  `sh -c` with `trap '' HUP`. Never rely on `command -v` alone.
- **The build host cannot reach `docker.io`, `proxy.golang.org`, or `go.dev`.** Use
  `quay.io` for base images, `goproxy.cn` for Go modules, and the aliyun mirror family
  for CentOS/EPEL archives and the Go tarball. `github.com` and `nodejs.org` work.
  Check reachability before designing a build around an endpoint.
- **A failed start leaves the app silently disabled.** If a port refuses connections,
  check `getcfg Zot Enable` before anything else.
- Arch support is `x86_64`, `x86`, `arm_64`, `arm-x41` only.
- **All three packages are installed and enabled on the NAS** (verified 2026-11-06:
  App Center reports them installed and enabled, and each answers on its port).
  `/etc/init.d/<name>.sh restart` is the confirmed way to restart one.

## Package layout

```
packages/zot/
  qpkg.cfg            metadata (name <=20 chars, version <=10)
  package_routines    install hooks as FUNCTIONS; removal hooks as VARIABLES
  shared/             config.json, zot.sh -> installed at $QPKG_ROOT
  icons/              Zot.gif 64x64, Zot_gray.gif 64x64, Zot_80.gif 80x80
  x86_64/             payload (gitignored)

packages/openlist/
  qpkg.cfg            metadata (name <=20 chars, version <=10)
  package_routines    install hooks as FUNCTIONS; removal hooks as VARIABLES
  shared/             openlist.sh -> installed at $QPKG_ROOT
  icons/              OpenList.gif 64x64, OpenList_gray.gif 64x64, OpenList_80.gif 80x80
  x86_64/             payload (gitignored)

packages/backrest/
  qpkg.cfg            metadata (name <=20 chars, version <=10)
  package_routines    install hooks as FUNCTIONS; removal hooks as VARIABLES
  shared/             config.json, backrest.sh -> installed at $QPKG_ROOT
  icons/              Backrest.gif 64x64, Backrest_gray.gif 64x64, Backrest_80.gif 80x80
  x86_64/             payloads: backrest AND restic (gitignored)
```

`data/` is created imperatively in `pkg_install()`, never shipped, so upgrades leave it
alone. Install hooks being functions while removal hooks are variables is the single
easiest thing to get wrong — a `PKG_POST_INSTALL` variable is accepted and ignored.

## Registry topology

Do not confuse these; getting it wrong has already cost time.

| Address | Role |
|---|---|
| `192.168.1.3:5000` | **primary** zot, fedora host, pull-through enabled |
| `192.168.1.40:5050` | **cold backup** zot, this QPKG. No sync, no auth, promoted manually |
| `192.168.1.2` | **not a registry** — a k3s node (`skyline-alpine`) |
| `192.168.1.206:5000` | dead; in-cluster zot removed 2026-07-06 |

The cold backup is deliberately absent from `registries.yaml` so containerd never
waits on a powered-down host. Population is by LAN `skopeo copy --all`; always use
`--all` so the multi-arch index and therefore the digest match the source.

## QPKG builds are not reproducible

Two builds of identical inputs differ by ~2 bytes and hash differently, because the
data archive's temp directory mtime lands in the tar. Verify by hashing the **extracted
members**, and never present a `.qpkg` hash as reproducible from source.
