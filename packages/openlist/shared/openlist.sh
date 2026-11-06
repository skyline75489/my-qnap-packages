#!/bin/sh
######################################################################
# OpenList QPKG service script.
#
# Called by QTS as: start | stop | restart | status | remove
# Called by cron as: rotate
#
# Notes that shaped this script:
#   * `openlist server` runs in the FOREGROUND and never daemonizes, so
#     start) backgrounds it and records a pid.
#   * OpenList resolves the paths in its config (data/data.db, data/temp,
#     data/log/log.log) against its WORKING DIRECTORY, not against the
#     config file's directory. Hence the cd to $QPKG_ROOT before exec: it
#     makes one relative layout valid on any volume, including across a
#     volume migration.
#   * The config file itself is NOT shipped in the package. OpenList creates
#     data/config.json on first start with a random jwt_secret; shipping
#     one would ship a known secret to every install.
#   * The port is pinned through the environment (OPENLIST_HTTP_PORT)
#     rather than through config.json: QTS proxies the web UI to whatever
#     QPKG_WEB_PORT says, so the two must not be able to drift apart.
#   * The Enable check is mandatory: QTS still runs this script at boot
#     even when the app is disabled, and without the check a disabled
#     service gets restarted.
######################################################################

CONF=/etc/config/qpkg.conf
QPKG_NAME="OpenList"

QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")

BIN="$QPKG_ROOT/openlist"
DATA="$QPKG_ROOT/data"
LOGDIR="$DATA/log"
CONSOLE="$LOGDIR/console.log"
PIDF="$DATA/openlist.pid"
ENVF="$QPKG_ROOT/openlist.env"

