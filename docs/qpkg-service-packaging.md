# Packaging a third-party service as a QPKG

How to decide whether a program belongs in this repo, and — if it does — how to get it
onto a QTS 5.2.9 NAS that runs **glibc 2.21** with no Container Station and no runtime
downloads.

The two packages in this repo are the easy case: each ships an upstream **release
binary** that already runs on glibc 2.21. Most candidates are not. This doc covers the
hard case: a service that has to be **built from source** and drags **native libraries**
and **external tools** with it.

---

## 1. Decide first: QPKG or container?

A QPKG is the right answer only when all three hold:

1. The service must run **without Container Station** (it is a cold/backup path, or the
   whole point is that the NAS has no container runtime).
2. The service can be made to run on **glibc 2.21** without heroic effort.
3. Its **state is either disposable or a single directory** that the QPKG can own.

If (2) is false, stop. Building a service against a libc the NAS does not have is a
multi-hour trap, and a container image is a strictly better artifact: the image pins
the whole userspace, the NAS already knows how to run it, and upgrades are a digest
change.

Container wins when: the service needs a database server, a message broker, or a
multi-process runtime; when it pulls many distro packages; or when a supported image
already exists. A QPKG wins when the service is **one process plus one directory**.

**A container needs no port gymnastics from us, but it does need real volumes.** Put
the app's database and its media/thumbnail cache on an actual QNAP volume, never on the
container layer — losing the cache means a full re-scan on restart.

**If you ship a container, pin the digest, not the tag.** Tags move.

---

## 2. Audit the upstream project before designing anything

The failure mode is discovering the dependency list after the package is half built.
Spend the first hour reading the upstream repo instead. Work through this list:

| Question | How to answer it | Why it matters |
|---|---|---|
| Is there a prebuilt release binary? | Check the releases API for assets | No assets ⇒ you own the build |
| Does it ship a VM runtime (.NET, JVM)? | measure the GLIBC floor of **every** ELF in the tarball, not just the main binary | see §2.4 — the runtime is often fine and one bundled `.so` is not |
| Does it use CGO? | `go.mod` for `cgo`/`*.c` deps; `CGO_ENABLED=1` in their Dockerfile | CGO ⇒ you own the libc and the shared libs |
| Does it shell out to other programs? | `grep -rn "exec.LookPath\|exec.Command" api/` | Each one is a runtime dependency you must ship |
| **Does it execute commands on someone else's instruction?** | see §2.3 | If yes, the package runs as root by default — decide before you build |
| Does it need a database server? | config/env docs | A server ⇒ container |
| Does it ship a web UI? | separate `ui/` dir, `npm run build` | UI = build step + payload weight |
| What licence? | `LICENSE` | AGPL/GPL affect redistribution of the QPKG |
| Is there a build tag to disable a heavy feature? | `grep -rn "^//go:build" --include=*.go` | The cheapest way to shrink the dependency surface |

### 2.1 Classify every dependency: fatal vs optional

This classification decides whether the service **boots**. Read the startup path, not
just the dependency list.

- **Fatal at startup** — the init path calls `log.Panicf`/`os.Exit` when the
  dependency is missing. The service will not run without it, so it must be shipped.
- **Optional** — the init path logs an error and continues (`log.Error`). The service
  runs with the feature degraded.

The grep that finds them:

```sh
grep -rn "LookPath\|exec.Command" api/ --include=*.go
grep -rn "Panicf\|log.Fatal\|os.Exit" api/ --include=*.go
```

Read both together. A single `LookPath` for a tool that upstream treats as optional
is not optional if its init error is fatal one frame away.

### 2.2 Native libraries: check for a fallback before you accept the dependency

A native library is a problem only if the code path is unavoidable. Look for a
pure-Go fallback in the same package. If the only implementation of, say, thumbnail
generation is a C binding to a big imaging library, that library is mandatory and the
package is now a *packaging exercise for that library*, not for the service.

### 2.3 Does it execute commands on someone else's instruction?

QTS runs a package's service script as **root**. That is a fact about the target,
and it is usually harmless: a registry or a backup server does not act on
instructions from a stranger.

It stops being harmless when the app executes commands that are not the user's
direct request — an LLM agent, a plugin host, a script runner, a webhook
receiver. Then "the service runs as root" becomes "someone else's text becomes
root code execution", and the input is whatever the model read: a web page, a
document, a chat message.

