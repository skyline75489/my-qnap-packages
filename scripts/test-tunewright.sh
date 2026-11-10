#!/usr/bin/env bash
# Verify a built Tunewright .qpkg WITHOUT a NAS.
#
#   scripts/test-tunewright.sh [path/to/pkg.qpkg]
#
# Three phases, mirroring scripts/test-backrest.sh:
#   1. structure  -- decompress the archives inside the .qpkg and check members,
#                    modes, and that the payload is present
#   2. runtime    -- plant the payload in a fake root with stubbed QTS helpers
#                    (/sbin/getcfg, /sbin/write_log) and drive the real service
#                    script through start -> readiness -> the app's own HTTP
#                    surface -> status -> rotate -> stop
#   3. detach     -- run phase 2 twice: once normally, once with a PATH that has
#                    no setsid, to exercise the QTS fallback chain
#
# The assertions that are specific to Tunewright:
#   * the server binary is STATICALLY linked. That is the whole reason it is
#     built against musl: the NAS runs glibc 2.21, and a modern glibc build
#     would not load there.
#   * the SPA is shipped and actually served at "/" — the server and the
#     frontend are one program, so a missing static/ directory is a package
#     that installs but shows nothing.
#   * the music library is the app's DATA dir, and the account database is
#     NOT written into it. The library is the user's own files.
#   * because the app binds a non-loopback address with no admin account yet,
#     it must refuse to hand the account to the first caller and print a
#     one-time setup token instead. The test claims the account with that
#     token and checks the session works.
#   * nothing is downloaded at run time: the payload contains no downloader,
#     and the log must not mention one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QPKG="${1:-}"
if [ -z "$QPKG" ]; then
    QPKG=$(ls -1t "$REPO_ROOT"/packages/tunewright/build/*.qpkg 2>/dev/null | head -1)
fi
[ -f "$QPKG" ] || { echo "no .qpkg found; run scripts/build-qpkg.sh tunewright first" >&2; exit 1; }

# Deliberately NOT $PORT: the environment of a build host often has PORT set
# to something else (a dev server), and inheriting it would point the test
# at a foreign service. 8089 is deliberately not 8081: never fight a live
# instance.
TEST_PORT=${TEST_PORT:-8089}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1 ($3)"; else no "$1: got '$2' want '$3'"; fi; }

echo "== package: $QPKG"
echo "   $(stat -c%s "$QPKG") bytes"

# ---------------------------------------------------------------- phase 1
echo
echo "== 1. structure"
python3 - "$QPKG" "$W/payload" <<'PY'
import sys, zlib, io, tarfile, os
pkg, dest = sys.argv[1], sys.argv[2]
d = open(pkg, 'rb').read()
offs, i = [], 0
while True:
    j = d.find(b'\x1f\x8b\x08', i)
    if j < 0: break
    offs.append(j); i = j + 1
for off in offs:
    try:
        o = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out = o.decompress(d[off:]) + o.flush()
        if not o.eof: continue
        tf = tarfile.open(fileobj=io.BytesIO(out))
        if './tunewright' in tf.getnames():
            os.makedirs(dest, exist_ok=True)
            tf.extractall(dest, filter='tar')
            for m in sorted(tf.getmembers(), key=lambda x: x.name):
                if not m.isdir() and not m.name.startswith('./static/'):
                    print(f"   {m.name:24s} {m.size:>10d}  {oct(m.mode)}")
            print(f"   ./static/                 {sum(1 for m in tf.getmembers() if m.name.startswith('./static/') and not m.isdir())} files")
            sys.exit(0)
    except Exception:
        continue
sys.exit("could not locate the data archive inside the package")
PY
[ $? -eq 0 ] || { no "extract data archive"; exit 1; }

R="$W/payload"
[ -x "$R/tunewright" ] && ok "tunewright binary is executable" || no "tunewright binary not executable"
# The service script is shipped 0644 and made executable by pkg_post_install on
# the NAS (qbuild does not carry the exec bit), so only presence is asserted
# here — the chmod lives in package_routines.
[ -f "$R/tunewright.sh" ] && ok "service script present" || no "service script missing"
[ -f "$R/tunewright.conf" ] && ok "tunewright.conf present" || no "tunewright.conf missing"
[ -f "$R/LICENSE" ] && ok "upstream LICENSE present" || no "upstream LICENSE missing"
[ -f "$R/SOURCE.txt" ] && ok "SOURCE.txt present" || no "SOURCE.txt missing"
grep -q '^version:' "$R/SOURCE.txt" 2>/dev/null && ok "SOURCE.txt states a version" || no "SOURCE.txt has no version"
for g in .qpkg_icon.gif .qpkg_icon_80.gif .qpkg_icon_gray.gif; do
    if [ -f "$R/$g" ]; then ok "icon $g"; else no "icon $g missing"; fi
done

# The SPA is part of the payload: without it the app serves 404 at "/".
[ -f "$R/static/index.html" ] && ok "frontend index.html shipped" || no "frontend index.html missing"
n_static=$(find "$R/static" -type f 2>/dev/null | wc -l)
[ "$n_static" -gt 20 ] && ok "frontend assets shipped ($n_static files)" || no "frontend assets missing ($n_static files)"

# The whole point of the musl build: this must be static, or the NAS
# (glibc 2.21) cannot load it.
if command -v file >/dev/null 2>&1; then
    chk "tunewright is statically linked" "$(file -b "$R/tunewright" | grep -c 'statically linked')" "1"
fi
# ...and it must not carry a dynamic loader at all.
if command -v readelf >/dev/null 2>&1; then
    chk "no dynamic interpreter" "$(readelf -l "$R/tunewright" 2>/dev/null | grep -c 'interpreter')" "0"
fi

# Nothing in the payload may download anything at run time.
found_dl=""
for f in curl wget aria2c fetch nc python python3 perl busybox; do
    [ -e "$R/$f" ] && found_dl="$found_dl $f"
done
[ -z "$found_dl" ] && ok "no downloader in the payload" || no "payload contains:$found_dl"

# ---------------------------------------------------------------- phase 2/3
run_phase(){ # $1=label  $2=PATH to use
    local label=$1 path=$2
    local root="$W/root.$label"
    local bin="$W/bin.$label"
    local music="$W/music.$label"
    rm -rf "$root" "$music"; mkdir -p "$root/data" "$bin" "$music"
    cp "$R"/tunewright "$R"/tunewright.sh "$R"/tunewright.conf "$root/"
    cp -a "$R/static" "$root/static"

    # A music library with one file in it, so the file listing has something
    # to list.
    printf 'not really an mp3\n' > "$music/track.mp3"

    # Point the app at the fake library. Everything else in the shipped
    # config is left as it is, so the shipped defaults are exercised too.
    sed -i "s#^MUSIC_DIR=.*#MUSIC_DIR=\"$music\"#" "$root/tunewright.conf"
    sed -i "s#^PORT=.*#PORT=\"$TEST_PORT\"#" "$root/tunewright.conf"

    cat > "$bin/getcfg" <<EOF
#!/bin/sh
case "\$2" in
  Install_Path) echo "$root" ;;
  Enable)       echo "TRUE" ;;
  Web_Port)     echo "$TEST_PORT" ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "$bin/write_log"
    chmod +x "$bin/getcfg" "$bin/write_log"

    sed -e "s#/sbin/getcfg#$bin/getcfg#g" -e "s#/sbin/write_log#$bin/write_log#g" \
        "$root/tunewright.sh" > "$bin/svc.sh"
    chmod +x "$bin/svc.sh"

    echo
    echo "== 2. runtime ($label)"
    PATH="$path" "$bin/svc.sh" start >"$bin/start.out" 2>&1
    chk "start exit" "$?" "0"
    grep -q 'detach method' "$bin/start.out" && ok "reports detach method: $(sed -n 's/.*detach method: //p' "$bin/start.out" | tail -1)" \
        || no "no detach method logged"
    # The socket wait must actually find the port. A mismatched variable name
    # here silently degrades into a 15 second stall on every start.
    grep -q "listening on port $TEST_PORT" "$bin/start.out" \
        && ok "waited for the listen socket" \
        || no "did not report the listen socket on port $TEST_PORT"

    # The app's own HTTP surface.
    chk "GET /api/v1/health" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/v1/health")" "200"
    chk "health payload" "$(curl -s -m 5 "http://127.0.0.1:$TEST_PORT/api/v1/health" | grep -c '"status":"ok"')" "1"
    # The SPA is served by the same binary.
    chk "GET / (SPA)" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/")" "200"
    chk "GET / is HTML" "$(curl -s -m 5 "http://127.0.0.1:$TEST_PORT/" | grep -ci '<html')" "1"
    chk "GET /_app/version.json" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/_app/version.json")" "200"

    local pid; pid=$(cat "$root/data/tunewright.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ok "pid alive ($pid)"; else no "pid not alive"; fi

    # The music library is the app's data dir; the account database is not.
    if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
        local env; env=$(tr '\0' '\n' < "/proc/$pid/environ")
        chk "TUNEWRIGHT_DATA_DIR is the music library" \
            "$(echo "$env" | sed -n 's/^TUNEWRIGHT_DATA_DIR=//p')" "$music"
        chk "TUNEWRIGHT_STATE_DIR is inside the package" \
            "$(echo "$env" | sed -n 's/^TUNEWRIGHT_STATE_DIR=//p' | cut -c1-${#root})" "$root"
        chk "TUNEWRIGHT_STATIC_DIR is inside the package" \
            "$(echo "$env" | sed -n 's/^TUNEWRIGHT_STATIC_DIR=//p' | cut -c1-${#root})" "$root"
        local tmpdir; tmpdir=$(echo "$env" | sed -n 's/^TMPDIR=//p')
        chk "TMPDIR is set" "$([ -n "$tmpdir" ] && echo set || echo unset)" "set"
        # Compare against the system temp dir by value: the fake root lives
        # under /tmp here, so a path-prefix test would be meaningless.
        chk "TMPDIR is not the system temp dir" \
            "$([ "$tmpdir" != "/tmp" ] && [ "$tmpdir" != "${TMPDIR:-}" ] && echo yes || echo no)" "yes"
    else
        no "could not read /proc/$pid/environ"
    fi

    # The account database must not land in the user's music library.
    [ -f "$music/users.json" ] && no "account database written into the music library" \
        || ok "no account database in the music library"
    [ -d "$root/data/state" ] && ok "state dir created in the package" || no "state dir missing"

    # The app binds a non-loopback address and no admin exists yet, so it
    # must not hand the account to the first caller: it prints a one-time
    # setup token instead.
    local tok
    tok=$(sed -n 's/.*Setup token: \([0-9a-f]\{32\}\).*/\1/p' "$root/data/log/tunewright.log" 2>/dev/null | head -1)
    [ -n "$tok" ] && ok "one-time setup token generated" || no "no setup token in the log"

    # Claiming the account without the token must fail...
    chk "setup without the token is refused" \
        "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            -d '{"username":"admin","password":"Tunewright-Test-Pw-1"}' \
            "http://127.0.0.1:$TEST_PORT/api/v1/auth/setup")" "403"

    # ...and with it must succeed and hand out a session.
    local jar="$bin/cookies"
    chk "setup with the token succeeds" \
        "$(curl -s -m 10 -o /dev/null -w '%{http_code}' -c "$jar" -X POST -H 'Content-Type: application/json' \
            -d "{\"username\":\"admin\",\"password\":\"Tunewright-Test-Pw-1\",\"setup_token\":\"$tok\"}" \
            "http://127.0.0.1:$TEST_PORT/api/v1/auth/setup")" "200"

    # The session must actually work: an authenticated file listing of the
    # music library proves the app can see the configured directory.
    chk "GET /api/v1/files is authenticated" \
        "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/v1/files")" "401"
    chk "GET /api/v1/files with a session" \
        "$(curl -s -m 5 -b "$jar" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/v1/files")" "200"
    chk "the library file is listed" \
        "$(curl -s -m 5 -b "$jar" "http://127.0.0.1:$TEST_PORT/api/v1/files" | grep -c 'track.mp3')" "1"

    # Nothing may be downloaded at run time.
    if grep -qi 'downloading\|downloaded' "$root/data/log/tunewright.log" 2>/dev/null; then
        no "the app tried to download something"
    else
        ok "no download attempted"
    fi

    PATH="$path" "$bin/svc.sh" status >/dev/null 2>&1 && ok "status reports running" || no "status says not running"

    # rotate: pad past the 10 MB ceiling, expect a rotation; then expect no second one
    head -c 11000000 /dev/zero | tr '\0' 'x' >> "$root/data/log/tunewright.log"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    chk "rotate emptied live log" "$(stat -c%s "$root/data/log/tunewright.log")" "0"
    [ -s "$root/data/log/tunewright.log.1" ] && ok "rotate kept previous log as .1" || no "no .1 after rotate"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    [ -f "$root/data/log/tunewright.log.2" ] && no "rotate fired below the ceiling" || ok "rotate is size-gated"

    PATH="$path" "$bin/svc.sh" stop >/dev/null 2>&1
    sleep 1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then no "still alive after stop"; else ok "stopped cleanly"; fi
    [ -f "$root/data/tunewright.pid" ] && no "pid file left behind" || ok "pid file removed"
    local after; after=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/" 2>/dev/null)
    # curl prints 000 and exits non-zero on a closed port; don't append another
    [ -n "$after" ] || after=000
    chk "port released" "$after" "000"
}

