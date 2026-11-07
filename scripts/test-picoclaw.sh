#!/usr/bin/env bash
# Verify a built PicoClaw .qpkg WITHOUT a NAS.
#
#   scripts/test-picoclaw.sh [path/to/pkg.qpkg]
#
# Four phases, mirroring scripts/test-backrest.sh:
#   1. structure  -- decompress the archives inside the .qpkg and check members,
#                    modes, and that both payloads are present
#   2. runtime    -- plant the payload in a fake root with stubbed QTS helpers
#                    (/sbin/getcfg, /sbin/write_log) and drive the real service
#                    script through start -> readiness -> HTTP -> status ->
#                    rotate -> stop
#   3. no-network -- start again with every proxy variable pointed at a closed
#                    port. The web console must still answer: this package
#                    must not need the internet to serve its UI, and an
#                    unattended download is an unreviewed binary.
#   4. detach     -- run phase 2 twice: once normally, once with a PATH that has
#                    no setsid, to exercise the QTS fallback chain
#
# The interesting assertions here are specific to PicoClaw:
#   * the launcher is given the SHIPPED config and fills it in locally, rather
#     than downloading one;
#   * the API is not open — /api/health answers 401 before a dashboard
#     password is set;
#   * the per-install channel token is generated locally, not shipped.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QPKG="${1:-}"
if [ -z "$QPKG" ]; then
    QPKG=$(ls -1t "$REPO_ROOT"/packages/picoclaw/build/*.qpkg 2>/dev/null | head -1)
fi
[ -f "$QPKG" ] || { echo "no .qpkg found; run scripts/build-qpkg.sh picoclaw first" >&2; exit 1; }

# Deliberately NOT $PORT: the environment of a build host often has PORT set
# to something else (a dev server), and inheriting it would point the test
# at a foreign service. 18899 is deliberately not 18800: never fight a live
# instance.
TEST_PORT=${TEST_PORT:-18899}
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
        if './picoclaw' in tf.getnames():
            os.makedirs(dest, exist_ok=True)
            tf.extractall(dest, filter='tar')
            for m in sorted(tf.getmembers(), key=lambda x: x.name):
                if not m.isdir():
                    print(f"   {m.name:28s} {m.size:>10d}  {oct(m.mode)}")
            sys.exit(0)
    except Exception:
        continue
sys.exit("could not locate the data archive inside the package")
PY
[ $? -eq 0 ] || { no "extract data archive"; exit 1; }

R="$W/payload"
[ -x "$R/picoclaw" ] && ok "picoclaw CLI is executable" || no "picoclaw CLI not executable"
[ -x "$R/picoclaw-launcher" ] && ok "picoclaw-launcher is executable" || no "picoclaw-launcher not executable"
chk "picoclaw self-reports" "$("$R/picoclaw" version 2>/dev/null | grep -c 'picoclaw 0\.3\.1')" "1"
# Go's flag package prints --help to stderr and exits 0, so the stream matters.
chk "picoclaw-launcher responds" "$("$R/picoclaw-launcher" --help 2>&1 | grep -c 'Web console and gateway manager')" "1"
[ -f "$R/picoclaw.sh" ] && ok "service script present" || no "service script missing"
[ -f "$R/home/config.json" ] && ok "config.json seed present" || no "config.json seed missing"
[ -f "$R/home/.security.yml" ] && ok ".security.yml seed present" || no ".security.yml seed missing"
[ -f "$R/LICENSE" ] && ok "LICENSE present" || no "LICENSE missing"
[ -f "$R/SOURCE.txt" ] && ok "SOURCE.txt present" || no "SOURCE.txt missing"
for g in .qpkg_icon.gif .qpkg_icon_80.gif .qpkg_icon_gray.gif; do
    if [ -f "$R/$g" ]; then ok "icon $g"; else no "icon $g missing"; fi
done

# The whole point of the glibc constraint: these must be static, or the NAS
# (glibc 2.21) cannot load them.
if command -v file >/dev/null 2>&1; then
    chk "picoclaw is statically linked" "$(file -b "$R/picoclaw" | grep -c 'statically linked')" "1"
    chk "picoclaw-launcher is statically linked" "$(file -b "$R/picoclaw-launcher" | grep -c 'statically linked')" "1"
fi

# The shipped seeds must not contain a secret: the channel token is generated
# per install, so a shipped one would be the same on every NAS.
chk "shipped .security.yml has no token" "$(grep -c 'token:' "$R/home/.security.yml")" "0"

# ---------------------------------------------------------------- phase 2/3
run_phase(){ # $1=label  $2=PATH to use  [$3=extra env assignments]
    local label=$1 path=$2 extra=${3:-}
    local root="$W/root.$label"
    local bin="$W/bin.$label"
    rm -rf "$root"; mkdir -p "$root/data" "$root/home" "$bin"
    cp "$R"/picoclaw "$R"/picoclaw-launcher "$R"/picoclaw.sh "$root/"
    cp "$R"/home/config.json "$R"/home/.security.yml "$root/home/"

    cat > "$bin/getcfg" <<EOF
#!/bin/sh
case "\$2" in
  Install_Path) echo "$root" ;;
  Enable)       echo "TRUE" ;;
  Web_Port)     echo "$TEST_PORT" ;;
  Listen_Host)  echo "" ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "$bin/write_log"
    chmod +x "$bin/getcfg" "$bin/write_log"

    sed -e "s#/sbin/getcfg#$bin/getcfg#g" -e "s#/sbin/write_log#$bin/write_log#g" \
        "$root/picoclaw.sh" > "$bin/svc.sh"
    chmod +x "$bin/svc.sh"

    echo
    echo "== 2. runtime ($label)"
    env PATH="$path" $extra "$bin/svc.sh" start >"$bin/start.out" 2>&1
    chk "start exit" "$?" "0"
    grep -q 'detach method' "$bin/start.out" && ok "reports detach method: $(sed -n 's/.*detach method: //p' "$bin/start.out" | tail -1)" \
        || no "no detach method logged"
    # The socket wait must actually find the port. A mismatched variable name
    # here silently degrades into a 15 second stall on every start.
    grep -q "listening on port $TEST_PORT" "$bin/start.out" \
        && ok "waited for the listen socket" \
        || no "did not report the listen socket on port $TEST_PORT"

    # The web console answers at / and sends you to the login page; the API
    # refuses to answer anything without a dashboard password.
    chk "GET /"                "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/")" "302"
    chk "GET /launcher-login"  "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/launcher-login")" "200"
    chk "GET /api/health (unauthenticated)" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/health")" "401"

    local pid; pid=$(cat "$root/data/picoclaw.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ok "pid alive ($pid)"; else no "pid not alive"; fi

    # The launcher must be told where its state is, and it must be told about
    # the config this package ships. Assert on the running process's
    # environment, not on the script's text.
    if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
        local envval
        envval(){ tr '\0' '\n' < "/proc/$pid/environ" | sed -n "s/^$1=//p"; }
        chk "PICOCLAW_HOME is the package home" "$(envval PICOCLAW_HOME)" "$root/home"
        chk "PICOCLAW_CONFIG is the shipped config" "$(envval PICOCLAW_CONFIG)" "$root/home/config.json"
        chk "PICOCLAW_BINARY is the shipped CLI" "$(envval PICOCLAW_BINARY)" "$root/picoclaw"
        chk "HOME is inside the package" "$(envval HOME)" "$root/home"
        local tmpdir; tmpdir=$(envval TMPDIR)
        chk "TMPDIR is set" "$([ -n "$tmpdir" ] && echo set || echo unset)" "set"
        # Compare against the system temp dir by value: the fake root lives
        # under /tmp here, so a path-prefix test would be meaningless.
        chk "TMPDIR is not the system temp dir" \
            "$([ "$tmpdir" != "/tmp" ] && [ "$tmpdir" != "${TMPDIR:-}" ] && echo yes || echo no)" "yes"
        chk "TMPDIR is inside the package" "$(case "$tmpdir" in "$root"/*) echo yes ;; *) echo no ;; esac)" "yes"
    else
        no "could not read /proc/$pid/environ"
    fi

    # The launcher must fill in the shipped config locally. A config that
    # still holds only the seed would mean it downloaded one instead.
    if python3 -c "
import json,sys
c=json.load(open('$root/home/config.json'))
sys.exit(0 if c.get('version')==3 and len(c.get('model_list') or [])>0 else 1)
" 2>/dev/null; then
        ok "config.json was filled in locally (model_list present)"
    else
        no "config.json was not filled in"
    fi

    # The channel token is generated per install. The seed ships without one.
    chk "a per-install channel token was generated" "$(grep -c 'token:' "$root/home/.security.yml")" "1"

    # Nothing may be downloaded at runtime. Everything the launcher created
    # must be accounted for, and the log must not mention a download.
    local unexpected
    unexpected=$(ls -A "$root" | grep -v -x -e picoclaw -e picoclaw-launcher -e picoclaw.sh -e home -e data | tr '\n' ' ')
    [ -z "$unexpected" ] && ok "no unexpected files in the package root" \
        || no "unexpected files in the package root: $unexpected"
    if grep -qi 'downloading\|download failed' "$root/data/log/console.log" 2>/dev/null; then
        no "the launcher attempted a download"
    else
        ok "no download attempted"
    fi

    PATH="$path" "$bin/svc.sh" status >/dev/null 2>&1 && ok "status reports running" || no "status says not running"

    # rotate: pad past the 10 MB ceiling, expect a rotation; then expect no second one
    head -c 11000000 /dev/zero | tr '\0' 'x' >> "$root/data/log/picoclaw.log"
    mkdir -p "$root/home/logs"
    head -c 11000000 /dev/zero | tr '\0' 'x' >> "$root/home/logs/launcher.log"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    chk "rotate emptied the service log" "$(stat -c%s "$root/data/log/picoclaw.log")" "0"
    [ -s "$root/data/log/picoclaw.log.1" ] && ok "rotate kept the service log as .1" || no "no .1 after rotate"
    chk "rotate emptied the launcher log" "$(stat -c%s "$root/home/logs/launcher.log")" "0"
    [ -s "$root/home/logs/launcher.log.1" ] && ok "rotate kept the launcher log as .1" || no "no launcher .1 after rotate"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    [ -f "$root/data/log/picoclaw.log.2" ] && no "rotate fired below the ceiling" || ok "rotate is size-gated"

    PATH="$path" "$bin/svc.sh" stop >/dev/null 2>&1
    sleep 1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then no "still alive after stop"; else ok "stopped cleanly"; fi
    [ -f "$root/data/picoclaw.pid" ] && no "pid file left behind" || ok "pid file removed"
    local after; after=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/" 2>/dev/null)
    # curl prints 000 and exits non-zero on a closed port; don't append another
    [ -n "$after" ] || after=000
    chk "port released" "$after" "000"
}

# normal environment (setsid usually present)
run_phase setsid "$PATH"

# ---------------------------------------------------------------- phase 3
# No network. Every proxy variable points at a closed port, so any outbound
# fetch fails immediately and visibly. The console must still come up.
echo
echo "== 3. no-network (all proxies black-holed)"
run_phase nonet "$PATH" "HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 no_proxy="

# ---------------------------------------------------------------- phase 4
# Thin PATH with no setsid on it. This is the regression test for the real bug:
# the script must still find setsid by absolute path. The trap-hup branch is only
# reachable on a host that genuinely lacks setsid, so it cannot be forced here.
np="$W/nopath"; mkdir -p "$np"
for b in sh cat sleep grep kill tail mv wc mkdir sync rm ls sed tr cut awk netstat curl python3 head; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$np/$b"
done
run_phase thin-path "$np"

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
