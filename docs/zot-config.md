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

If pull-through is wanted later, add the `sync` block then — and only then does the
CA bundle need verifying.

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

### What "truncate at start" actually does

`start)` does `: > data/log/zot.log` — the file is emptied every time the service
starts, so it only ever holds the current run.

Two problems for this service in particular:

1. **It bounds nothing if the service never restarts.** A registry is meant to run for
   months. At 27 MB/day, "one run's worth" is gigabytes. Truncate-at-start is only a
   real bound for short-lived processes.
2. **It destroys the evidence you want.** The log is truncated *as part of starting*,
   so after a crash-restart the post-mortem log is already gone.

### Plan instead

1. Remove the noise at the source: no `cve` block, and `"level": "warn"` in steady
   state. That eliminates ~78% (`info` request logs) plus the CVE error loop, leaving
   almost nothing in normal operation.
2. Rotate on start rather than truncate: if the log is non-trivial, move it to
   `zot.log.1` (replacing the previous `.1`) and start a fresh file. Bounded at two
   files, and the previous run's log survives one restart — which is exactly the one
   you want after a crash.

```sh
# in start), before launching zot
[ -s "$LOG" ] && mv -f "$LOG" "$LOG.1"
```

That beats both truncate-at-start (loses evidence) and unbounded append (grows until
the volume notices).

## Holding pattern

If CVE scanning is later wanted, it needs a reachable trivy DB — either the default
`ghcr.io` through the proxy, or `cve.trivy.dbRepository` pointed at a mirror in the
local zot. Not worth doing in v1.