# ------------------------------------------------- edge cases: music library
# The server canonicalises its data directory and panics if it does not
# exist, so the service script has to deal with a missing library: create it
# (and say so) rather than let the app die on startup. And a path that cannot
# be created must fail loudly instead of starting against nothing.
edge_cases(){
    local root="$W/root.edge"
    local bin="$W/bin.edge"
    rm -rf "$root"; mkdir -p "$root/data" "$bin"
    cp "$R"/tunewright "$R"/tunewright.sh "$R"/tunewright.conf "$root/"
    cp -a "$R/static" "$root/static"

    cat > "$bin/getcfg" <<EOF
#!/bin/sh
case "\$2" in
  Install_Path) echo "$root" ;;
  Enable)       echo "TRUE" ;;
  Web_Port)     echo "$TEST_PORT" ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "$bin/write_log"
    chmod +x "$bin/getcfg" "$bin/write_log"
    sed -e "s#/sbin/getcfg#$bin/getcfg#g" -e "s#/sbin/write_log#$bin/write_log#g" \
        "$root/tunewright.sh" > "$bin/svc.sh"
    chmod +x "$bin/svc.sh"

    echo
    echo "== 2. runtime (edge cases)"

    # A missing library is created, with a warning.
    local missing="$W/missing-library"
    rm -rf "$missing"
    sed -i "s#^MUSIC_DIR=.*#MUSIC_DIR=\"$missing\"#" "$root/tunewright.conf"
    sed -i "s#^PORT=.*#PORT=\"$TEST_PORT\"#" "$root/tunewright.conf"
    "$bin/svc.sh" start >"$bin/start.out" 2>&1
    chk "start with a missing library" "$?" "0"
    [ -d "$missing" ] && ok "the missing music directory was created" || no "music directory not created"
    grep -q 'created the music directory' "$bin/start.out" \
        && ok "the creation was logged" || no "no warning about the created directory"
    chk "GET /api/v1/health" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/v1/health")" "200"
    "$bin/svc.sh" stop >/dev/null 2>&1

    # A library that cannot exist is a hard failure, not a silent empty app.
    sed -i "s#^MUSIC_DIR=.*#MUSIC_DIR=\"/proc/tunewright-nope/music\"#" "$root/tunewright.conf"
    "$bin/svc.sh" start >"$bin/start2.out" 2>&1
    chk "start with an unusable library fails" "$([ $? -ne 0 ] && echo nonzero || echo zero)" "nonzero"
    grep -q 'music directory does not exist' "$bin/start2.out" \
        && ok "the failure names the music directory" || no "no clear error about the music directory"
    [ -f "$root/data/tunewright.pid" ] && no "pid file left behind after a failed start" \
        || ok "no pid file after a failed start"
}

# normal environment (setsid usually present)
run_phase setsid "$PATH"

# Thin PATH with no setsid on it. This is the regression test for the real bug:
# the script must still find setsid by absolute path. The trap-hup branch is only
# reachable on a host that genuinely lacks setsid, so it cannot be forced here.
np="$W/nopath"; mkdir -p "$np"
for b in sh cat sleep grep kill tail mv wc mkdir sync rm ls sed tr cut awk netstat curl head stat find; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$np/$b"
done
run_phase thin-path "$np"

edge_cases

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
