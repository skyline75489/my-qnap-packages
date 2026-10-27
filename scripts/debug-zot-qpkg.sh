#!/bin/sh
# Read-only diagnostics for the zot QPKG on QTS.
#
# Run as root on the NAS:   sh debug-zot-qpkg.sh
#
# Busybox-safe: no bashisms, no ss, no absolute paths for coreutils (QTS does
# not consistently symlink them into /bin and /usr/bin). Changes nothing.

QPKG_NAME=Zot
CONF=/etc/config/qpkg.conf

sec(){ echo; echo "===== $* ====="; }

sec "qpkg.conf entry"
if grep -q "^\[$QPKG_NAME\]" "$CONF" 2>/dev/null; then
    sed -n "/^\[$QPKG_NAME\]/,/^\[/p" "$CONF" | head -25
else
    echo "  NO [$QPKG_NAME] SECTION IN $CONF  <-- package not registered"
fi

sec "resolved paths"
ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF" 2>/dev/null)
echo "  Install_Path : ${ROOT:-<empty>}"
echo "  Version      : $(/sbin/getcfg "$QPKG_NAME" Version -f "$CONF" 2>/dev/null)"
echo "  Enable       : $(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF" 2>/dev/null)"
echo "  Shell        : $(/sbin/getcfg "$QPKG_NAME" Shell -f "$CONF" 2>/dev/null)"
echo "  Web_Port     : $(/sbin/getcfg "$QPKG_NAME" Web_Port -f "$CONF" 2>/dev/null)"
echo "  Volume_Select: $(/sbin/getcfg "$QPKG_NAME" Volume_Select -f "$CONF" 2>/dev/null)"

sec "installed files"
if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
    ls -la "$ROOT" 2>&1
    echo "--- data/ ---"
    ls -la "$ROOT/data" 2>&1
    echo "--- data/log ---"
    ls -la "$ROOT/data/log" 2>&1
else
    echo "  install dir missing: '$ROOT'"
fi

sec "binary sanity (does it even execute here?)"
if [ -n "$ROOT" ] && [ -x "$ROOT/zot" ]; then
    echo "  size: $(ls -l "$ROOT/zot" | awk '{print $5}') bytes"
    "$ROOT/zot" --version 2>&1 | head -2
else
    echo "  '$ROOT/zot' missing or not executable"
fi

sec "is zot running?"
ps 2>/dev/null | grep -i '[z]ot' || echo "  no zot process"

sec "pid file"
if [ -n "$ROOT" ]; then
    if [ -f "$ROOT/data/zot.pid" ]; then
        echo "  pid=$(cat "$ROOT/data/zot.pid" 2>/dev/null)"
    else
        echo "  no pid file  <-- never started, or exited before writing it"
    fi
fi

sec "anything listening on 5050?"
netstat -tln 2>/dev/null | grep -E '5050|LISTEN' | head -20 || echo "  netstat unavailable"

sec "zot.log (last 30)"
[ -n "$ROOT" ] && tail -30 "$ROOT/data/log/zot.log" 2>&1

sec "console.log (last 30) - panics land here"
[ -n "$ROOT" ] && tail -30 "$ROOT/data/log/console.log" 2>&1

sec "config.json as installed"
[ -n "$ROOT" ] && cat "$ROOT/config.json" 2>&1

sec "free space on install volume"
[ -n "$ROOT" ] && df -h "$ROOT" 2>&1

sec "DONE"
echo "  If nothing above is conclusive, two follow-ups (these DO change state):"
echo "    1) sh $ROOT/zot.sh start          # prints its own error, if any"
echo "    2) sleep 10; ps | grep [z]ot; netstat -tln | grep 5050"
echo "  If (2) shows zot alive and 5050 listening, the service works but is"
echo "  being killed later -> that is the App Center process-group problem."
