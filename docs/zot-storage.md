# Where zot stores its data

zot has three writable paths. They have different durability needs, and the QPKG
lifecycle treats them very differently.

| Path | zot config key | Contents | Must survive uninstall? |
|---|---|---|---|
| Blob store | `storage.rootDirectory` | image layers, manifests, metadata DB | **Yes** — irreplaceable |
| Log | `log.output` | zot.log | No |
| Config | (passed on argv) | `config.json` | Yes — but small, handled by `QPKG_CONFIG` |

## The constraint that decides everything

`qinstall.sh` generates an uninstall script that empties the install tree with
`rsync -a --delete /tmp/qpkg_blankdir "$SYS_QPKG_DIR"` and then `rm -fr`. So the
default install path — `/share/<VOL>/.qpkg/<NAME>` — is **ephemeral**. Putting the
blob store there means uninstalling the app (or an App Center "remove") deletes
every cached image, with no recycle bin.

For a registry that is a bad failure mode: the store is the expensive part to
rebuild, and it is exactly what pull-through latency depends on.

`PKG_PRE_REMOVE` runs *before* the wipe, so it is technically possible to move data
out on uninstall — but that is fragile (runs as a one-shot shell block, no retry, and
a large move could exceed `QPKG_TIMEOUT`). Not the design to rely on.

## Install volume vs storage volume — two independent knobs

These get conflated, so to be explicit:

| | Install volume | Storage volume |
|---|---|---|
| Controlled by | `QPKG_VOLUME_SELECT` → `Volume_Select` in `qpkg.conf` | whatever path the config points at |
| Holds | the ~215 MB package payload | blobs, metadata, logs |
| Path | `/share/<VOL>/.qpkg/<NAME>` | anything |
| Survives uninstall | **no** | yes, if outside `.qpkg/<NAME>` |

The install volume only decides where the *package* unpacks. It does not constrain
where data lives, and it does not survive uninstall. So these can differ: install the
215 MB payload on the default volume and put blobs on whichever volume has the space.

A "share" is **not** a different kind of storage — it is just a directory on a volume
that QTS also manages. The share-vs-volume-root choice is about management features,
not physical location:

| | Share | Plain dir at volume root |
|---|---|---|
| Path | `/share/<VOL>/<sharename>/...` | `/share/<VOL>/zot-storage/...` |
| Survives uninstall | yes | yes |
| Per-share quota | yes | no |
| File Station visibility | yes | no |
| Snapshot-able as a share | yes | volume-level only |
| Setup step | share must exist | none |

`/share/CACHEDEV1_DATA` is the QTS 5.x volume mount convention — `DownloadCenter`'s
build script even greps for `/share/CACHEDEV` and `/mnt/HDA_ROOT` as
machine-specific paths to keep out of its package.

### Real-world counterexample

The most mature native Go QPKG I found, `tasict/DownloadCenter`, puts run-time data
**inside** the install path:

```sh
DATA="${QPKG_ROOT}/data"
mkdir -p "$DATA" "${DATA}/run" "$LOGDIR"
```

That is option C below, and it is a deliberate choice: uninstalling the app throws
away the download session state, which is acceptable because it is user state, not
expensive derived data.

For zot the calculus is different but not absolute. Pull-through with
`onDemand: true` means an **empty** registry still works — the cache rebuilds itself
as pods pull. So losing blobs is recoverable, just slow. On a China-network link where
ghcr.io/docker.io are unreliable, that rebuild is expensive enough that durability is
still worth having.

## Options

### A. Dedicated share — recommended

```
/share/<VOL>/zot/            <- dedicated shared folder, admin-created
    storage/                 <- storage.rootDirectory
    log/zot.log              <- log.output
```

Resolved at runtime, not hardcoded:

```sh
get_share_path "zot" ZOT_SHARE   # works for any share in smb.conf
```

Pros: survives uninstall and upgrade; quota-able (bounds pull-through growth);
snapshot-able; visible in File Station so it is obvious what is consuming space.
Cons: one manual step — the share must exist (created by admin, or reuse an existing
one).

### B. Directory on the volume root — no manual step

```
/share/<VOL>/zot-storage/    <- sibling of .qpkg
```

Derived as `$(dirname "$SYS_QPKG_INSTALL_PATH")/zot-storage`. Survives uninstall
because it is outside `$SYS_QPKG_DIR`.

Pros: no share creation needed; still survives uninstall.
Cons: no quota; invisible in File Station (looks like a stray directory at the
volume root); not covered by share-level snapshots by default.

### C. Under the install path — rejected

`$SYS_QPKG_DIR/data`, created in `pkg_install()` per the QDK cookbook's
"run-time data directory" recipe. Upgrade-safe, but **uninstall deletes it**. Only
acceptable if the store is treated as disposable cache. For a primary registry, no.

## Recommendation

**Option A**, with a fallback chain so install never fails:

1. `get_share_path "zot"` → use it if the share exists
2. else `$(dirname "$SYS_QPKG_INSTALL_PATH")/zot-storage` (option B)
3. log which one was chosen, in the system log and at startup

`pkg_install()` must `mkdir -p` the chosen `storage/` and `log/` **before** the
service starts. zot panics on a missing log directory and nil-derefs on a
non-creatable storage root — both verified, see `zot-binary-notes.md`.

## zot config implications

```json
"storage": {
  "rootDirectory": "<chosen path>/storage",
  "commit": true,
  "dedupe": true,
  "gc": true,
  "gcDelay": "168h",
  "gcInterval": "24h"
},
"log": { "level": "info", "output": "<chosen path>/log/zot.log" }
```

- Keep the whole store on **one** filesystem. Don't split blobs across volumes.
- Registry blobs are content-addressed and write-once, which is friendly to
  snapshots and to a quota that only ever grows slowly.
- `gcDelay: 168h` matches the existing node; deleted tags keep blobs for a week.

## Open questions

- Share name: `zot`? Or reuse an existing share?
- Which volume, and how much space to provision? This is the one number that
  determines whether pull-through is useful — the existing zot holds ~85 repos.
- Should `log/zot.log` be rotated? QTS will not rotate it for us, and zot has no
  built-in rotation. Options: log to stdout and let the service wrapper truncate, or
  a periodic rotation in the init script.
