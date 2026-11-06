#!/usr/bin/env bash
# Verify the OpenList .qpkg WITHOUT a NAS.
#
#   scripts/test-openlist.sh [path/to/pkg.qpkg]
#
# Three phases, same shape as scripts/test-package.sh:
#   1. structure  -- decompress the archives inside the .qpkg and check members,
#                    modes, and the payload's presence
#   2. runtime    -- plant the payload in a fake root with stubbed QTS helpers
#                    (/sbin/getcfg, /sbin/write_log) and drive the real service
#                    script through start -> readiness -> status -> rotate -> stop
#   3. detach     -- run phase 2 twice: once normally, once with a PATH that has
#                    no setsid, to exercise the QTS fallback chain
#
# This is the only way to catch the failure modes that qbuild reports as success.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QPKG="${1:-}"
if [ -z "$QPKG" ]; then
    QPKG=$(ls -1t "$REPO_ROOT"/packages/openlist/build/*.qpkg 2>/dev/null | head -1)
fi
[ -f "$QPKG" ] || { echo "no .qpkg found; run scripts/build-qpkg.sh openlist first" >&2; exit 1; }

# Deliberately NOT $PORT: the environment of a build host often has PORT set
# to something else (a dev server), and inheriting it would point the test
# at a foreign service. Never 5244 either: that is the real service port.
TEST_PORT=${TEST_PORT:-5245}
W=${WORKDIR:-$(mktemp -d)}
# KEEP=1 leaves the fake root behind for inspection after a failure.
if [ "${KEEP:-0}" != "1" ]; then trap 'rm -rf "$W"' EXIT; fi

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
        if './openlist' in tf.getnames():
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
[ -x "$R/openlist" ] && ok "payload binary is executable" || no "payload binary not executable"
[ -x "$R/openlist" ] && chk "binary self-reports" "$("$R/openlist" version 2>/dev/null | grep -c '^Version:')" "1"
[ -f "$R/openlist.sh" ] && ok "service script present" || no "service script missing"
for g in .qpkg_icon.gif .qpkg_icon_80.gif .qpkg_icon_gray.gif; do
    if [ -f "$R/$g" ]; then ok "icon $g"; else no "icon $g missing"; fi
done

# The binary must be static: a libc-linked build would depend on the NAS's
# glibc 2.21 and is a different animal than the one this package was tested
# against.
if file "$R/openlist" | grep -q 'statically linked'; then
    ok "payload is statically linked"
else
    no "payload is NOT statically linked: $(file "$R/openlist")"
fi

# ---------------------------------------------------------------- phase 2/3
run_phase(){ # $1=label  $2=PATH to use
    local label=$1 path=$2
    local root="$W/root.$label"
    local bin="$W/bin.$label"
    rm -rf "$root"; mkdir -p "$root" "$bin"
    cp "$R"/openlist "$R"/openlist.sh "$root/"

    # Ask OpenList for a known admin password instead of leaving it to the web
    # setup wizard. Exercises the documented first-run path.
    cat > "$root/openlist.env" <<'EOF'
OPENLIST_ADMIN_PASSWORD=testpassword123
EOF

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
        "$root/openlist.sh" > "$bin/svc.sh"
    chmod +x "$bin/svc.sh"

    echo
    echo "== 2. runtime ($label)"
    PATH="$path" "$bin/svc.sh" start >"$bin/start.out" 2>&1
    chk "start exit" "$?" "0"
    grep -q 'detach method' "$bin/start.out" && ok "reports detach method: $(sed -n 's/.*detach method: //p' "$bin/start.out" | tail -1)" \
        || no "no detach method logged"

    # The port is pinned through the environment, so the service must listen
    # on the port QTS was told about, not on OpenList's built-in default.
    chk "GET /ping " "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/ping")" "200"
    chk "GET /     " "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/")" "200"
    chk "GET /api/public/settings" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/api/public/settings")" "200"
    # curl prints 000 and exits non-zero on a closed port; do not append
    # another 000 to it.
    nothere=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:5244/ping" 2>/dev/null)
    [ -n "$nothere" ] || nothere=000
    chk "not on default port 5244" "$nothere" "000"

    local pid; pid=$(cat "$root/data/openlist.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ok "pid alive ($pid)"; else no "pid not alive"; fi

    # The config must use paths relative to the working directory, otherwise a
    # volume migration would leave the service pointing at the old volume.
    chk "config db path is relative" "$(python3 -c "import json;print(json.load(open('$root/data/config.json'))['database']['db_file'])")" "data/data.db"
    chk "config temp path is relative" "$(python3 -c "import json;print(json.load(open('$root/data/config.json'))['temp_dir'])")" "data/temp"

    # The admin account must exist with the password we asked for.
    chk "admin account created" "$(python3 -c "
import sqlite3;c=sqlite3.connect('$root/data/data.db')
print(list(c.execute(\"select username from x_users where username='admin'\"))[0][0])")" "admin"
    grep -q 'initial password is: testpassword123' "$root/data/log/console.log" \
        && ok "initial password reported in the console log" \
        || no "initial password not reported"

    PATH="$path" "$bin/svc.sh" status >/dev/null 2>&1 && ok "status reports running" || no "status says not running"

    # rotate: pad past the 10 MB ceiling, expect a rotation; then expect no second one
    head -c 11000000 /dev/zero | tr '\0' 'x' >> "$root/data/log/console.log"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    chk "rotate emptied live log" "$(stat -c%s "$root/data/log/console.log")" "0"
    [ -s "$root/data/log/console.log.1" ] && ok "rotate kept previous log as .1" || no "no .1 after rotate"
    PATH="$path" "$bin/svc.sh" rotate >/dev/null 2>&1
    [ -f "$root/data/log/console.log.2" ] && no "rotate fired below the ceiling" || ok "rotate is size-gated"

    PATH="$path" "$bin/svc.sh" stop >/dev/null 2>&1
    sleep 1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then no "still alive after stop"; else ok "stopped cleanly"; fi
    [ -f "$root/data/openlist.pid" ] && no "pid file left behind" || ok "pid file removed"
    local after; after=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/ping" 2>/dev/null)
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