# 10 MB ceiling; the daily cron job only rotates when this is exceeded.
LOGSZ_MAX=10485760
# Files kept: console.log, console.log.1, console.log.2
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
    grep -q "openlist" "/proc/$_pid/cmdline" 2>/dev/null || return 1
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

    # OpenList refuses to start if the data directory is not writable and
    # executable, and it needs the log/ and temp/ subdirectories to exist.
    # umask 077: everything below $DATA holds the sqlite database, the
    # jwt_secret and (on first start) the admin password — none of it
    # should be world-readable on a multi-user NAS.
    umask 077
    mkdir -p "$DATA" "$LOGDIR" "$DATA/temp" || { err_msg "cannot create $DATA"; exit 1; }

    # The port QTS proxies to. Pinned here so it cannot drift away from
    # QPKG_WEB_PORT in qpkg.cfg.
    _PORT=$(/sbin/getcfg "$QPKG_NAME" Web_Port -d 5244 -f "$CONF")

    # Optional user file for environment overrides, e.g.
    #   OPENLIST_ADMIN_PASSWORD=<password>
    # which makes OpenList create the admin account on first start instead
    # of waiting for the web setup wizard. Sourced BEFORE the pinned
    # variables below so the port can never be changed by accident.
    # `set -a` exports everything the file assigns: a plain `.` would leave
    # the variables local to this shell and the child would never see them.
    if [ -f "$ENVF" ]; then
        # A syntax error in a sourced file kills the shell, so check first
        # and refuse to start with a clear message instead.
        if ! /bin/sh -n "$ENVF" 2>/dev/null; then
            err_msg "syntax error in $ENVF — fix it or remove it"
            exit 1
        fi
        set -a
        . "$ENVF"
        set +a
        log_msg "loaded environment overrides from $ENVF"
    fi

    OPENLIST_ADDR="0.0.0.0"
    OPENLIST_HTTP_PORT="$_PORT"
    export OPENLIST_ADDR OPENLIST_HTTP_PORT

    # Preserve the previous run's log across restarts. This is NOT the size
    # bound (that is the cron 'rotate' action); it exists so a post-crash
    # log survives the restart that follows it.
    [ -s "$CONSOLE" ] && mv -f "$CONSOLE" "$CONSOLE.1"

    log_msg "starting $BIN ($("$BIN" version 2>/dev/null | sed -n 's/^Version: *//p' | head -1)) on port $_PORT"

    # cd matters: the paths OpenList puts in its config are relative to cwd.
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
        "$_SETSID" /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" server --data data' \
            openlistdetach "$PIDF" "$BIN" </dev/null >>"$CONSOLE" 2>>"$CONSOLE" &
    elif [ -x /bin/busybox ] && /bin/busybox setsid true >/dev/null 2>&1; then
        _DETACH="busybox-setsid"
        /bin/busybox setsid /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" server --data data' \
            openlistdetach "$PIDF" "$BIN" </dev/null >>"$CONSOLE" 2>>"$CONSOLE" &
    else
        # Last resort. trap "" HUP is exactly what nohup does, but it does NOT
        # create a new session — if QTS kills this process group, OpenList dies
        # with it. Record enough context to diagnose that if it happens.
        _DETACH="trap-hup"
        log_msg "no setsid found; PATH=$PATH"
        /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2" server --data data' \
            openlistdetach "$PIDF" "$BIN" </dev/null >>"$CONSOLE" 2>>"$CONSOLE" &
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
            err_msg "OpenList exited during startup; see $CONSOLE"
        else
            err_msg "OpenList did not become ready within 15s"
        fi
        tail -n 20 "$CONSOLE" 2>/dev/null
        rm -f "$PIDF"
        exit 1
    fi

    # A live pid is not the same as a bound socket. QTS returns from `start` and
    # immediately offers the UI, and a client that connects in that window gets
    # ECONNREFUSED — indistinguishable from "not running". Wait for the listen
    # socket, bounded, and do not fail on timeout.
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

    # OpenList writes its config with mode 0777 (upstream hardcodes 0o777).
    # It holds the jwt_secret, so take the permissions back.
    [ -f "$DATA/config.json" ] && chmod 600 "$DATA/config.json" 2>/dev/null

    # OpenList v4 does NOT create an admin account on its own: it waits for
    # the web setup wizard unless OPENLIST_ADMIN_PASSWORD was provided.
    # Say so, otherwise the UI looks broken.
    if [ -z "$OPENLIST_ADMIN_PASSWORD" ] && [ ! -f "$DATA/data.db" ]; then
        log_msg "no admin account yet: open the web UI to run the setup wizard, or set OPENLIST_ADMIN_PASSWORD in $ENVF"
    fi

    # When OpenList created the admin itself it prints the initial password
    # to stdout — which we captured. Surface it in the QTS system log, it is
    # only ever printed once.
    if grep -q 'initial password is:' "$CONSOLE" 2>/dev/null; then
        log_msg "$(grep 'initial password is:' "$CONSOLE" 2>/dev/null | tail -1)"
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
    # The sqlite database is in WAL mode: give the kernel a nudge so the
    # last transactions are flushed to disk.
    sync
    log_msg "stopped"
}

do_status(){
    if is_running; then
        echo "$QPKG_NAME is running (pid $(cat "$PIDF"), port $(/sbin/getcfg "$QPKG_NAME" Web_Port -d 5244 -f "$CONF"))"
        exit 0
    fi
    echo "$QPKG_NAME is not running"
    exit 1
}

# Cron-driven size cap for the stdout capture. Rotates only when the file has
# actually grown past the ceiling, so it is a safety net rather than a
# scheduled disturbance. OpenList rotates its own data/log/log.log.
do_rotate(){
    [ -f "$CONSOLE" ] || exit 0
    SIZE=$(wc -c < "$CONSOLE" 2>/dev/null || echo 0)
    [ "$SIZE" -gt "$LOGSZ_MAX" ] || exit 0

    _i=$LOG_KEEP
    while [ $_i -gt 1 ]; do
        _prev=$((_i - 1))
        [ -f "$CONSOLE.$_prev" ] && mv -f "$CONSOLE.$_prev" "$CONSOLE.$_i"
        _i=$_prev
    done
    mv -f "$CONSOLE" "$CONSOLE.1"
    : > "$CONSOLE"
    log_msg "rotated console log ($SIZE bytes)"
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
