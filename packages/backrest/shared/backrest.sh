#!/bin/sh
######################################################################
# Backrest QPKG service script.
#
# Called by QTS as: start | stop | restart | status | remove
# Called by cron as: rotate
#
# Notes that shaped this script:
#   * backrest runs in the FOREGROUND and never daemonizes, so start)
#     backgrounds it and records a pid.
#   * backrest would download a restic binary on first start if it cannot
#     find one. This package ships restic and points BACKREST_RESTIC_COMMAND
#     at it, so the NAS never reaches out to the internet at runtime. If the
#     bundled restic is missing we fail instead of letting it download.
#   * backrest resolves its data directory from BACKREST_DATA and its config
#     from BACKREST_CONFIG, so both are absolute paths under $QPKG_ROOT and
#     stay valid across a volume migration.
#   * backrest only handles SIGINT, not SIGTERM, so stop) sends SIGINT to
#     let it shut its sqlite databases down cleanly before escalating.
#   * The Enable check is mandatory: QTS still runs this script at boot
#     even when the app is disabled, and without the check a disabled
#     service gets restarted.
######################################################################

CONF=/etc/config/qpkg.conf
QPKG_NAME="Backrest"

QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")

BIN="$QPKG_ROOT/backrest"
RESTIC="$QPKG_ROOT/restic"
CFG="$QPKG_ROOT/config.json"
DATA="$QPKG_ROOT/data"
LOGDIR="$DATA/log"
LOG="$LOGDIR/backrest.log"
CONSOLE="$LOGDIR/console.log"
PIDF="$DATA/backrest.pid"

PORT=$(/sbin/getcfg "$QPKG_NAME" Web_Port -d 9898 -f "$CONF")

