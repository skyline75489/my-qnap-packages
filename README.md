# my-qnap-packages

QPKG packages, build scripts, and packaging specs for my QNAP NAS.

## Why this exists

The NAS hosts services that the rest of the homelab depends on — notably the `zot`
OCI registry the K3s cluster pulls images from. Those services must start from
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

Spec notes landed. No packages built yet.

## Decisions

| Item | Value |
|---|---|
| Target arch | `x86_64` |
| Listen port | `5050` — 5000 is taken by the QTS portal |

