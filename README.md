# QNAP QPKG packaging

How to ship a third-party service as a **QPKG** — QNAP's native package format —
so it starts from local disk on a QTS NAS, without Container Station and without
downloading anything at run time.

This repo is the method plus three worked examples. The method is the point; the
packages are evidence that it works.

- **[AGENTS.md](AGENTS.md)** — the map: ground rules, verification standard, commands.
- **[docs/qpkg-service-packaging.md](docs/qpkg-service-packaging.md)** — the
  methodology: deciding QPKG vs container, auditing an upstream project, building
  against the NAS's libc, and what a package must ship at runtime.
- **[docs/nas-topology.md](docs/nas-topology.md)** — deployment state for one
  particular NAS: addresses, ports, what is installed.

## Why native packages

Two constraints, both non-negotiable:

- **No container runtime dependency.** A container-based package needs a working
  registry to pull its own image — circular when the package *is* the registry. It
  also couples uptime to Container Station staying healthy and to images surviving
  an App Center reinstall.
- **No runtime downloads.** A NAS may be isolated, and an unattended download is an
  unreviewed binary. If an app insists on fetching something at first start, that
  something gets **bundled** instead.

Packages here therefore ship a self-contained payload that QTS starts directly via
its own init sequence.

## The workflow

```
  decide ──▶ audit ──▶ fetch/build payload ──▶ assemble ──▶ verify ──▶ install
```

