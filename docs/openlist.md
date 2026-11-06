# OpenList on the NAS — decisions and quirks

Everything here was measured against upstream v4.2.9 and the package built from it,
not read off the documentation.

## Why this package exists

OpenList (fork of AList) is a file-list / storage gateway: it mounts cloud and
local backends and serves them over a web UI, WebDAV, S3 and FTP. It ships as a
single Go binary with the frontend embedded, which makes it a natural fit for the
"native binary, no Container Station" rule this repo follows.

## The payload

| | |
|---|---|
| Asset | `openlist-linux-musl-amd64.tar.gz` (v4.2.9) |
| Size | 53 MB tarball → 155 MB binary |
| Linkage | **statically linked** (upstream builds musl with `-extldflags '-static -fpic'` and asserts it in CI) |
| Alternative | `openlist-linux-amd64.tar.gz` — dynamically linked, needs only `libc.so.6` |

The static musl build is used because it removes the glibc question entirely: the
NAS pins glibc 2.21, and a static binary cannot care about it. The `-lite` build
(115 MB binary) drops some storage drivers; the full build was chosen.

Upstream publishes **md5 only** (`md5-linux-musl.txt`), so `scripts/fetch-openlist.sh`
verifies the tarball against that and additionally against a sha256 of the extracted
binary that we pinned ourselves
(`7b6d5f9f9f3d29fab3c4ffb77fd155f397f3e07d228d66b68274ad0b7379f5f0`).

## Paths are relative to the working directory

OpenList's config carries `data/data.db`, `data/temp` and `data/log/log.log`.
They are resolved against the **current working directory**, not against the data
directory. The service script therefore does `cd "$QPKG_ROOT"` before exec, exactly
like the zot script does, and passes `--data data` (relative).

This is what makes the package survive a volume migration: the config file moves
with the volume and still points at the new location.

Corollary: do **not** pass an absolute `--data` path. The default config is built
from the raw `--data` value, so an absolute path would be baked into
`config.json` and would point at the old volume after a migration.

## No shipped config.json

OpenList creates `data/config.json` on first start, with a random `jwt_secret`.
The package deliberately ships none: a shipped config would carry a known JWT
secret into every install, and anyone with the package could mint valid tokens.

Upstream writes that file with mode `0o777`. The service script resets it to 0600
after startup, and the whole `data/` tree is created with `umask 077`.

## The port is pinned through the environment

OpenList reads config values from the environment with the prefix `OPENLIST_`.
The exact names are the `env:` tags of the config struct, so for a nested struct
without an `envPrefix` the *inner* tag is used:

| Variable | Effect |
|---|---|
| `OPENLIST_HTTP_PORT` | listen port (verified: this is the one that works) |
| `OPENLIST_ADDR` | bind address |
| `OPENLIST_ADMIN_PASSWORD` | creates the `admin` account on first start |
| `OPENLIST_DB_FILE` | sqlite path |
| `OPENLIST_TEMP_DIR` | temp directory |

Note `OPENLIST_SCHEME_HTTP_PORT` does **not** work — the `scheme` struct has no
`envPrefix`, so the inner tag `HTTP_PORT` is used as-is. `OPENLIST_PORT` does not
work either.

The service script sets `OPENLIST_HTTP_PORT` from `QPKG_WEB_PORT` (5244) and
`OPENLIST_ADDR=0.0.0.0`, so the port QTS proxies to and the port OpenList binds
cannot drift apart. `OPENLIST_HTTP_PORT` wins over `config.json` at runtime; the
file keeps the value it was written with, which is only a cosmetic inconsistency.

`--no-prefix` is deliberately **not** passed: it would clear the prefix and make
plain environment variables (`PORT`, `HTTP_PORT`, …) override the config.

## No admin account on first start

`internal/bootstrap/data/user.go` only creates the admin when `flags.Dev` is set or
`OPENLIST_ADMIN_PASSWORD` is present; otherwise the web setup wizard
(`POST /api/public/init/setup`) does it. A first start with neither leaves a
working UI with no way in except the wizard.

`$SYS_QPKG_DIR/openlist.env` is the escape hatch. A commented template is shipped in
`shared/`, so it is already there after the install:

```sh
OPENLIST_ADMIN_PASSWORD=<password>
```

The service script syntax-checks it (`sh -n`) before sourcing it — a syntax error
in a sourced file kills the shell — and sources it with `set -a` so the variables
are exported to the daemon.

## Ports

| Port | What |
|---|---|
| 5244 | OpenList HTTP (upstream default, kept) |
| 5221 | FTP — off by default |
| 5222 | SFTP — off by default |
| 5246 | S3 — off by default |

Only 5244 is enabled. 5000 is the QTS portal, hence not used.

## Logging

| File | Written by | Rotation |
|---|---|---|
| `data/log/log.log` | OpenList | OpenList itself (50 MB × 30 backups) |
| `data/log/console.log` | this package (stdout capture) | daily cron `rotate`, 10 MB ceiling, 2 kept |

`console.log` also holds the one-time line
`Successfully created the admin user and the initial password is: …`; the service
script copies it to the QTS system log.

## Uninstall

Everything under `$SYS_QPKG_DIR` is deleted on uninstall, `data/` included. That
means the admin account, the JWT secret and the storage definitions are gone and
have to be recreated. The database is a cache of sorts, but the storage
definitions are not.

## Licensing

- The software is **AGPL-3.0**.
- The logo (`OpenListTeam/Logo`) is **CC BY-NC-SA 4.0** — *non-commercial*. Fine for
  a personal NAS, not for redistribution in a commercial context. The icons in
  `packages/openlist/icons/` are derived from it.