# 10 MB ceiling; the daily cron job only rotates when this is exceeded.
LOGSZ_MAX=10485760
# Files kept: backrest.log, backrest.log.1, backrest.log.2
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
    grep -q "backrest" "/proc/$_pid/cmdline" 2>/dev/null || return 1
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

    # Without a restic binary backrest downloads one at first start. This
    # package must never do that: the NAS has no business reaching out to
    # the internet, and an unattended download is an unreviewed binary.
    if [ ! -x "$RESTIC" ]; then
        err_msg "bundled restic missing or not executable: $RESTIC"
        exit 1
    fi

    mkdir -p "$LOGDIR" "$DATA/home" "$DATA/restic-cache" "$DATA/tmp" || {
        err_msg "cannot create $DATA"
        exit 1
    }

    # Preserve the previous run's log across restarts. This is NOT the size
    # bound (that is the cron 'rotate' action); it exists so a post-crash
    # log survives the restart that follows it.
    [ -s "$LOG" ] && mv -f "$LOG" "$LOG.1"

    log_msg "starting $BIN ($("$BIN" --version 2>/dev/null | sed -n 's/^backrest version: \([^,]*\).*/\1/p')) on port $PORT"

    # Configuration for the app. All paths are absolute and inside
    # $QPKG_ROOT so they survive a volume migration.
    HOME="$DATA/home"
    BACKREST_CONFIG="$CFG"
    BACKREST_DATA="$DATA"
    BACKREST_PORT=":$PORT"
    BACKREST_RESTIC_COMMAND="$RESTIC"
    RESTIC_CACHE_DIR="$DATA/restic-cache"
    # QTS's /tmp is a small tmpfs. restic writes its in-progress pack files
    # there (fs.TempFile("", "restic-temp-pack-") -> os.TempDir()), and a
    # backup that outgrows /tmp dies with "no space left on device" while
    # saving the snapshot. Point TMPDIR at the volume instead. restic has no
    # --temp-dir flag; TMPDIR is the only knob, and it is inherited by the
    # restic subprocess because Backrest passes its own environment through.
    TMPDIR="$DATA/tmp"
    XDG_CONFIG_HOME="$DATA/home/.config"
    XDG_CACHE_HOME="$DATA/home/.cache"
    export HOME BACKREST_CONFIG BACKREST_DATA BACKREST_PORT BACKREST_RESTIC_COMMAND
    export RESTIC_CACHE_DIR TMPDIR XDG_CONFIG_HOME XDG_CACHE_HOME

    # The UI has no authentication until a user is created in its settings.
    # Say so once per start rather than leaving it to be discovered.
    if [ -f "$CFG" ] && grep -q '"disabled"[[:space:]]*:[[:space:]]*true' "$CFG" 2>/dev/null; then
        log_msg "WARNING: authentication is disabled — create a user in the Backrest UI before exposing this to anything untrusted"
    fi

    cd "$QPKG_ROOT" || { err_msg "cannot cd to $QPKG_ROOT"; exit 1; }

    # Detach without trusting PATH or assuming nohup exists.
    #
    # QTS has no systemd and often no setsid on PATH, so probe fixed
    # locations first rather than trusting `command -v`. This NAS reported
    # "nohup: command not found" before, which means a PATH-only probe is
    # not enough.
    _SETSID=""
    for _c in /usr/bin/setsid /bin/setsid /usr/sbin/setsid /sbin/setsid /usr/local/bin/setsid; do
        if [ -x "$_c" ]; then _SETSID="$_c"; break; fi
    done
    if [ -z "$_SETSID" ] && command -v setsid >/dev/null 2>&1; then
        _SETSID=$(command -v setsid)
    fi

    if [ -n "$_SETSID" ]; then
        _DETACH="setsid($_SETSID)"
        "$_SETSID" /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2"' \
            backrestdetach "$PIDF" "$BIN" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    elif [ -x /bin/busybox ] && /bin/busybox setsid true >/dev/null 2>&1; then
        _DETACH="busybox-setsid"
        /bin/busybox setsid /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2"' \
            backrestdetach "$PIDF" "$BIN" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    else
        # Last resort. trap "" HUP is exactly what nohup does, but it does NOT
        # create a new session — if QTS kills this process group, backrest dies
        # with it. Record enough context to diagnose that if it happens.
        _DETACH="trap-hup"
        log_msg "no setsid found; PATH=$PATH"
        /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2"' \
            backrestdetach "$PIDF" "$BIN" </dev/null >>"$LOG" 2>>"$CONSOLE" &
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
            err_msg "backrest exited during startup; see $CONSOLE"
        else
            err_msg "backrest did not become ready within 15s"
        fi
        tail -n 20 "$CONSOLE" 2>/dev/null
        rm -f "$PIDF"
        exit 1
    fi

    # A live pid is not the same as a bound socket. QTS returns from `start`
    # and immediately offers the UI, and a client that connects in that window
    # gets ECONNREFUSED — indistinguishable from "not running". Wait for the
    # listen socket, bounded.
    if command -v netstat >/dev/null 2>&1; then
        _n=0
        while [ "$_n" -lt 15 ]; do
            if netstat -tln 2>/dev/null | grep -q "[:.]${PORT} "; then
                log_msg "listening on port $PORT"
                _n=-1
                break
            fi
            sleep 1
            _n=$((_n + 1))
        done
        [ "$_n" -eq 15 ] && log_msg "pid is up but port $PORT is not listening yet"
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

    # SIGINT first: backrest traps os.Interrupt and shuts its sqlite
    # connections down in order. It does not trap SIGTERM, which would kill
    # it mid-transaction.
    kill -INT "$_pid" 2>/dev/null

    _n=0
    while [ "$_n" -lt 25 ]; do
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
        _n=$((_n + 1))
    done

    if kill -0 "$_pid" 2>/dev/null; then
        err_msg "did not exit on SIGINT, sending SIGTERM"
        kill -TERM "$_pid" 2>/dev/null
        sleep 2
    fi

    if kill -0 "$_pid" 2>/dev/null; then
        err_msg "did not exit gracefully, sending SIGKILL"
        kill -9 "$_pid" 2>/dev/null
    fi

    rm -f "$PIDF"
    sync
    log_msg "stopped"
}

do_status(){
    if is_running; then
        echo "$QPKG_NAME is running (pid $(cat "$PIDF"), port $PORT)"
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
