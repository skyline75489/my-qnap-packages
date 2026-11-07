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

## Why this package is not published

**It is not published, and it should not be — yet.** The reason is in the
measured behaviour of the app, not in a feeling about it.

QTS runs a package's service script as **root**. PicoClaw's agent is an LLM
that can run shell commands. Put those two facts together and the service is
root code execution driven by model output.

### What the agent can actually do, as shipped

Measured at v0.3.1, from the source and from the config the launcher writes at
first start:

| Capability | Default | Where |
|---|---|---|
| **File tools** (read, edit, append, list) — confined to the agent's **workspace**, which is `PICOCLAW_HOME/workspace` | `agents.defaults.restrict_to_workspace: true`, `allow_read_outside_workspace: false`; the fs tools root themselves with `os.OpenRoot` and refuse anything else with "access denied: path is outside the workspace" | `pkg/tools/fs/filesystem.go`, `pkg/agent/instance.go:113` |
| `tools.allow_read_paths` / `tools.allow_write_paths` — these **widen** the sandbox, they do not define it | `null`, i.e. no extra paths | `pkg/agent/instance.go:115-116` |
| **The exec tool** — `sh -c <command>`, arbitrary shell, as whatever uid the process has | `tools.exec.enabled: true`, `allow_remote: true` | `pkg/tools/shell.go:401` |
| The exec tool's filter — a **deny list** of ~50 regexes (`rm -rf`, `dd if=`, `sudo`, `chmod`, `kill`, `curl|sh`, backticks, `$(...)`…) | `enable_deny_patterns: true` | `pkg/tools/shell.go:52` |
| **Cron** may run commands | `tools.cron.allow_command: true` | the default config |
| The agent fetches web content — the prompt-injection path into all of the above | `tools.web.enabled: true` | the default config |
| Skills may be installed and run | `tools.skills.enabled: true` | the default config |
| There is **no uid check** anywhere in the tools or the agent — no `os.Geteuid`, no "refuse to run as root" | — | `grep -rn Geteuid pkg/tools/ pkg/agent/` finds nothing |

So the file tools are already confined; **the exec tool is the hole**, and it is
a wide one. A deny list is a speed bump, not a boundary: it blocks the literal
string `rm -rf`, not `find … -delete`, `unlink`, `truncate` or `shred`; it
blocks `chmod 777`, not `chmod 7777`; and a bare `>` redirect writes anywhere
the uid can write — which, as root, is everywhere.

Upstream's own mitigation, `pkg/isolation`, wraps child processes in
**bubblewrap** (`bwrap`) with an explicit `expose_paths` allow list — and the
exec tool *does* go through it (`isolation.Start(cmd)` at
`pkg/tools/shell.go:415`). But it is `enabled: false` by default, it does not
sandbox the main process, and it needs `bwrap` present on the host: a binary
this package does not ship, and one that wants user namespaces or setuid on
QTS.

### The distinction that resolves the tension

The first version of this note said the fix was to drop privileges, so that the
agent would "own nothing but the package's own directory". That is the wrong
lever, and it is worth saying why, because the two capabilities are separable:

- **Usefulness comes from file access.** An assistant on a NAS is useful because
  it can read the user's documents, organise the photo library, write a report
  into a folder. That is the **file tools** — and upstream already confines them
  to the workspace and lets you *widen* that confinement explicitly with
  `allow_read_paths` / `allow_write_paths`.
- **Danger comes from command execution.** Arbitrary shell as root is not what
  makes the agent useful; it is what makes it dangerous.

So the two do not have to be traded off. Grant the file tools exactly the
paths you want — the shares you choose, read-only for most — and take away the
shell.

### What would have to change before this is publishable

1. **Ship a hardened default config.** `tools.exec.enabled: false` and
   `tools.cron.allow_command: false`, so the web console works and the agent
   cannot execute anything until the user turns it on. This is a one-line
   change to the seed `config.json`, and it is the single most valuable one.
2. **Make the file allow list explicit**, e.g.
   `allow_read_paths: ["^/share/CACHEDEV1_DATA/Documents/"]`, so "the agent may
   read this folder" is a statement in the config rather than an accident of
   the sandbox's default.
3. **Bundle `bwrap`** and ship `isolation.enabled: true` with an explicit
   `expose_paths` allow list, so even an enabled exec tool runs in a namespace
   that cannot see the rest of the filesystem.
4. **Drop privileges as defence in depth** — the service script would run the
   launcher as an unprivileged uid instead of root. This is worth doing, but on
   its own it is not the fix: it would leave the agent able to run shell as
   that uid, and it would make it *useless* unless the uid is granted access to
   the shares you want it to work with.

None of that is implemented. The package as it stands is plain upstream
behaviour, which is why it stays unpublished.

### The residual risk, stated honestly

Even with all four changes, an LLM that can read your files and fetch the web
is exposed to prompt injection: a document or a web page can contain
instructions the model then acts on. Upstream's mitigations reduce the blast
radius; they do not remove it. Running an agent on a NAS is a decision with a
risk that cannot be engineered away — only bounded.

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

The web console has a **dashboard password**, stored as a bcrypt hash (cost 12) in
a one-row SQLite table in `home/launcher-auth.db`. Until it is set:

- `/` redirects to `/launcher-login` (302 → 200);
- `/api/*` answers **401** — the API is not open;
- `/launcher-setup` is reachable, and that is how the password is created.

### Setting it

Open **`http://<nas>:18800/launcher-setup`** in a browser and fill in the form.
The rules, from the handler (`web/backend/api/auth.go`):

| Rule | Error |
|---|---|
| at least 8 characters | `password must be at least 8 characters` |
| the two fields must match | `passwords do not match` |
| not empty | `password must not be empty` |

Setting it does **not** log you in — you then log in at `/launcher-login`. A
successful login returns a session cookie:

```
Set-Cookie: picoclaw_launcher_auth=...; Path=/; Max-Age=2678400; HttpOnly; SameSite=Lax
```

That is 31 days. Login attempts are rate-limited to **10 per IP per minute**
(`loginAttemptsPerIP`).

### Changing it, and resetting it

To change an existing password you must already be logged in: `POST
/api/auth/setup` refuses with `must be authenticated to change password` once a
password exists. The setup page handles this in the browser.

If the password is lost, the store is the only thing that has to go — it is a
single SQLite file, and the upstream recovery message says it outright ("stop
the application, reset dashboard password storage, and restart"):

```sh
/etc/init.d/picoclaw.sh stop
rm -f "$(/sbin/getcfg PicoClaw Install_Path -f /etc/config/qpkg.conf)/home/launcher-auth.db"
/etc/init.d/picoclaw.sh start
```

The launcher then comes back with an empty password store and the setup page
works again. Nothing else is lost: the config and the API keys are in
`home/config.json` and `home/.security.yml`.

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

- **The package is not published**, for the reason in the section above: it
  would run an LLM agent with shell access, as root, on a NAS.
- **Nothing has been run on a real NAS.** The package builds and the harness
  passes; that is the whole of the evidence.
- The **agent** is not exercised: no model is configured, no API key is set, and
  the `picoclaw gateway` process is never started. The harness covers the web
  console, the service lifecycle and the config wiring.
- The dashboard password flow is **exercised** by the harness — the setup
  validation, the bcrypt hash on disk, and a login — but the password is never
  set *by the package*, and the reset path is not exercised.
- `arm_64` is not packaged, although upstream builds it and QTS supports it.
- Upstream is early: its own README says not to deploy to production before
  v1.0, and warns that recent builds use 10–20 MB of RAM.