Ask two questions, and do not skip the first:

1. **Which capability is the dangerous one?** An agent that reads and writes
   files and an agent that runs a shell are different risks, and upstream often
   separates them: the file tools are confined to a workspace or a path allow
   list, while the command tool is not. Read the config defaults — a `null`
   allow list usually means *the sandbox's own default still applies*, not
   *unrestricted*. Getting this backwards in either direction is easy.
2. **Is there a boundary, or only a filter?** A deny list of dangerous
   commands (`rm -rf`, `sudo`, `dd if=`) is a filter. It is worth having and it
   is not a boundary: it matches literal strings, and the next one down
   (`find … -delete`, `unlink`, a bare `>` redirect) is not on the list.

The options, in the order they are worth taking:

- **Turn the dangerous capability off in the shipped config.** If the app has a
  config switch for it, ship it off and let the user turn it on deliberately.
- **Make the safe capability explicit.** A path allow list in the config is a
  statement of what the app may touch, and it survives an upgrade. An implicit
  default is not a decision.
- **Use the app's own sandbox if it has one**, and check what it needs on the
  host — a bubblewrap-based sandbox wants user namespaces or setuid, which a
  NAS may not have.
- **Drop privileges as defence in depth**, not as the fix. QTS runs the *script*
  as root; the script can `su` to an unprivileged account. That limits the
  blast radius, and it is worth doing — but on its own it makes the app
  useless rather than safe, because the uid then owns nothing. If the app's
  usefulness depends on file access, the uid needs access to *those* paths,
  granted the way the NAS grants access to anything else.

This is a packaging decision, not only a runtime one: sometimes the honest
answer is to package the service and not ship it, and to write down why. The
PicoClaw package is in this repo, unpublished, for exactly this reason — see
`docs/picoclaw.md`.

### 2.4 .NET (and other VM runtimes) are not automatically excluded

A common assumption is that "a .NET app" is a QPKG no-go. **It is not.** A .NET app
that ships as a self-contained release tarball is just a directory of ELF files, and
the only question that matters is the same one as for any other payload: does every
one of those files link against a glibc the NAS has?

