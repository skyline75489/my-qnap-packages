#!/bin/sh
######################################################################
# Tunewright QPKG service script.
#
# Called by QTS as: start | stop | restart | status | remove
# Called by cron as: rotate
#
# Notes that shaped this script:
#   * tunewright-server runs in the FOREGROUND and never daemonizes, so
#     start) backgrounds it and records a pid.
#   * The server traps SIGINT and SIGTERM and drains open connections for up
#     to 25 seconds. A second signal makes it exit immediately, so stop)
#     sends SIGTERM, waits, and sends a second SIGTERM before SIGKILL.
#   * Paths are absolute and resolved at run time, so the package keeps
#     working across a volume migration.
#   * The Enable check is mandatory: QTS still runs this script at boot
#     even when the app is disabled, and without the check a disabled
#     service gets restarted.
#   * The music library is the app's data directory. It is NOT under
#     $QPKG_ROOT/data: that directory is wiped on uninstall, and the library
#     is the user's own files.
######################################################################

CONF=/etc/config/qpkg.conf
QPKG_NAME="Tunewright"

QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")

BIN="$QPKG_ROOT/tunewright"
STATIC="$QPKG_ROOT/static"
APPCFG="$QPKG_ROOT/tunewright.conf"
DATA="$QPKG_ROOT/data"
LOGDIR="$DATA/log"
LOG="$LOGDIR/tunewright.log"
PIDF="$DATA/tunewright.pid"

# The port QTS knows about. tunewright.conf may override it; the App Center's
# "Web UI" link uses the QTS value, so the two are read from the same place.
PORT=$(/sbin/getcfg "$QPKG_NAME" Web_Port -d 8081 -f "$CONF")

# 10 MB ceiling; the daily cron job only rotates when this is exceeded.
LOGSZ_MAX=10485760
# Files kept: tunewright.log, tunewright.log.1, tunewright.log.2
LOG_KEEP=2

log_msg(){
    echo "[$QPKG_NAME] $*"
    /sbin/write_log "[$QPKG_NAME] $*" 4 2>/dev/null
}

err_msg(){
    echo "[$QPKG_NAME] ERROR: $*" >&2
    /sbin/write_log "[$QPKG_NAME] ERROR: $*" 1 2>/dev/null
}

# Read a KEY="value" line out of the app config. A missing or malformed
# line yields the supplied default, so a broken config never stops the
# package from starting with sane values.
cfg_get(){
    _key="$1"; _def="$2"; _val=""
    if [ -f "$APPCFG" ]; then
        _val=$(sed -n "s/^[[:space:]]*${_key}[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$APPCFG" 2>/dev/null | tail -1)
    fi
    if [ -n "$_val" ]; then
        echo "$_val"
    else
        echo "$_def"
    fi
}

