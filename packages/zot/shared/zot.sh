#!/bin/sh
######################################################################
# zot QPKG service script.
#
# Called by QTS as: start | stop | restart | status | remove
# Called by cron as: rotate
#
# Notes that shaped this script:
#   * zot serve runs in the FOREGROUND and never daemonizes, so start)
#     backgrounds it and records a pid.
#   * zot resolves RELATIVE storage/log paths against its working
#     directory, not against the config file's directory. Hence the cd to
#     $QPKG_ROOT before exec: it makes one config.json valid on any
#     volume, including across a volume migration.
#   * log.output is intentionally absent from config.json, so zot logs to
#     stdout. We own the redirect, which means we own rotation and there
#     is only ever one writer to the file.
#   * The Enable check is mandatory: QTS still runs this script at boot
#     even when the app is disabled, and without the check a disabled
#     service gets restarted.
######################################################################

CONF=/etc/config/qpkg.conf
QPKG_NAME="Zot"

QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")

BIN="$QPKG_ROOT/zot"
CFG="$QPKG_ROOT/config.json"
DATA="$QPKG_ROOT/data"
LOG="$DATA/log/zot.log"
CONSOLE="$DATA/log/console.log"
PIDF="$DATA/zot.pid"

# 10 MB ceiling; the daily cron job only rotates when this is exceeded.
LOGSZ_MAX=10485760
# Files kept: zot.log, zot.log.1, zot.log.2
LOG_KEEP=2

log_msg(){
    echo "[$QPKG_NAME] $*"
    /sbin/write_log "[$QPKG_NAME] $*" 4 2>/dev/null
}

err_msg(){
    echo "[$QPKG_NAME] ERROR: $*" >&2
    /sbin/write_log "[$QPKG_NAME] ERROR: $*" 1 2>/dev/null
}

is_running(){
    [ -f "$PIDF" ] || return 1
    _pid=$(cat "$PIDF" 2>/dev/null)
    [ -n "$_pid" ] || return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    # guard against a recycled pid belonging to something else
    grep -q "zot" "/proc/$_pid/cmdline" 2>/dev/null || return 1
    return 0
}