Measured on [Lidarr](https://github.com/Lidarr/Lidarr) release tarballs
(`linux-core-x64`, the glibc build — not `linux-musl`):

| Release | Runtime | Highest `GLIBC_*` in the whole tarball | Loads on glibc 2.21? |
|---|---|---|---|
| v3.1.6.5079 | .NET 8 (`net8.0`, runtime 8.0.27) | **2.34** | no — but fixable, see below |
| v2.14.5.4836 | .NET 6 (`net6.0`, runtime 6.0.35) | **2.16** | yes |
| v1.2.6.3313 | .NET 6 (`net6.0`) | **2.16** | yes |

The interesting part is *where* the 2.34 came from. The .NET runtime itself was
fine in every build:

```
$ objdump -T libcoreclr.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -2
GLIBC_2.14
GLIBC_2.16
```

The offender was a single bundled native library — `libe_sqlite3.so`, compiled by
the upstream vendor on a modern distro, pulling in `pthread_create@GLIBC_2.34`,
`dlopen@GLIBC_2.34` and `dlerror@GLIBC_2.34`. So the failure is not ".NET is too
new"; it is "one vendor-compiled `.so` is too new".

**That one library is usually swappable — and that changes the answer.** A bundled
SQLite is a *plain amalgamation*: it exports the standard `sqlite3_*` C API and
nothing else. Check before assuming the payload is unfixable:

```sh
objdump -T libe_sqlite3.so | awk '$3=="DF"||$3=="DO"{print $NF}' \
  | grep -vE '^sqlite3_' | head
# empty output => it is a stock SQLite amalgamation => rebuildable from source
```

Rebuilding it against the target libc is a small, contained job — the SQLite
amalgamation is one `.c` file, and `manylinux2014` is already the build image
(§3.1):

```sh
gcc -O2 -fPIC -shared -Wl,-soname,libe_sqlite3.so -o libe_sqlite3.so sqlite3.c \
    -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_COLUMN_METADATA \
    -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE \
    -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_MATH_FUNCTIONS \
    -DSQLITE_ENABLE_DESERIALIZE -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_SNAPSHOT \
    -lpthread -ldl -lm
```

Measured on Lidarr v3's `libe_sqlite3.so` (SQLite 3.53.4):

| | bundled | rebuilt |
|---|---|---|
| Highest `GLIBC_*` | **2.34** | **2.14** |
| `sqlite3_*` exports | 300 | 296 |

The four absent exports are `sqlite3_key`, `sqlite3_key_v2`, `sqlite3_rekey` and
`sqlite3_rekey_v2` — the SQLite Encryption Extension (SEE) API, which is a
**paid** feature and unused by an app that does not encrypt its database. The
rebuilt library was loaded and queried (`SELECT` returns the right row) to confirm
it is a working drop-in.

**Match the upstream compile flags.** The `-D` list above was derived by diffing
the exported symbol sets; a plain `gcc sqlite3.c` build is missing 28 symbols
(`sqlite3_preupdate_hook`, `sqlite3_column_database_name`, …) and will fail to
resolve them at runtime. Diff the two symbol sets before shipping a rebuild:

```sh
objdump -T libe_sqlite3.so | awk '$3=="DF"||$3=="DO"{print $NF}' \
  | grep -E '^sqlite3_' | sort -u > bundled.txt
# ... rebuild, then:
comm -23 bundled.txt rebuilt.txt      # symbols the app will fail to resolve
```

So the practical order of attack for a .NET payload is:

1. Measure the whole tarball (§3). Identify the single library that breaks it.
2. If it is a stock SQLite amalgamation, rebuild it against glibc ≤ 2.17 and
   ship that instead of walking back the upstream release.
3. Only walk back the release series if the offender is something that cannot
   be rebuilt (a proprietary codec, a vendor blob).

The `linux-musl` variants are **not** a shortcut around this. They replace the
glibc dependency with a musl one (`libc.musl-x86_64.so.1`), which a glibc QTS
does not have; making one work means shipping the musl loader and re-pointing
the ELF interpreter. That is a real project, not a repack.

#### The host libraries a .NET app still needs

A self-contained .NET tarball carries the runtime but not the C libraries the
runtime `dlopen`s at startup. Audit them by probing the strings, not by reading
the docs:

```sh
# ICU (globalization). Versioned sonames are probed, so an old ICU may be rejected.
strings libSystem.Globalization.Native.so | grep -E 'libicuuc|libicui18n|so\.%'

# OpenSSL (TLS) — the probe list shows which sonames are accepted.
strings libSystem.Security.Cryptography.Native.OpenSsl.so | grep '^libssl\.so'

# SQLite, when the app P/Invokes the system library rather than bundling one.
strings System.Data.SQLite.dll | grep -x 'sqlite3'
```

On Lidarr v2 that audit yields: host ICU, host OpenSSL, and **host
`libsqlite3.so`** — confirmed by running it and reading `/proc/<pid>/maps`, where
the loaded library was the system's `/usr/lib64/libsqlite3.so.0`. So even a
version whose glibc floor is fine still has to be matched against what QTS
actually provides — check the NAS, do not assume.

If ICU is missing or too old for the runtime to accept, the runtime has an
escape hatch (`System.Globalization.Invariant`, present in
`System.Private.CoreLib.dll`) that disables culture-sensitive behaviour. It
changes sorting and string comparison, so treat it as a degraded mode to be
tested against the app, not a free fix.

#### The two rules that bite .NET apps hardest on QTS

- **Disable the self-updater.** Lidarr (like the whole *arr family) downloads a
  new release of itself at runtime unless told otherwise. That is exactly the
  "no runtime downloads" rule in `AGENTS.md` — an unattended binary fetch. Pin
  the update mechanism to *external* in the shipped config.
- **Check the licence.** Lidarr is **GPL-3.0**. Redistributing a GPL-3.0 binary
  inside a QPKG carries the corresponding-source obligation on top of the
  `LICENSE` + `SOURCE.txt` rule in `AGENTS.md`. That obligation is a packaging
  decision to make before writing the fetch script, not after.

---

## 3. Satisfy the glibc constraint

The NAS runs **glibc 2.21**. QTS pins it deliberately, so it will not be raised.

- A binary built against a newer libc **will not run** — it fails at load time with
  `GLIBC_2.2x not found`, before `main` runs.
- The safe target is **glibc ≤ 2.21**. Building against **2.17** (CentOS 7 /
  `manylinux2014`) gives margin and is the conventional choice.
- Verify by **measuring**, not by trusting the build image:

```sh
objdump -T ./binary | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3
# every version listed must be <= 2.21
```

- **Measure every ELF in the payload, not just the entry point.** A bundled
  library can carry a higher floor than the main executable — that is exactly
  what happens with a .NET app that ships one vendor-compiled native library
  (see §2.4). One command over the whole tree:

```sh
find . -type f -exec objdump -T {} \; 2>/dev/null \
  | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3
# any version > 2.21 means the payload will not load
```

(`objdump` fails quietly on non-ELF files, so there is no need to test the magic
bytes first.)

A **fully static** binary sidesteps libc entirely, but only if it has no CGO. With
CGO you are in the "build against an older libc" business, and `docs/static-linking.md`
records how the existing static payload was verified.

### 3.1 The `manylinux2014` build environment

`quay.io/pypa/manylinux2014_x86_64` is a CentOS 7 image with **glibc 2.17** and a
compiler — a good default sysroot for anything that must run on QTS. It also carries
Go-friendly tooling and `sqlite3` in `/usr/local`.

CentOS 7 is EOL: `vault.centos.org` returns **403** from this network. Use a mirror
instead, and rewrite the repo files wholesale rather than editing them — CentOS 7 repo
files use `$basearch`/`$releasever`, so `sed` patterns on the literal URL do not match:

```sh
rm -f /etc/yum.repos.d/*.repo
cat > /etc/yum.repos.d/centos7.repo <<'EOF'
[base]
name=centos7-base
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/x86_64/
gpgcheck=0
enabled=1
[updates]
name=centos7-updates
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/x86_64/
gpgcheck=0
enabled=1
[epel7]
name=epel7
baseurl=https://mirrors.aliyun.com/epel-archive/7/x86_64/
gpgcheck=0
enabled=1
EOF
yum -y --exclude='*.i686' install <packages>
```

Two traps, both hit:

- **`--exclude='*.i686'`** — the i686 dependency chain pulls `glibc.i686`, which
  conflicts with the newer `glibc-common` already installed and aborts the transaction.
- **`updates` must point at the `updates/` tree**, not at `os/`, or yum resolves
  `glibc-common` to a version older than the installed one and fails the same way.

EPEL 7 is an **archive** (`epel-archive/7`) and holds packages that the base repo
dropped; it is the only source for some of them.

### 3.2 Toolchain and module proxies

- Go: the `go.dev` download endpoint is unreachable here; the tarball is available from
  the same mirror family (`mirrors.aliyun.com/golang/`). Pick a version that satisfies
  the upstream `go` directive in `go.mod`.
- Go modules: `proxy.golang.org` times out; **`GOPROXY=https://goproxy.cn,direct`**
  works.
- Node: `nodejs.org` is reachable, so the **UI build can happen on the host** rather
  than in the old-glibc container. Node ≥ 18 needs glibc 2.28 and will *not* run inside
  `manylinux2014` — build UI assets outside the container, build the Go binary inside.

### 3.3 Registry reachability

Verified from this build host at the time of writing:

| Endpoint | Reachable | Use |
|---|---|---|
| `quay.io` | yes | base images (`manylinux2014`) |
| `github.com` | yes | upstream source, releases API |
| `nodejs.org` | yes | Node tarball for UI builds |
| `mirrors.aliyun.com` | yes | CentOS/EPEL archives, Go tarballs |
| `goproxy.cn` | yes | Go modules |
| `registry-1.docker.io` | **no** (connection reset) | — |
| `proxy.golang.org` | **no** (timeout) | — |
| `go.dev` | **no** (TLS EOF) | — |
| `mirror.gcr.io` | **no** (timeout) | — |

**Check reachability before designing the build around an endpoint.** A build that
assumes `docker.io` will fail on the first pull, and the failure looks like a network
outage rather than a design error. Images already present locally are worth checking
too — a cached upstream image can serve as a source of UI assets and as a reference
for what the upstream runtime actually needs.

---

## 4. Shrink the dependency surface

Before shipping a heavy dependency, look for an upstream **build tag** that removes it.
Feature-gated code is usually behind `//go:build !no_<feature>` with a shim
implementation under `//go:build no_<feature>`. Building with `-tags no_<feature>`
drops the native dependency *and* the code that uses it.

This is the single highest-leverage step in the whole exercise: one tag can remove a
native library, its build dependencies, its runtime models, and a runtime download.

There is often a matching **environment variable** to disable the same feature at
runtime. Using the build tag is stronger — the code is not compiled in at all — but
both can be set so the behaviour is explicit rather than incidental.

---

## 5. Packaging the runtime

A QPKG ships files; it does not install system packages. So everything the binary
needs at runtime has to travel inside the package:

- **Shared libraries.** Either link them statically (hard for big C libraries) or
  ship the `.so` files in the package and point `LD_LIBRARY_PATH` at them from the
  service script. Ship exactly what `ldd` reports, no more.
- **Interpreted tools.** A tool written in Perl/Python needs its interpreter on the
  NAS too. Either ship the interpreter and its module tree (size!), or find a static
  build of the tool, or pick a different tool.
- **Static third-party binaries.** Prefer upstream static builds of big CLI tools
  (codecs, probes) over building them: they carry their own libc and sidestep the
  2.21 problem entirely. Verify their minimum glibc the same way (`objdump -T`).
- **Frontend assets.** Build the UI and ship the `dist/` directory; set the app's
  "serve UI" option and point it at that path.

The service script must export the environment the app needs — `PATH` (so the app
finds its helper tools), `LD_LIBRARY_PATH` (so it finds its shared libraries), and the
app's own configuration variables. See `packages/zot/shared/zot.sh` for the shape.

---

## 6. Configuration, ports and state

- **Ports**: 5000 is the QTS portal. Pick the next free port and record it in
  `qpkg.cfg` (`QPKG_SERVICE_PORT`).
- **Config file**: `QPKG_CONFIG` entries get the `.qdkorig`/`.qdksave` upgrade-safe
  treatment (see `docs/qpkg-spec.md`). Services that read a `.env` file, or a
  `godotenv`-style file, want that file listed here, with a shipped default that the
  install hook only creates when absent.
- **State**: decide what is disposable. Everything under `$QPKG_ROOT/data` dies on
  uninstall (`rsync --delete` + `rm -rf`) — fine for a cache, fatal for a database.
  Ship the state **outside** `$QPKG_ROOT` if it must survive an uninstall.
- **Databases**: an embedded database (SQLite) is a file, so it is easy; a server
  database is not, and points back at "use a container".

---

## 7. Build-host gotchas

- **Podman bind mounts**: a mounted script may come back `Permission denied`; pipe it
  in over stdin (`podman run -i ... bash -s < script.sh`) instead of mounting it.
- **`qbuild` is not reproducible** — see the note at the end of `AGENTS.md`.
- **Never trust the build's success output**; see the verification standard in
  `AGENTS.md`.

---

## 8. Checklist for a new package

1. Decided QPKG vs container (§1) and recorded the reason.
2. Audited the upstream project (§2); every dependency classified fatal / optional /
   feature-gated.
3. Feature-gated heavy dependencies removed via build tags (§4).
4. Built in a glibc ≤ 2.17 environment; `objdump -T` confirms every `GLIBC_*` symbol
   is ≤ 2.21 (§3).
5. If the payload is a VM runtime (.NET, JVM), the whole tarball measured, not just
   the entry point, and the host libraries it `dlopen`s (ICU, OpenSSL, libsqlite3)
   confirmed present on the NAS (§2.4).
6. Runtime surface inventoried with `ldd` and `PATH`; everything it needs ships
   inside the package (§5).
7. Port chosen away from 5000; config file registered for upgrade-safe handling;
   state placement decided (§6).
8. Payload fetched or built **by a script** that verifies checksums, and the payload
   gitignored.
9. `scripts/build-qpkg.sh` + a `scripts/test-*.sh` harness that drives the real
   service script, per the verification standard in `AGENTS.md`.
10. Licence checked for redistribution implications.
11. Checked whether the app executes commands on someone else's instruction, and
    if it does, the boundary decided and recorded (§2.3) — including the option of
    packaging it and **not** shipping it.
12. Anything not covered by the test harness stated as unverified, not implied.

---

## What this repo does *not* need

A package that would require shipping a database server, a broker, or a multi-process
supervisor belongs in Container Station, not here. Say so plainly rather than
building it. The existing packages exist for a specific reason — the registry must
boot without an image registry — and that reason does not extend to every service.
