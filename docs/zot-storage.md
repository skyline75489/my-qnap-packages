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

### C. Under the install path — **chosen**

`$SYS_QPKG_DIR/data`, created in `pkg_install()` per the QDK cookbook's
"run-time data directory" recipe. Upgrade-safe, and uninstall deletes it — which is
the accepted trade-off here (see "Decision" below).

## Decision: `${QPKG_ROOT}/data`

Chosen. Rationale: blobs without the registry are meaningless, and `onDemand: true`
pull-through means a reinstalled zot repopulates itself as pods pull. So paying for
durability that outlives the package buys nothing.

```
/share/<VOL>/.qpkg/Zot/
    zot                 binary (215 MB)
    config.json         shipped, QPKG_CONFIG-protected
    zot.sh              service script
    data/               created in pkg_install(), NOT shipped in the package
        storage/        storage.rootDirectory
        log/zot.log     log.output
```

### Why this is upgrade-safe

`data/` is created imperatively in `pkg_install()`, never shipped:

```sh
pkg_install(){
    $CMD_MKDIR -p "$SYS_QPKG_DIR/data/storage" "$SYS_QPKG_DIR/data/log"
}
```

QDK only tracks files **shipped inside the package** for obsolete-file cleanup on
upgrade, so a directory it never saw is never touched. Upgrades preserve blobs;
uninstall removes them. That is exactly the intended split for this decision.

### Relative paths make the config volume-agnostic

Verified: zot resolves a relative `storage.rootDirectory` / `log.output` against the
**process working directory**, not against the config file's directory. Test with the
config in `etc/` and storage relative to cwd wrote `<cwd>/data/storage/cache.db` and
`<cwd>/data/log/zot.log`, leaving `etc/data/` untouched.

So the service script does:

```sh
cd "$QPKG_ROOT" || exit 1
exec ./zot serve config.json
```

and `config.json` contains:

```json
"storage": { "rootDirectory": "data/storage" },
"log": { "level": "info", "output": "data/log/zot.log" }
```

Consequences, all good:
- One config.json works on **any** volume — no install-time path substitution, no
  placeholders, no generated-at-install file.
- Volume migration (`QPKG_VOLUME_SELECT=2/3`) needs no config rewrite, because the
  whole `.qpkg/<NAME>` tree moves and the relative paths still resolve.
- The config can ship as a plain file in the package and get normal `QPKG_CONFIG`
  `.qdkorig`/`.qdksave` protection on upgrade.

The one hazard: relative paths are only correct if cwd is `$QPKG_ROOT`. The `cd`
must not be omitted, or zot writes its store wherever the script happened to be.

### Consequences to plan for

1. **The install volume is now the storage volume.** Not for durability — the data is
   discardable — but for **capacity while it exists**. Measured on the existing backup
   zot: **25 GB for 85 repos**, of which 3.1 GB is the `_trivy` CVE database and 1.4 GB
   the `metabase` index. Discardable is not the same as small: that much data still has
   to fit somewhere for as long as the registry runs, and pull-through keeps growing it.
   So `QPKG_VOLUME_SELECT` decides which volume absorbs the growth. Planned:
   `QPKG_VOLUME_SELECT="3"` (select on both install and migration) so it lands on a
   volume with room rather than defaulting silently.
   If the default volume is known to have room, `0` is a perfectly fine answer — but it
   should be a decision, not an accident. A full volume on QTS is not a registry-only
   problem: writes fail across the board (logs, config, other apps on that volume).
2. **No per-share quota.** `.qpkg` is not a share, so nothing bounds pull-through
   growth except the volume itself. Rely on zot's `gc`/`gcDelay` and QTS volume
   alerts; do not rely on a quota.
3. **Uninstall will be slow if the store is large.** The generated uninstaller does
   `rsync -a --delete /tmp/qpkg_blankdir "$SYS_QPKG_DIR"` then `rm -fr`, so it walks
   the whole tree. With tens of GB expect App Center to sit on the removal for a
   while; `QPKG_TIMEOUT` does **not** govern uninstall.
4. **The service script must implement `remove`.** The uninstaller calls
   `$SYS_INIT_DIR/$QPKG_SERVICE_PROGRAM stop` and then `... remove`. `start`/`stop`/
   `restart` alone are not enough.


## zot config implications

Paths are relative to `$QPKG_ROOT` (the service script `cd`s there first):

```json
"storage": {
  "rootDirectory": "data/storage",
  "commit": true,
  "dedupe": true,
  "gc": true,
  "gcDelay": "168h",
  "gcInterval": "24h"
},
"log": { "level": "info", "output": "data/log/zot.log" }
```

- Keep the whole store on **one** filesystem. Don't split blobs across volumes.
- Registry blobs are content-addressed and write-once, which is friendly to a store
  that mostly only grows.
- `gcDelay: 168h` matches the existing node; deleted tags keep blobs for a week.
- **`commit: true` is fsync, nothing to do with dedupe.** Verified in
  `pkg/storage/local/driver.go`: `fileWriter.Close()` calls `file.Sync()` only when
  the driver's `commit` flag is set. So it forces a flush of each blob to disk before
  close — durability against unclean shutdown / power loss, at the cost of write
  throughput on large layers. On a NAS, where an unclean shutdown is plausible, keep
  it `true`: a truncated blob under a correct content address is a much worse failure
  than a slower push.

## Open questions

- Which volume, and how much space? Baseline measured on the existing backup zot:
  **25 GB / 85 repos**. Whether the default volume can absorb that plus growth decides
  `QPKG_VOLUME_SELECT`.
- Should `search.cve` be enabled? It is 3.1 GB of the 25 GB (`_trivy` DB) and is a
  second upstream download path to keep working. The fedora config already sets
  `"cve": { "updateInterval": "0" }`; doing the same here likely drops to ~22 GB.
- Should `data/log/zot.log` be rotated? QTS will not rotate it for us and zot has no
  built-in rotation. Options: log to stdout and let the service wrapper truncate, or
  rotate in the init script.
- Log level: `info` vs `warn` — `info` is useful during bring-up, `warn` after.
