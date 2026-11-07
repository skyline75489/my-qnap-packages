# PicoClaw

`sipeed/picoclaw` — "Tiny, Fast, and Deployable anywhere", a personal AI
assistant written in Go. Packaged here as a native QPKG: no Container Station, no
downloads at install time or run time.

- Upstream: <https://github.com/sipeed/picoclaw> — MIT
- Packaged version: **0.3.1** (`v0.3.1`, released 2026-07-03)
- Port: **18800**
- Package: [`../packages/picoclaw`](../packages/picoclaw/README.md)

## Upstream facts that shaped the package

Read from the source at `v0.3.1` and from the release artefacts, not from the
README:

| Fact | Consequence |
|---|---|
| The release tarball carries **two** binaries — `picoclaw` (CLI/agent) and `picoclaw-launcher` (web console) | Both are shipped; the launcher finds the CLI next to itself |
| Both are built with `CGO_ENABLED=0` (`.goreleaser.yaml`) | Statically linked — glibc 2.21 is not a constraint |
| The dashboard password is a **SQLite** store (`modernc.org/sqlite`, pure Go, bcrypt cost 12) | No database server, so this is still a QPKG and not a Container Station service |
| State lives in `PICOCLAW_HOME` (default `~/.picoclaw`); the config path is `PICOCLAW_CONFIG`; the CLI path is `PICOCLAW_BINARY` | All three are set explicitly, to absolute paths inside `$QPKG_ROOT` |
| The launcher defaults to **localhost** and to port 18800; `-public` binds every interface | `-public` is passed, or `-host` when `Listen_Host` is set |
| The gateway (`picoclaw gateway`) is a **separate** process on `cfg.Gateway.Port` (default 18790, localhost) | The package runs the launcher only; the launcher starts and stops the gateway from the web console |
| The config is versioned (`CurrentVersion = 3`) with a V0→V1→V2→V3 migration chain | The package ships a minimal `{"version": 3}` seed; the launcher fills it in locally |
| The updater is **only** reachable as `picoclaw update` or through a UI button | Nothing is fetched at startup — see below |

## The no-runtime-download rule

Two things upstream could have downloaded, and neither does:

- **The config.** The launcher writes the full default configuration — 30 models,
  every channel — into the file it was pointed at. The package ships a seed and
  lets it fill that in locally.
- **An update check.** `pkg/updater` exists, but it is reachable only through
  `picoclaw update` (a cobra command) and through the web console's update
  button (`web/backend/api/update.go`, which takes the URL from the request).
  Nothing calls it during startup.

That is measured, not assumed: the test harness starts the package with
`HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy` and `http_proxy` all pointed at a
closed port, and asserts that the console still answers. A package that quietly
fetched something at startup could not come up that way.

The harness also asserts that the shipped `.security.yml` seed contains **no
token** and that a per-install one appears after the first start — a shipped
token would be the same secret on every NAS.

## Ports

| Port | What | Bound to |
|---|---|---|
| 18800 | the web console (`picoclaw-launcher`) | every interface (`-public`), or `Listen_Host` |
| 18790 | the agent gateway (`picoclaw gateway`) | localhost, upstream default |

18800 is upstream's own default and collides with nothing QTS uses — 5000 is the
QTS portal. The gateway port is upstream's business; the launcher proxies to it,
and the package never starts it on its own.

## Paths

Everything the app touches is inside `$QPKG_ROOT`:

| Path | What |
|---|---|
| `$QPKG_ROOT/picoclaw` | the CLI and agent |
| `$QPKG_ROOT/picoclaw-launcher` | the web console, the long-running process |
| `$QPKG_ROOT/home/config.json` | model list, channels, gateway settings — **QPKG_CONFIG** |
| `$QPKG_ROOT/home/.security.yml` | API keys and channel tokens — **QPKG_CONFIG** |
| `$QPKG_ROOT/home/launcher-auth.db` | the dashboard password (SQLite) |
| `$QPKG_ROOT/home/logs/` | the launcher's own logs |
| `$QPKG_ROOT/home/workspace/` | the agent's workspace |
| `$QPKG_ROOT/data/` | this package's logs, pid file and `TMPDIR` |

`HOME` is set to `$QPKG_ROOT/home`, so the agent's `~/.ssh` key and its caches
land on the volume instead of in `/root`.

### Why the config files are seeds, and why they are listed in `QPKG_CONFIG`

`QPKG_CONFIG` is what makes a user's edits survive an upgrade: the QDK compares
the shipped file's md5 sum with the installed one, and a file the user changed is
kept (`.qdkorig`/`.qdksave`). The mechanism is **file-based** — `store_config`
runs `md5sum` on the path — so a directory cannot be listed.

That matters here because upstream keeps the config and the secrets in one
directory with the logs, the password database and the workspace. Splitting them
means the two files the user actually edits are the two files the package ships
and tracks, while the rest stays runtime state.

The seeds are deliberately minimal: `{"version": 3}` and `channel_list: {}`. The
launcher fills them in at first start — verified: the config grows to the full
default with a 30-model list, and a channel token is generated per install.

## Authentication

The web console has a **dashboard password**, stored as a bcrypt hash in
`launcher-auth.db`. Until it is set:

- `/` redirects to `/launcher-login` (302 → 200);
- `/api/*` answers **401** — the API is not open;
- `/launcher-setup` is reachable, and that is how the password is created.

The service script logs a warning on every start while no password is set,
because the console is reachable from the LAN. Set one from the UI at
`http://<nas>:18800/launcher-setup`.

This is upstream's design, not a package decision, but the package makes it
visible: a QPKG normally has no authentication story at all.

## The updater is not the package's business

`picoclaw update` downloads a release asset and **replaces the binary in place**.
On a QPKG install that would break the guarantee this repo cares about — the
binary in the package is the one whose checksum was verified at fetch time and
whose licence travelled with it — and the next package upgrade would overwrite it
anyway. Upgrade the package instead.

## Version pinning

`scripts/fetch-picoclaw.sh` pins `PICOCLAW_VERSION` (default `v0.3.1`) and
verifies the tarball against the checksums file the project publishes with every
release (`picoclaw_<version>_checksums.txt`).

The seed `config.json` says `"version": 3`, which is `CurrentVersion` in v0.3.1's
`pkg/config/config.go`. A newer upstream release with a higher config version
would need the seed checked against it: the launcher migrates a config whose
version is *lower* than it expects, but a seed claiming a version the binary does
not know is not a thing to guess at.

## What is not covered

- **Nothing has been run on a real NAS.** The package builds and the harness
  passes; that is the whole of the evidence.
- The **agent** is not exercised: no model is configured, no API key is set, and
  the `picoclaw gateway` process is never started. The harness covers the web
  console, the service lifecycle and the config wiring.
- The dashboard password flow is not exercised either — only that the API
  refuses to answer without one.
- `arm_64` is not packaged, although upstream builds it and QTS supports it.
- Upstream is early: its own README says not to deploy to production before
  v1.0, and warns that recent builds use 10–20 MB of RAM.
