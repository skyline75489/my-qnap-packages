# zot config for the QPKG (v1)

Scope decision: **pull-through is not a priority** for the NAS registry. v1 is a plain
registry that stores what gets pushed to it. That removes a whole class of problems.

## v1 extensions

| Extension | v1 | Why |
|---|---|---|
| `storage` | yes | the point |
| `search` | yes | required by `ui` |
| `ui` | yes | required to wire `QPKG_WEBUI` / `QPKG_WEB_PORT` |
| `metrics` | yes | cheap, useful for `/metrics` |
| `sync` | **no** | no pull-through in v1 |
| `search.cve` | **no** | see below — it is actively harmful here |

### Why no `sync` in v1

Without pull-through the NAS needs no access to docker.io / ghcr.io / quay.io at all.
Everything arrives by LAN copy from the fedora zot (`skopeo copy`, see
`k3s-image-management/references/zot-mirror-to-zot.md`). Consequences:

- No upstream TLS → the open question about stale CA roots on 2015-era firmware
  becomes **irrelevant**.
- No `HTTP(S)_PROXY` env in the service script.
- No "first pull is slow / sync timeout" failure modes.
- Storage growth is predictable: only what we push.

**This is a deliberate decision, not an unfinished feature.** Images are synced from
elsewhere; zot on the NAS is a cold backup whose only job is to start early and
behave predictably. The bootstrap layer of the image stack should be the least clever
component in it.

#### Rejected: pull-through, so Container Station could pull locally

Considered and declined. Making the NAS zot a local registry for Container Station
apps would mean enabling `extensions.sync` with `onDemand: true`, which:

- reintroduces upstream TLS (and therefore the CA-bundle question on 2015-era
  firmware) and proxy configuration;
- brings back the sync-timeout failure modes, where a manifest read blocks until the
  upstream gives up;
- couples Container Station app pulls to a daemon that must also serve as the
  cluster's DR copy — two roles with different failure tolerances.

Container Station apps should pull from the primary at `192.168.1.3:5000` over the
LAN instead. That keeps the NAS package simple and leaves the cold copy genuinely
cold.

Add the `sync` block only if the fedora host stops being reachable and the NAS must
serve Container Station on its own — and treat that as a design change, not a tweak.


### Why no `cve` block — verified trap

Setting the interval to zero does **not** disable CVE scanning. In
`pkg/cli/server/root.go`:

```go
if *config.Extensions.Search.Enable && config.Extensions.Search.CVE != nil {
    defaultUpdateInterval, _ := time.ParseDuration("2h")
    if config.Extensions.Search.CVE.UpdateInterval < defaultUpdateInterval {
        config.Extensions.Search.CVE.UpdateInterval = defaultUpdateInterval   // 0 -> 2h
        logger.Warn().Msg("cve update interval set to too-short interval < 2h, ...")
    }
    if config.Extensions.Search.CVE.Trivy == nil {
        config.Extensions.Search.CVE.Trivy = &extconf.TrivyConfig{}            // auto-created
    }
    if config.Extensions.Search.CVE.Trivy.DBRepository == "" {
        defaultDBDownloadURL := "ghcr.io/aquasecurity/trivy-db"                // needs ghcr.io
        ...
    }
}
```

So **the mere presence of a `cve` block** forces a 2-hour scan interval, auto-creates
the Trivy config, and defaults the DB source to `ghcr.io/aquasecurity/trivy-db`.

This is not theoretical. The fedora zot has `"cve": { "updateInterval": "0" }` and,
since the config was edited on 2026-10-25 03:04, it has kept emitting cve lines at
**~8/hour**, all failures:

```
failed to scan image ... unable to initialize a scan service
failed to perform scheduled cve scan for image
```

Because `ghcr.io` is not reachable from that host, every scan fails, twice an hour,
forever. And it allocated the 3.1 GB `_trivy` directory.

**To disable: omit the `cve` block entirely.** Then `Search.CVE == nil`, the
defaulting block above is skipped, and `IsCveScanningEnabled()` returns false
(`e.Search.CVE != nil && e.Search.CVE.Trivy != nil`).