do_start(){
    ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi

    if is_running; then
        log_msg "already running (pid $(cat "$PIDF"))"
        exit 0
    fi

    if [ ! -x "$BIN" ]; then
        err_msg "binary missing or not executable: $BIN"
        exit 1
    fi
    if [ ! -f "$CFG" ]; then
        err_msg "config missing: $CFG"
        exit 1
    fi

    # Storage root must exist and be writable, or zot nil-derefs on startup
    # instead of exiting cleanly.
    mkdir -p "$DATA/storage" "$DATA/log" || { err_msg "cannot create $DATA"; exit 1; }

    # Preserve the previous run's log across restarts. This is NOT the size
    # bound (that is the cron 'rotate' action); it exists so a post-crash
    # log survives the restart that follows it.
    [ -s "$LOG" ] && mv -f "$LOG" "$LOG.1"

    log_msg "starting $BIN ($( "$BIN" --version 2>/dev/null | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' ))"

    # cd matters: relative paths in config.json resolve against cwd.
    cd "$QPKG_ROOT" || { err_msg "cannot cd to $QPKG_ROOT"; exit 1; }

    # Detach without trusting PATH or assuming nohup exists.
    #
    # Precedent: DownloadCenter (tasict/DownloadCenter) calls plain `setsid`
    # unconditionally; roon-qpkg and changedetection do `command -v setsid` then
    # fall back to `nohup`. None of them probe absolute paths, so on a host where
    # the init-time PATH is thin, `command -v` can miss a setsid that is present.
    # This NAS reported "nohup: command not found", which means the else-branch
    # was reached — so probe fixed locations first rather than trusting PATH.
    _SETSID=""
    for _c in /usr/bin/setsid /bin/setsid /usr/sbin/setsid /sbin/setsid /usr/local/bin/setsid; do
        if [ -x "$_c" ]; then _SETSID="$_c"; break; fi
    done
    if [ -z "$_SETSID" ] && command -v setsid >/dev/null 2>&1; then
        _SETSID=$(command -v setsid)
    fi

    if [ -n "$_SETSID" ]; then
        _DETACH="setsid($_SETSID)"
        "$_SETSID" /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" serve "$3"' \
            zotdetach "$PIDF" "$BIN" "$CFG" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    elif [ -x /bin/busybox ] && /bin/busybox setsid true >/dev/null 2>&1; then
        _DETACH="busybox-setsid"
        /bin/busybox setsid /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" serve "$3"' \
            zotdetach "$PIDF" "$BIN" "$CFG" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    else
        # Last resort. trap "" HUP is exactly what nohup does, but it does NOT
        # create a new session — if QTS kills this process group, zot dies with
        # it. Record enough context to diagnose that if it happens.
        _DETACH="trap-hup"
        log_msg "no setsid found; PATH=$PATH"
        /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" serve "$3"' \
            zotdetach "$PIDF" "$BIN" "$CFG" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    fi
    log_msg "detach method: $_DETACH"

    # Do not judge liveness on the first instant: between fork and exec the pid
    # exists but its /proc cmdline is still the shell, so a naive check reports
    # failure on a perfectly healthy start. Wait for the pid file, and tell
    # "still starting" apart from "died".
    _n=0
    _dead=0
    while [ "$_n" -lt 15 ]; do
        is_running && break
        if [ -s "$PIDF" ]; then
            _pid=$(cat "$PIDF" 2>/dev/null)
            if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
                _dead=1
                break
            fi
        fi
        sleep 1
        _n=$((_n + 1))
    done

    if ! is_running; then
        if [ "$_dead" -eq 1 ]; then
            err_msg "zot exited during startup; see $CONSOLE"
        else
            err_msg "zot did not become ready within 15s"
        fi
        tail -n 20 "$CONSOLE" 2>/dev/null
        rm -f "$PIDF"
        exit 1
    fi

    # A live pid is not the same as a bound socket. QTS returns from `start` and
    # immediately offers the UI, and a client that connects in that window gets
    # ECONNREFUSED — indistinguishable from "not running". Wait for the listen
    # socket, bounded, and do not fail on timeout: a large blob store can take a
    # while to reparse and zot does bind eventually.
    _PORT=$(/sbin/getcfg "$QPKG_NAME" Web_Port -d 5050 -f "$CONF")
    if command -v netstat >/dev/null 2>&1; then
        _n=0
        while [ "$_n" -lt 15 ]; do
            if netstat -tln 2>/dev/null | grep -q "[:.]${_PORT} "; then
                log_msg "listening on port $_PORT"
                _n=-1
                break
            fi
            sleep 1
            _n=$((_n + 1))
        done
        [ "$_n" -eq 15 ] && log_msg "pid is up but port $_PORT is not listening yet"
    fi

    log_msg "started (pid $(cat "$PIDF"))"
}

do_stop(){
    if ! is_running; then
        log_msg "not running"
        rm -f "$PIDF"
        exit 0
    fi
    _pid=$(cat "$PIDF")
    log_msg "stopping pid $_pid"
    kill "$_pid" 2>/dev/null

    _n=0
    while [ "$_n" -lt 25 ]; do
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
        _n=$((_n + 1))
    done

    if kill -0 "$_pid" 2>/dev/null; then
        err_msg "did not exit gracefully, sending SIGKILL"
        kill -9 "$_pid" 2>/dev/null
    fi

    rm -f "$PIDF"
    # Blobs must be flushed: commit:true fsyncs writes, but give the kernel a nudge.
    sync
    log_msg "stopped"
}

do_status(){
    if is_running; then
        echo "$QPKG_NAME is running (pid $(cat "$PIDF"), port $(/sbin/getcfg "$QPKG_NAME" Web_Port -d 5050 -f "$CONF"))"
        exit 0
    fi
    echo "$QPKG_NAME is not running"
    exit 1
}

# Cron-driven size cap. Rotates only when the file has actually grown past the
# ceiling, so it is a safety net rather than a scheduled disturbance.
do_rotate(){
    [ -f "$LOG" ] || exit 0
    SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$SIZE" -gt "$LOGSZ_MAX" ] || exit 0

    _i=$LOG_KEEP
    while [ $_i -gt 1 ]; do
        _prev=$((_i - 1))
        [ -f "$LOG.$_prev" ] && mv -f "$LOG.$_prev" "$LOG.$_i"
        _i=$_prev
    done
    mv -f "$LOG" "$LOG.1"
    : > "$LOG"
    log_msg "rotated log ($SIZE bytes)"
}

case "$1" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)  do_status ;;
    rotate)  do_rotate ;;
    remove)  do_stop ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|rotate|remove}"
        exit 1
        ;;
esac

exit 0
