# Deployment notes — this NAS

Everything here is **deployment state**, not methodology. It changes when the
deployment changes; the method lives in [../AGENTS.md](../AGENTS.md) and
[qpkg-service-packaging.md](qpkg-service-packaging.md).

Keep this file short and factual. If a fact here is contradicted by reality, reality
wins — fix the file.

## The target

| | |
|---|---|
| Model | QNAP TS-551 (internal TS-XA51) |
| CPU | Intel Celeron J3355, 2 cores, no AVX |
| Memory | 8 GB |
| Firmware | QTS 5.2.9 |
| libc | **glibc 2.21** — QTS pins it deliberately |
| Architecture | `x86_64` |
| Hostname | `SKYLINE-QNAP` |
| Address | `192.168.1.40` |

The 2.21 libc is the constraint that shapes every build here: a payload built
against a newer glibc will not load. See
[qpkg-service-packaging.md](qpkg-service-packaging.md).

## Packages installed

All three are installed, enabled and answering (last verified 2026-11-06).

| Package | Port | Installed path | Notes |
|---|---|---|---|
| zot 2.1.22 | 5050 | `/share/<VOL>/.qpkg/Zot` | cold backup OCI registry |
| OpenList 4.2.9 | 5244 | `/share/<VOL>/.qpkg/OpenList` | file list / storage gateway |
| Backrest 1.14.1 | 9898 | `/share/<VOL>/.qpkg/Backrest` | restic orchestrator, web UI |

`<VOL>` is whichever volume was chosen at install time (`QPKG_VOLUME_SELECT="3"`).
Resolve it rather than guessing:

```sh
/sbin/getcfg Backrest Install_Path -f /etc/config/qpkg.conf
```

Port 5000 is the QTS portal and is never used by a package here.

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

## Operational notes

- **Restart:** `/etc/init.d/<name>.sh restart` — confirmed working on QTS 5.2.9 for
  all three packages. See [troubleshooting.md](troubleshooting.md).
- **Status:** `sh <Install_Path>/<name>.sh status`.
- **A failed start leaves the package silently disabled.** Check
  `/sbin/getcfg <Name> Enable -f /etc/config/qpkg.conf` before anything else.
- **Config and data locations** differ per package: OpenList keeps its config under
  `data/` (regenerated on reinstall), Backrest keeps it next to the service script
  (survives upgrades). See each package's README.
- **Backrest's authentication is disabled** by default. Create a user in its UI
  before exposing port 9898 to anything untrusted.

## Verifying the deployment

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.40:5050/v2/            # zot
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.40:5244/api/public/settings  # OpenList
curl -s -X POST -H 'Content-Type: application/json' -d '{}' \
     http://192.168.1.40:9898/v1.Backrest/GetConfig                              # Backrest
```

App Center state (installed/enabled/version) is readable through the QTS API.