is_running(){
    [ -f "$PIDF" ] || return 1
    _pid=$(cat "$PIDF" 2>/dev/null)
    [ -n "$_pid" ] || return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    # guard against a recycled pid belonging to something else
    grep -q "tunewright" "/proc/$_pid/cmdline" 2>/dev/null || return 1
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

    if [ ! -f "$STATIC/index.html" ]; then
        err_msg "frontend build missing: $STATIC/index.html"
        exit 1
    fi

    MUSIC_DIR=$(cfg_get MUSIC_DIR "/share/Multimedia/Music")
    STATE_DIR=$(cfg_get STATE_DIR "")
    PORT=$(cfg_get PORT "$PORT")
    HOST=$(cfg_get HOST "0.0.0.0")
    SETUP_TOKEN=$(cfg_get SETUP_TOKEN "")
    COOKIE_SECURE=$(cfg_get COOKIE_SECURE "false")
    TRUST_PROXY=$(cfg_get TRUST_PROXY "false")

    # An empty STATE_DIR means the packaged default: the account database
    # lives with the package, not inside the music library.
    [ -n "$STATE_DIR" ] || STATE_DIR="$DATA/state"

    if [ ! -d "$MUSIC_DIR" ]; then
        # The server canonicalises its data directory and panics if it does
        # not exist — it will not create it itself. Create it here, and say
        # so, because an empty directory means an empty library.
        if mkdir -p "$MUSIC_DIR" 2>/dev/null; then
            log_msg "WARNING: created the music directory $MUSIC_DIR (it was empty or missing)"
        else
            err_msg "music directory does not exist and cannot be created: $MUSIC_DIR"
            err_msg "edit $APPCFG (MUSIC_DIR) and restart"
            exit 1
        fi
    fi

    mkdir -p "$LOGDIR" "$STATE_DIR" "$DATA/tmp" || {
        err_msg "cannot create $DATA"
        exit 1
    }

    # Preserve the previous run's log across restarts. This is NOT the size
    # bound (that is the cron 'rotate' action); it exists so a post-crash
    # log survives the restart that follows it.
    [ -s "$LOG" ] && mv -f "$LOG" "$LOG.1"

    log_msg "starting $BIN on port $PORT (library: $MUSIC_DIR)"

    # Configuration for the app. Every path is absolute.
    TUNEWRIGHT_DATA_DIR="$MUSIC_DIR"
    TUNEWRIGHT_STATE_DIR="$STATE_DIR"
    TUNEWRIGHT_STATIC_DIR="$STATIC"
    TUNEWRIGHT_PORT="$PORT"
    TUNEWRIGHT_HOST="$HOST"
    TUNEWRIGHT_COOKIE_SECURE="$COOKIE_SECURE"
    TUNEWRIGHT_TRUST_PROXY="$TRUST_PROXY"
    # QTS's /tmp is a small tmpfs. Nothing here is supposed to write there,
    # but pointing TMPDIR at the volume keeps a stray temp write from
    # failing with "no space left on device".
    TMPDIR="$DATA/tmp"
    export TUNEWRIGHT_DATA_DIR TUNEWRIGHT_STATE_DIR TUNEWRIGHT_STATIC_DIR
    export TUNEWRIGHT_PORT TUNEWRIGHT_HOST TUNEWRIGHT_COOKIE_SECURE
    export TUNEWRIGHT_TRUST_PROXY TMPDIR

    if [ -n "$SETUP_TOKEN" ]; then
        TUNEWRIGHT_SETUP_TOKEN="$SETUP_TOKEN"
        export TUNEWRIGHT_SETUP_TOKEN
    fi

    # TLS for the MusicBrainz / Apple Music lookups goes through rustls,
    # which reads the system CA bundle. If there is none, the lookups fail
    # (the rest of the app does not). Say so once instead of leaving it to
    # be discovered.
    if [ ! -f /etc/ssl/certs/ca-certificates.crt ] \
       && [ ! -f /etc/pki/tls/certs/ca-bundle.crt ] \
       && [ ! -f /etc/ssl/ca-bundle.pem ]; then
        log_msg "WARNING: no system CA bundle found — MusicBrainz/Apple Music lookups will fail"
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
            tunewrightdetach "$PIDF" "$BIN" </dev/null >>"$LOG" 2>&1 &
    elif [ -x /bin/busybox ] && /bin/busybox setsid true >/dev/null 2>&1; then
        _DETACH="busybox-setsid"
        /bin/busybox setsid /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2"' \
            tunewrightdetach "$PIDF" "$BIN" </dev/null >>"$LOG" 2>&1 &
    else
        # Last resort. trap "" HUP is exactly what nohup does, but it does NOT
        # create a new session — if QTS kills this process group, the server
        # dies with it. Record enough context to diagnose that if it happens.
        _DETACH="trap-hup"
        log_msg "no setsid found; PATH=$PATH"
        /bin/sh -c 'echo $$ > "$1"; trap "" HUP; exec "$2"' \
            tunewrightdetach "$PIDF" "$BIN" </dev/null >>"$LOG" 2>&1 &
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
            err_msg "tunewright exited during startup; see $LOG"
        else
            err_msg "tunewright did not become ready within 15s"
        fi
        tail -n 20 "$LOG" 2>/dev/null
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

    # SIGTERM first: the server drains open connections (up to 25s) before it
    # exits, so a request in flight is not cut off mid-write.
    kill -TERM "$_pid" 2>/dev/null

    _n=0
    while [ "$_n" -lt 30 ]; do
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
        _n=$((_n + 1))
    done

    # A second signal makes the server exit immediately instead of draining
    # for another 25 seconds.
    if kill -0 "$_pid" 2>/dev/null; then
        err_msg "did not drain within 30s, sending a second SIGTERM"
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