## Logging

Measured on the fedora zot (73 MB, uptime 2.7 days, `level: info`):

| Metric | Value |
|---|---|
| Lines | 171,002 |
| Size | 73 MB |
| Rate | ~27 MB/day ≈ **9.9 GB/year** |
| Levels | `info` 134,276 (78%), `error` 36,497, `warn` 229 |
| Components | anonymous/request logs 134,178; `session` 24,070; `cve` 11,047; `dedupe` 1,262 |

Most of it is per-request `info` logging plus the CVE failure loop.

### Rotate-at-start does not bound size either

Same flaw as truncate-at-start, and one I originally talked myself into: a rotation
tied to `start)` only fires when the service restarts. On a NAS the service runs for
months, so "one run's worth" is unbounded in exactly the same way. Rotating at start
preserves the previous run's log across a restart — which is useful for post-crash
forensics — but it is **not a size control**.

If the log must be bounded, the bound has to run on a timer **while the service runs**.

### Plan instead

1. **Cut the volume at the source: `"level": "warn"`.** That is the actual control.
   At `info` the bulk of output is per-request logging (78% of 171k lines measured);
   `warn` removes it. Note `error` is *not* the better choice — see below.
2. **Add a size ceiling on a timer.** QTS has cron, and QPKGs do use it; `DownloadCenter`
   is the precedent:

   ```sh
   CRONTAB="/etc/config/crontab"
   cron_add(){
       grep -qF "$QPKG_ROOT/zot.sh rotate" "$CRONTAB" 2>/dev/null && return 0
       echo "0 4 * * * /bin/sh $QPKG_ROOT/zot.sh rotate >/dev/null 2>&1" >> "$CRONTAB"
       crontab "$CRONTAB"
       /etc/init.d/crond.sh restart >/dev/null 2>&1
   }
   ```

   with `rotate` doing a size check rather than an unconditional move:

   ```sh
   rotate)
       [ -f "$LOG" ] || exit 0
       SIZE=$(wc -c < "$LOG")
       [ "$SIZE" -gt 10485760 ] || exit 0      # 10 MB ceiling
       mv -f "$LOG.1" "$LOG.2" 2>/dev/null || true
       mv -f "$LOG" "$LOG.1"
       : > "$LOG"
       ;;
   ```

   Bounded at three files ≤ ~20 MB total, and it only fires if something actually
   misbehaves. `cron_remove` (delete the line, `crontab $CRONTAB`, restart crond) goes
   in `PKG_PRE_REMOVE`.
3. **Keep `mv zot.log zot.log.1` in `start)`** as a secondary — not as the size bound,
   but so the previous run survives one restart. Cheap and it is the log you want
   after a crash.

### Why `warn` rather than `error`

Check what the levels actually contain on this workload, once `cve` and `sync` are out:

| Level | Fedora (with cve + sync) | NAS v1 (no cve, no sync) |
|---|---|---|
| `info` | 134,276 (78%) — per-request | still per-request, still large |
| `warn` | 229 | a handful |
| `error` | 36,497 — 29,588 sync + 5,852 sync + 222 scan | **≈ 0** |

The 36k errors were almost entirely sync and CVE failures, neither of which exists on
the NAS. So `warn` and `error` are both effectively silent there — and `error` would
additionally throw away warnings that matter, e.g.:

```
[warn] metadb: storage parse incomplete; skipping fast-restart stamp so the next
       restart reparses
```

That is exactly the kind of message you want after an unclean shutdown. `error` buys
nothing over `warn` on this workload and loses diagnostics, so: **`warn`**.

Cost of `warn`: no startup version banner (`info`). Get it from `zot --version`, or
raise to `info` temporarily by editing the config and restarting.


## Holding pattern

If CVE scanning is later wanted, it needs a reachable trivy DB — either the default
`ghcr.io` through the proxy, or `cve.trivy.dbRepository` pointed at a mirror in the
local zot. Not worth doing in v1.
