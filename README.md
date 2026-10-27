# my-qnap-packages

QPKG packages, build scripts, and packaging specs for my QNAP NAS.

## Why this exists

The NAS hosts services that the rest of the homelab depends on — notably a `zot`
OCI registry used as the **cold backup** for the K3s cluster's image registry (the
primary is the fedora host at `192.168.1.3:5000`). Those services must start from
local disk:

- **No Container Station wrapper.** A container-based package needs a working
  registry to pull its own image, which is circular when the package *is* the
  registry. It also couples service uptime to Container Station staying healthy
  and to images surviving an App Center reinstall.
- **No runtime downloads.** Nothing is fetched at start time.

So packages here ship a self-contained payload (a static binary) that QTS starts
directly via its own init sequence.

## Layout

```
docs/         QPKG format/build notes — what the toolkit actually does
packages/     One directory per QPKG: qpkg.cfg, package_routines, shared/, icons/
scripts/      Cross-package helpers (build, inspect, verify)
```

## Environment

- Build host: Fedora, `qbuild` from [qnap-dev/QDK](https://github.com/qnap-dev/QDK)
- Package install path on NAS: `/share/<VOL>/.qpkg/<QPKG_NAME>`
- QTS is glibc-based; init is QTS's own (`qpkg.conf` RC ordering), **not** systemd

## Status

**Installed and running** on the NAS as the cold backup registry:

```
http://192.168.1.40:5050        zot 2.1.22, QTS 5.2.9, QPKG
packages/zot/build/Zot_2.1.22_x86_64.qpkg   65.4 MB   (unsigned)
```

Verified end to end: `skopeo copy` push → catalog/tags/manifest digest identical to
source → pull back → inspect. Service script exercised against a fake root for
start, readiness, rotate and stop, plus on the real NAS.

Build with:

```sh
scripts/fetch-zot.sh      # payload, sha256-verified against upstream checksums
scripts/make-icons.sh /path/to/logo512.png packages/zot/icons   # optional, icons are committed
scripts/build-qpkg.sh
```

## Docs

| Doc | What it answers |
|---|---|
| [troubleshooting.md](docs/troubleshooting.md) | **Start here when it breaks.** Symptom → cause → fix, from real failures |
| [qpkg-spec.md](docs/qpkg-spec.md) | The format: layout, `qpkg.cfg` keys, hook asymmetry, `qbuild`, build-host gotchas |
| [zot-config.md](docs/zot-config.md) | Which extensions and why; the `cve` trap; logging and rotation |
| [zot-storage.md](docs/zot-storage.md) | Where blobs live, install volume vs storage volume, uninstall semantics |
| [static-linking.md](docs/static-linking.md) | Why the upstream binary runs on glibc 2.21 unmodified (tested, not assumed) |
| [zot-binary-notes.md](docs/zot-binary-notes.md) | Release assets, `-minimal` build, linkage, payload size |

## Decisions

| Item | Value |
|---|---|
| Target arch | `x86_64` |
| Listen port | `5050` — 5000 is taken by the QTS portal |
| NAS loader | glibc 2.21 (`ld-linux-x86-64.so.2 -> ld-2.21.so`) — QTS pins it deliberately |
| QTS version | 5.2.9 (so `QTS_MINI_VERSION="5.0.0"` is correct) |
| zot payload | Upstream `zot-linux-amd64` v2.1.22 prebuilt — verified against glibc 2.21 |
| Storage | `${QPKG_ROOT}/data` — see [docs/zot-storage.md](docs/zot-storage.md) |
| Install volume | Admin picks at install → `QPKG_VOLUME_SELECT="3"` |
| Extensions | `storage`, `search`, `ui`, `metrics` — **no `sync`, no `cve`** ([zot-config.md](docs/zot-config.md)) |
| Image sync | Done externally; the NAS never reaches upstream. Deliberate, not unfinished |
| Logging | `level: warn`; size cap via QTS cron (10 MB, keep 3), not start-based rotation |
| Populated by | LAN `skopeo copy` from the fedora zot, no upstream access |

