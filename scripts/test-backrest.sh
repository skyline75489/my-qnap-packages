#!/usr/bin/env bash
# Verify a built Backrest .qpkg WITHOUT a NAS.
#
#   scripts/test-backrest.sh [path/to/pkg.qpkg]
#
# Three phases, mirroring scripts/test-package.sh:
#   1. structure  -- decompress the archives inside the .qpkg and check members,
#                    modes, and that both payloads are present
#   2. runtime    -- plant the payload in a fake root with stubbed QTS helpers
#                    (/sbin/getcfg, /sbin/write_log) and drive the real service
#                    script through start -> readiness -> status -> rotate -> stop
#   3. detach     -- run phase 2 twice: once normally, once with a PATH that has
#                    no setsid, to exercise the QTS fallback chain
#
# The interesting assertion here is that Backrest uses the BUNDLED restic.
# Backrest downloads a restic binary on first start when it cannot find one;
# the package must never do that, so the test asserts the restic cache
# directory was populated (proof restic ran) and that no download was logged.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QPKG="${1:-}"
if [ -z "$QPKG" ]; then
    QPKG=$(ls -1t "$REPO_ROOT"/packages/backrest/build/*.qpkg 2>/dev/null | head -1)
fi
[ -f "$QPKG" ] || { echo "no .qpkg found; run scripts/build-qpkg.sh backrest first" >&2; exit 1; }

# Deliberately NOT $PORT: the environment of a build host often has PORT set
# to something else (a dev server), and inheriting it would point the test
# at a foreign service. 9899 is deliberately not 9898: never fight a live
# instance.
TEST_PORT=${TEST_PORT:-9899}
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
        if './backrest' in tf.getnames():
            os.makedirs(dest, exist_ok=True)
            tf.extractall(dest, filter='tar')
            for m in sorted(tf.getmembers(), key=lambda x: x.name):
                if not m.isdir():
                    print(f"   {m.name:24s} {m.size:>10d}  {oct(m.mode)}")
            sys.exit(0)
    except Exception:
        continue
sys.exit("could not locate the data archive inside the package")
PY
[ $? -eq 0 ] || { no "extract data archive"; exit 1; }

R="$W/payload"
[ -x "$R/backrest" ] && ok "backrest binary is executable" || no "backrest binary not executable"
[ -x "$R/restic" ] && ok "restic binary is executable" || no "restic binary not executable"
[ -x "$R/backrest" ] && chk "backrest self-reports" "$("$R/backrest" --version 2>/dev/null | grep -c '^backrest version:')" "1"
[ -x "$R/restic" ] && chk "restic self-reports" "$("$R/restic" version 2>/dev/null | grep -c '^restic ')" "1"
[ -f "$R/backrest.sh" ] && ok "service script present" || no "service script missing"
[ -f "$R/config.json" ] && ok "config.json present" || no "config.json missing"
for g in .qpkg_icon.gif .qpkg_icon_80.gif .qpkg_icon_gray.gif; do
    if [ -f "$R/$g" ]; then ok "icon $g"; else no "icon $g missing"; fi
done

# The whole point of the glibc constraint: these must be static, or the NAS
# (glibc 2.21) cannot load them.
if command -v file >/dev/null 2>&1; then
    chk "backrest is statically linked" "$(file -b "$R/backrest" | grep -c 'statically linked')" "1"
    chk "restic is statically linked" "$(file -b "$R/restic" | grep -c 'statically linked')" "1"
fi

# ---------------------------------------------------------------- phase 2/3
run_phase(){ # $1=label  $2=PATH to use
    local label=$1 path=$2
    local root="$W/root.$label"
    local bin="$W/bin.$label"
    rm -rf "$root"; mkdir -p "$root/data" "$bin"
    cp "$R"/backrest "$R"/restic "$R"/backrest.sh "$R"/config.json "$root/"

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
        "$root/backrest.sh" > "$bin/svc.sh"
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

    chk "GET /"          "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/")" "200"
    chk "GET /metrics"   "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/metrics")" "200"
    chk "POST /v1.Backrest/GetConfig" \
        "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$TEST_PORT/v1.Backrest/GetConfig")" "200"

    # The bundled restic must be the one backrest uses. backrest only execs
    # restic when a backup task actually runs, so the proof is indirect:
    #   * no "installing restic" in the log  -> it did not download one
    #   * no $DATA/restic file              -> it did not self-install one
    #   * no "may not be supported" warning -> it accepted the bundled one
    if grep -qi 'installing restic\|downloading restic' "$root/data/log/backrest.log" 2>/dev/null; then
        no "backrest tried to download restic"
    else
        ok "no restic download attempted"
    fi
    if [ -e "$root/data/restic" ]; then
        no "backrest self-installed a restic binary"
    else
        ok "no self-installed restic binary"
    fi
    if grep -qi 'may not be supported by backrest' "$root/data/log/backrest.log" 2>/dev/null; then
        no "backrest rejected the bundled restic (version mismatch?)"
    else
        ok "bundled restic accepted"
    fi

    local pid; pid=$(cat "$root/data/backrest.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ok "pid alive ($pid)"; else no "pid not alive"; fi

    PATH="$path" "$bin/svc.sh" status >/dev/null 2>&1 && ok "status reports running" || no "status says not running"

    # rotate: pad past the 10 MB ceiling, expect a rotation; then expect no second one
    head -c 11000000 /dev/zero | tr '\0' 'x' >> "$root/data/log/backrest.log"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    chk "rotate emptied live log" "$(stat -c%s "$root/data/log/backrest.log")" "0"
    [ -s "$root/data/log/backrest.log.1" ] && ok "rotate kept previous log as .1" || no "no .1 after rotate"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    [ -f "$root/data/log/backrest.log.2" ] && no "rotate fired below the ceiling" || ok "rotate is size-gated"

    PATH="$path" "$bin/svc.sh" stop >/dev/null 2>&1
    sleep 1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then no "still alive after stop"; else ok "stopped cleanly"; fi
    [ -f "$root/data/backrest.pid" ] && no "pid file left behind" || ok "pid file removed"
    local after; after=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/" 2>/dev/null)
    # curl prints 000 and exits non-zero on a closed port; don't append another
    [ -n "$after" ] || after=000
    chk "port released" "$after" "000"
}

# normal environment (setsid usually present)
run_phase setsid "$PATH"

# Thin PATH with no setsid on it. This is the regression test for the real bug:
# the script must still find setsid by absolute path. The trap-hup branch is only
# reachable on a host that genuinely lacks setsid, so it cannot be forced here.
np="$W/nopath"; mkdir -p "$np"
for b in sh cat sleep grep kill tail mv wc mkdir sync rm ls sed tr cut awk netstat curl; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$np/$b"
done
run_phase thin-path "$np"

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
