# zot binary facts (for packaging)

Verified against upstream [project-zot/zot](https://github.com/project-zot/zot)
`v2.1.22` release assets and a locally run binary. Relevant when shipping zot as a
native QPKG payload.

## Release assets

Upstream publishes per-OS/arch binaries on GitHub Releases. For Linux:

| Asset | Size |
|---|---|
| `zot-linux-amd64` | 226.4 MB |
| `zot-linux-arm64` | 211.3 MB |
| `zot-linux-amd64-minimal` | 88.0 MB |
| `zot-linux-arm64-minimal` | 82.4 MB |

Also shipped: `zli-*` (CLI), `zb-*` (bench), `zot-schema.json`, `checksums.sha256.txt`.

No 32-bit ARM assets — only amd64 and arm64. Older QNAP ARM models
(`arm-x19`/`arm-x31`) are out of scope.

## `-minimal` is NOT usable for a pull-through cache

`-minimal` reports `binary-type: minimal`. In the Makefile:

```make
binary-minimal: EXTENSIONS=
```

Empty `EXTENSIONS` means **no `-tags`** are passed, so every extension is compiled
out. Measured behaviour of `zot-linux-amd64-minimal` v2.1.22:

| Probe | Result |
|---|---|
| `GET /v2/` | 200 |
| `GET /` (UI) | **404** |
| `GET /v2/_zot/ext/search` | **404** |
| Pull-through of an uncached upstream manifest | **404** (no proxying) |
| `/metrics` | returns an internal JSON blob, not Prometheus text |

So the minimal build has no `sync`, no `ui`, no `search`. Since the whole point of
this registry is `extensions.sync` pull-through, **the full binary is required**.

## Full build extensions

`zot --version` on the full binary:

```
binary-type: -events-imagetrust-lint-metrics-mgmt-profile-scrub-search-sync-ui-userprefs
```

Makefile defaults:

```make
ALL_EXTENSIONS = debug,imagetrust,lint,metrics,mgmt,profile,scrub,search,sync,ui,userprefs,events
EXTENSIONS ?= sync,search,scrub,metrics,lint,ui,mgmt,profile,userprefs,imagetrust,events
UI_DEPENDENCIES := search,mgmt,userprefs
```

`EXTENSIONS` is a plain build variable, so a custom build can drop extensions that
aren't needed (`lint`, `imagetrust`, `scrub`, `profile`, `events`) to shrink the
binary. `ui` pulls in `search,mgmt,userprefs` automatically.

## Linkage

Both variants are **static-PIE**:

```
file:      ELF 64-bit LSB pie executable, dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2
readelf -d: no NEEDED entries
ldd:       statically linked
```

Built with `CGO_ENABLED=0` and `BUILDMODE_FLAGS := -buildmode=pie`.

This means: no libc dependency, but an `INTERP` segment pointing at the dynamic
loader is present. QTS is glibc-based so `/lib64/ld-linux-x86-64.so.2` exists and
this runs. To eliminate the loader dependency entirely, build from source with
`BUILDMODE_FLAGS=` (empty), which yields a fully static ELF.

**Verified, not assumed:** the NAS's loader is glibc 2.21 (`ld-linux-x86-64.so.2 ->
ld-2.21.so`), and the v2.1.22 release binary was tested against that exact loader —
serve, push, pull, UI and metrics all work. See
[static-linking.md](static-linking.md).

## Compressed payload size

`gzip -9` on the 215 MB full binary → **63.5 MB**. That is roughly the data-archive
size a QPKG would carry for one architecture.

## Runtime requirements discovered by running it

- **Storage root must be creatable.** Pointing `storage.rootDirectory` at a
  non-creatable path logs `failed to create root dir ... mkdir /nonexistent:
  permission denied` and then **panics with a nil-pointer dereference** rather than
  exiting cleanly. Create the directory in `pkg_post_install`.
- **The directory for `log.output` must pre-exist.** Otherwise the process panics
  at startup with `open <path>/zot.log: no such file or directory`.
- `zot serve <config>` runs in the **foreground** and never daemonizes. QTS has no
  systemd, so the QPKG service script must background it and manage a PID file.
- Config is plain JSON; entrypoint in the container image is
  `/usr/local/bin/zot-linux-amd64 serve /etc/zot/config.json` with storage at
  `/var/lib/registry`. Neither path is mandatory for a native install.

## Why not Container Station

Container Station needs to pull the zot image from *a* registry. When the package
being installed *is* the registry the cluster depends on, that is circular. It also
couples registry availability to Container Station's health and to image survival
across App Center reinstalls. Native QPKG removes the dependency entirely.
