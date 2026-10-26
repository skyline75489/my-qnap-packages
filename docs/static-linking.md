# Static linking for QPKG binaries

Question: can we ship upstream's prebuilt `zot-linux-amd64` inside a QPKG, or must we
build it ourselves? The concern is `-buildmode=pie`, which leaves an `INTERP` segment
in the binary.

## TL;DR

- Upstream zot binaries are **static-PIE**: no library dependencies, but they *do*
  require `/lib64/ld-linux-x86-64.so.2` to exist at runtime.
- QTS is glibc-based, so that loader is present and the upstream binary will almost
  certainly run unmodified. "Almost certainly" is the problem — it is an unverified
  assumption about the appliance image.
- Building from source with `BUILDMODE_FLAGS=` removes the loader dependency
  entirely and produces a true static `ET_EXEC`. It is cheap to do (see below).
- The QNAP ecosystem convention is fully static: both real Go QPKGs I found build
  with `CGO_ENABLED=0` and **no** `-buildmode=pie`.

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
`/lib64/ld-linux-x86-64.so.2`. No libc, no other libraries. If that path exists on
QTS, the upstream binary runs.

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

Ship **upstream's prebuilt binary first** (zero build infrastructure, 63.5 MB
gzipped) and treat "does the loader exist on QTS" as a one-line verification on the
NAS:

```sh
ls -l /lib64/ld-linux-x86-64.so.2
```

If it's there, done. If not — or if we want the package to be provably
self-contained — build from source with `BUILDMODE_FLAGS=` to get `ET_EXEC`, which
also lets us drop unneeded extensions and shrink the payload.

A middle option if we want certainty without maintaining a Go build: ship the
prebuilt binary and additionally include the loader from a known-good Debian image
in the package. Not recommended — it duplicates a system file and version-couples us
to the NAS. Mentioned only for completeness.
