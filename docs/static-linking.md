# Static linking for QPKG binaries

Question: can we ship upstream's prebuilt `zot-linux-amd64` inside a QPKG, or must we
build it ourselves? The concern is `-buildmode=pie`, which leaves an `INTERP` segment
in the binary.

## TL;DR

- Upstream zot binaries are **static-PIE**: no library dependencies, but they *do*
  require `/lib64/ld-linux-x86-64.so.2` to exist at runtime.
- **Tested against the NAS's actual loader, glibc 2.21: it works.** The v2.1.22
  release binary serves, accepts a push, and serves pulls correctly. See
  [Tested against glibc 2.21](#tested-against-glibc-221-the-nas-loader).
- So there is **no need to build from source** for loader reasons. Ship upstream's
  binary.
- The QNAP ecosystem convention is still fully static: both real Go QPKGs I found
  build with `CGO_ENABLED=0` and **no** `-buildmode=pie`. We just don't need to
  follow it here.

### Correction: glibc 2.27 is not the floor for static-PIE

My first read of this was that glibc 2.27's static-PIE work meant the 2.21 loader
couldn't bootstrap a static-PIE binary. **That is wrong.** glibc 2.27 added support
for building *glibc itself* as static-PIE; it did not gate the loader's ability to
run an `ET_DYN` main executable. The loader only has to process
`R_X86_64_RELATIVE` relocations, which `ld.so` has handled for far longer. The
empirical test below is what settled it, not the version history.


## Real-world QPKG examples that ship Go binaries

### 1. `akolts/QnapLCD` — Go daemon controlling the NAS front-panel LCD

Makefile:

```make
GOFLAGS = CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1
LDFLAGS = -s -w
...
$(GOFLAGS) go build -ldflags='$(LDFLAGS) ...' -o $@ ./cmd/qnaplcd
```

Dockerfile — final stage is `FROM scratch`, which is only possible for a static
binary:

```dockerfile
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
    go build -ldflags="-s -w -X main.version=${VERSION}" -o /out/qnaplcd ./cmd/qnaplcd
...
FROM scratch
COPY --from=builder /out/qnaplcd /qnaplcd
```

Two details worth copying:
- `GOAMD64=v1` — pins the baseline x86-64 microarchitecture level, so the binary
  can't accidentally require AVX2/etc. and fault on older NAS CPUs.
- No `-buildmode=pie` flag anywhere.

### 2. `tasict/DownloadCenter` — full QPKG, Go daemon + two C++ engines

Build script compiles Go with:

```sh
(cd daemon && CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOARM="$goarm" \
    $GO build -trimpath -ldflags "-s -w -X main.Version=$VERSION $GA_FLAGS" -o "../$dir/bin/dcd" ./cmd/dcd)
```

Again no `-buildmode=pie`. README, on the C++ side:

> The engines are statically linked with third-party libraries (libtorrent, Boost,
> OpenSSL, curl, nghttp2, libssh2, zlib, JSON for Modern C++, musl and the GCC
> runtime)

musl + static GCC runtime for the native engines, pure-Go static for the daemon.
This is a package that has to run across x86_64 / arm_64 / arm-x41 / arm-x31 from a
single source tree, so it is a good model for what actually survives on QTS.

Note its `qpkg.cfg` also shows the `QDK_DATA_DIR_*` idiom for per-arch payloads:

```sh
QDK_DATA_DIR_X86_64="x86_64"
QDK_DATA_DIR_ARM_64="arm_64"
QDK_DATA_DIR_X41="arm-x41"
QDK_DATA_DIR_X31="arm-x31"
QDK_DATA_DIR_SHARED="shared"
```

## Empirical A/B test

Ran on the Fedora build host. Key property of an ELF: a static-PIE keeps a
`PT_INTERP` segment naming the dynamic loader; a true static executable has none.

```
           type   INTERP  NEEDED
zot        DYN    1       0      <- static-PIE, names /lib64/ld-linux-x86-64.so.2
kubectl    EXEC   0       0      <- true static, self-contained
```

Both have zero library dependencies. The difference is only whether the kernel needs
a loader to bootstrap the process.

Test: run each inside a chroot that contains **only the binary** — no libc, no loader.

```sh
unshare -r chroot /tmp/piechroot /zot --version
# chroot: failed to run command '/zot': No such file or directory

unshare -r chroot /tmp/piechroot /kubectl version --client
# Client Version: v1.36.5+k3s1        <- works
```

That `No such file or directory` for a file that plainly exists is the kernel
reporting "interpreter not found".

Then copy **only** the loader in, and retry the PIE binary:

```sh
mkdir -p piechroot/lib64 && cp /lib64/ld-linux-x86-64.so.2 piechroot/lib64/
unshare -r chroot /tmp/piechroot /zot --version
# {"message":"version","binary-type":"-events-imagetrust-...","commit":"v2.1.18..."}
```

Conclusion: the static-PIE zot needs exactly one thing from the host —
`/lib64/ld-linux-x86-64.so.2`. No libc, no other libraries.

## Tested against glibc 2.21 (the NAS loader)

The NAS reports:

```
lrwxrwxrwx 1 admin administrators 10 2026-10-14 15:26
    ld-linux-x86-64.so.2 -> ld-2.21.so
```

glibc 2.21 is a 2015-era release, so this needed testing, not assuming. Test setup:
pulled the genuine `libc6_2.21-0ubuntu4.3_amd64.deb` (Ubuntu 15.04) and extracted the
real `ld-2.21.so`, rather than approximating with a newer loader.

| Test | Result |
|---|---|
| `ld-2.21.so /zot --version` | prints full version JSON |
| `ld-2.21.so /zot serve <cfg>` | process stays up |
| `GET /v2/` | 200 |
| `GET /metrics` | 200 |
| `GET /` (UI) | 200 |
| `GET /v2/_catalog` | `{"repositories":[]}` |
| **push** image via `skopeo copy` → zot | exit 0, blob + config + manifest written |
| `GET /v2/probe/rt/tags/list` | `{"tags":["1.0"]}` |
| manifest `Docker-Content-Digest` | correct digest returned |
| **pull** back to `oci:` archive | exit 0, valid image |
| storage on disk | 2.4 MB for the probe image |

Also tested the **kernel exec path** (`PT_INTERP=/lib64/ld-linux-x86-64.so.2` resolved
inside a chroot to `ld-2.21.so`), not just invoking the loader manually — `/v2/` and
UI both 200.

Tested binary: `zot-linux-amd64` **v2.1.22** (226 MB, built with `go1.27.1`), i.e. the
exact release artifact we would ship. `Type: DYN`,
`INTERP=/lib64/ld-linux-x86-64.so.2`, `NEEDED` count 0.

**Verdict: the upstream binary runs on this NAS's loader unmodified.**

### What this means for packaging

1. **No from-source build needed.** Ship `zot-linux-amd64` v2.1.22 as-is.
2. **glibc 2.21 dates the firmware.** It indicates QTS 4.x, not 5.x. So
   `QTS_MINI_VERSION` must target QTS 4.x (e.g. `4.3.0`), **not** `5.0.0` as an
   earlier draft had it. Confirm the exact QTS version via App Center.
3. **CA certificates are the remaining unknown.** TLS pull-through uses Go's system
   root store (`/etc/ssl/certs/ca-certificates.crt` and friends). On 2015-era
   firmware the bundle may predate current roots, which would break `sync` against
   ghcr.io/quay.io even though the binary itself runs fine. Verify before relying on
   pull-through on the NAS.

Incidental finding while testing: zot **refuses to start** if `ui` is enabled without
`search` —

```
failed to enable ui, search extension must be enabled
```

`UI_DEPENDENCIES := search,mgmt,userprefs` in the Makefile handles this for the
*default* build, but a hand-written config still has to enable `search`.

## Why upstream builds PIE

`Makefile`:

```make
BUILDMODE_FLAGS := -buildmode=pie
BASE_IMAGE=gcr.io/distroless/base-nossl-debian13:latest-$(ARCH)
ifeq ($(OS),freebsd)
	BUILDMODE_FLAGS=
	BASE_IMAGE=freebsd/freebsd-static:14.3
endif
```

PIE is the default because it is what distroless/Debian users expect. Note the
freebsd branch already empties `BUILDMODE_FLAGS` — so "build without PIE" is a
configuration upstream itself supports, not a hack.

`BUILDMODE_FLAGS` is a plain `:=` assignment, so a command-line override wins:

```sh
make BUILDMODE_FLAGS= binary
```

## Cost of building from source

Cheap. No npm required — the UI ships prebuilt.

```
go.mod:    go 1.27.0
Go here:   not installed; brew has go 1.27.3 (satisfies it)
UI:        https://github.com/project-zot/zui/releases/download/commit-8e8457d/zui.tgz
           -> HTTP 200, 1.1 MB prebuilt tarball
```

The `ui` make target prefers that tarball and only falls back to
`git clone` + `npm install` + `npm run build` when it's missing. So a static build
is: install Go, `make BUILDMODE_FLAGS= EXTENSIONS=... binary`.

Environment quirks to respect when building:
- `export GOEXPERIMENT=jsonv2` (set at the top of the Makefile)
- `CGO_ENABLED=0`
- `-trimpath`
- `GOAMD64=v1` is *not* set by zot — consider adding it, following QnapLCD, so the
  binary doesn't assume a newer x86-64 baseline than the NAS CPU provides.

## Recommendation

**Ship upstream's prebuilt `zot-linux-amd64` v2.1.22.** Zero build infrastructure,
63.5 MB gzipped, and it is verified to run on this NAS's glibc 2.21 loader — serve,
push, pull, UI, metrics all exercised.

Keep the from-source path in your back pocket rather than as the plan. Reason to use
it later: dropping unneeded extensions (`lint`, `imagetrust`, `scrub`, `profile`,
`events`) to shrink the payload, or if we ever need `ET_EXEC` for a different target.
Not needed for this NAS.

Before relying on pull-through, verify CA roots on the NAS (see above). A bare
`curl -I https://ghcr.io` from the NAS shell is enough to tell.