| Step | What happens | Reference |
|---|---|---|
| **1. Decide** | Does this belong in a QPKG at all? A service needing a database server or a multi-process runtime belongs in Container Station. Say so rather than building it. | [qpkg-service-packaging.md §1](docs/qpkg-service-packaging.md) |
| **2. Audit** | Read the upstream project *before* designing: prebuilt binaries? CGO? External tools it shells out to? A web UI? A licence that affects redistribution? Classify every dependency as **fatal at startup**, optional, or feature-gated. | [qpkg-service-packaging.md §2](docs/qpkg-service-packaging.md) |
| **3. Payload** | Prefer an upstream release binary that already runs on the NAS's libc. Otherwise build one against an older glibc and verify with `objdump -T`. Fetch it with a script that verifies upstream checksums. | [qpkg-service-packaging.md §3](docs/qpkg-service-packaging.md) |
| **4. Assemble** | `qpkg.cfg`, `package_routines`, the service script, the config, the icons. Install hooks are functions; removal hooks are variables. | [qpkg-spec.md](docs/qpkg-spec.md) |
| **5. Verify** | `qbuild` printing success proves nothing. A harness must plant the payload in a fake root and drive the real service script. | [below](#the-verification-standard) |
| **6. Install** | Only on instruction. Installing, restarting services and touching the NAS are the user's call. | [AGENTS.md](AGENTS.md) |

## The verification standard

*"Done" means the harness passes, not that the build printed success.*

Every package here has a `scripts/test-<name>.sh` that:

1. decompresses the archives inside the built `.qpkg` and checks the members, modes
   and payload;
2. plants the payload in a **fake root** with stubbed QTS helpers
   (`/sbin/getcfg`, `/sbin/write_log`) and drives the **real** service script:
   start → readiness → the app's own HTTP surface → status → rotate → stop;
3. runs the whole thing **twice**, the second time with a `PATH` containing no
   `setsid`, to exercise the fallback chain.

That third point is not decoration: QTS has no `systemd`, no `nohup`, and often no
`setsid` on `PATH`, and a missing `setsid` once cost three round trips on a real
NAS.

Anything the harness does not cover must be **stated as unverified**, not implied.

## Worked examples

Each is a different shape of problem, which is why all three are here.

| Package | Shape | What it teaches |
|---|---|---|
| [zot](packages/zot/README.md) | Upstream prebuilt static binary, config in JSON | The plain case: a release binary that already runs on the target libc |
| [OpenList](packages/openlist/README.md) | Static musl binary, env-driven config, self-generated config | A config the app creates for itself must not be shipped — it would ship a known secret |
| [Backrest](packages/backrest/README.md) | Two static binaries, the app drives a helper it would otherwise download | Bundling a dependency so the package never reaches out at run time |
| [PicoClaw](packages/picoclaw/README.md) | Two static binaries, the app's own state is user configuration | Splitting a runtime directory into *tracked seeds* and *runtime state*, so the user's API keys survive an upgrade |

| | |
|---|---|
| [docs/troubleshooting.md](docs/troubleshooting.md) | start here when something is broken — symptom → cause → fix, from real failures |
| [docs/qpkg-spec.md](docs/qpkg-spec.md) | the format itself: layout, `qpkg.cfg`, hook asymmetry, `qbuild`, build-host gotchas |
| [docs/qpkg-service-packaging.md](docs/qpkg-service-packaging.md) | the method: audit, dependency classification, building against glibc 2.21 |
| [docs/static-linking.md](docs/static-linking.md) | verifying a payload's linkage, measured rather than assumed |
| [docs/publishing.md](docs/publishing.md) | publishing a package as a GitHub release: the gates, the digest, the licence obligations |
| [docs/nas-topology.md](docs/nas-topology.md) | deployment state for one particular NAS |
| [docs/picoclaw.md](docs/picoclaw.md) | the PicoClaw package: the web console, the config seeds, the dashboard password |

## Layout

```
AGENTS.md     start here: ground rules, doc map, commands, verification standard
docs/         format notes, methodology, troubleshooting, deployment state
packages/     one directory per QPKG: qpkg.cfg, package_routines, shared/, icons/
scripts/      fetch payload, build, test without a NAS, NAS-side diagnostics
```

## Conventions that matter

- **Payloads are never committed.** They are fetched by a script that verifies
  upstream checksums, and they are gitignored.
- **Every package ships its upstream `LICENSE` and a `SOURCE.txt`** naming the
  exact upstream version it was built from. Two of the three packages are copyleft,
  and a public release is redistribution.
- **A release is published only after the harness passes**, and it carries a digest
  of the artifact rather than a claim of reproducibility — QPKG builds are not
  reproducible.
- **`data/` is created at install, never shipped.** QTS only tracks shipped files
  for obsolete-file cleanup, so a directory it never saw is never touched by an
  upgrade — and it is removed on uninstall. Nothing irreplaceable may live there.
- **User configuration and credentials live next to the service script**, protected
  by `QPKG_CONFIG`, so an upgrade cannot silently clobber them.
- **QPKG builds are not reproducible.** Two builds of identical inputs differ by a
  couple of bytes and hash differently. Verify by hashing the extracted members,
  and never present a `.qpkg` hash as reproducible from source.
- **QTS has no `systemd`.** Daemonising means probing absolute paths for `setsid`,
  then `/bin/busybox setsid`, then `sh -c` with `trap '' HUP`. Never rely on
  `command -v` alone.

## Build environment

- Build host: Fedora, with `qbuild` from
  [qnap-dev/QDK](https://github.com/qnap-dev/QDK) unpacked at `.tools/QDK`
  (gitignored).
- The build compiles `qpkg_encrypt` from the QDK tree on first run; without it the
  package ships with no checksum trailer and QTS rejects the install.
- The build host cannot reach `docker.io`, `proxy.golang.org` or `go.dev`; use
  `quay.io`, `goproxy.cn` and the aliyun mirror family. Check reachability before
  designing a build around an endpoint.
- Package install path on the NAS: `/share/<VOL>/.qpkg/<QPKG_NAME>`.

## Licence

The packaging in this repo — the scripts, the package scaffolding, the docs — is
[MIT](LICENSE).

The **payloads are not**. Each package redistributes an upstream binary under that
project's own licence, which ships inside the package as `LICENSE`, with
`SOURCE.txt` naming the exact upstream version it was built from:

| Package | Upstream licence |
|---|---|
| zot | Apache-2.0 |
| OpenList | AGPL-3.0 |
| Backrest | GPL-3.0, plus the bundled restic (BSD-3-Clause) |
| PicoClaw | MIT |

The MIT licence covers this repo's own work, not the third-party binaries it
redistributes.
