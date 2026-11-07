#!/bin/sh
######################################################################
# PicoClaw QPKG service script.
#
# Called by QTS as: start | stop | restart | status | remove
# Called by cron as: rotate
#
# Notes that shaped this script:
#   * The long-running process is `picoclaw-launcher`, upstream's web
#     console and gateway manager. It runs in the FOREGROUND and never
#     daemonizes, so start) backgrounds it and records a pid.
#   * The launcher finds the `picoclaw` CLI next to itself. Both binaries
#     ship in the package root; PICOCLAW_BINARY is set explicitly anyway,
#     because the fallback is $PATH and the QTS PATH is not ours.
#   * All state lives under $QPKG_ROOT/home: config.json, .security.yml
#     (API keys), the dashboard password database, the logs and the agent
#     workspace. HOME points there too, so the agent's ~/.ssh key and
#     caches stay on the volume instead of in /root.
#   * QTS's /tmp is a small tmpfs. TMPDIR is pointed at the package's own
#     data volume for the same reason the Backrest package points it
#     there: a program that spills into /tmp fails with "no space left on
#     device" at the worst possible moment.
#   * The launcher traps SIGTERM and shuts its HTTP server and its SQLite
#     database down in order, so stop) sends SIGTERM and escalates only if
#     it has to.
#   * The Enable check is mandatory: QTS still runs this script at boot
#     even when the app is disabled, and without the check a disabled
#     service gets restarted.
######################################################################

CONF=/etc/config/qpkg.conf
QPKG_NAME="PicoClaw"

QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")

BIN="$QPKG_ROOT/picoclaw-launcher"
CLI="$QPKG_ROOT/picoclaw"
PICHOME="$QPKG_ROOT/home"
DATA="$QPKG_ROOT/data"
LOGDIR="$DATA/log"
LOG="$LOGDIR/picoclaw.log"
CONSOLE="$LOGDIR/console.log"
PIDF="$DATA/picoclaw.pid"

PORT=$(/sbin/getcfg "$QPKG_NAME" Web_Port -d 18800 -f "$CONF")
# Optional: bind the web console to a specific address instead of every
# interface. Empty means -public, i.e. reachable from the LAN.
HOST=$(/sbin/getcfg "$QPKG_NAME" Listen_Host -d "" -f "$CONF")

# 10 MB ceiling; the daily cron job only rotates when this is exceeded.
LOGSZ_MAX=10485760
# Files kept: picoclaw.log, picoclaw.log.1, picoclaw.log.2
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
    grep -q "picoclaw-launcher" "/proc/$_pid/cmdline" 2>/dev/null || return 1
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
        err_msg "launcher missing or not executable: $BIN"
        exit 1
    fi

    # The launcher drives the `picoclaw` CLI (it starts and stops the
    # gateway with it). Without the CLI it would fall back to $PATH and
    # either fail or pick up something else entirely.
    if [ ! -x "$CLI" ]; then
        err_msg "picoclaw CLI missing or not executable: $CLI"
        exit 1
    fi

    mkdir -p "$LOGDIR" "$DATA/tmp" "$PICHOME/logs" "$PICHOME/workspace" || {
        err_msg "cannot create $DATA or $PICHOME"
        exit 1
    }

    # Preserve the previous run's log across restarts. This is NOT the size
    # bound (that is the cron 'rotate' action); it exists so a post-crash
    # log survives the restart that follows it.
    [ -s "$LOG" ] && mv -f "$LOG" "$LOG.1"

    log_msg "starting picoclaw-launcher ($("$CLI" version 2>/dev/null | sed -n 's/^🦞 picoclaw \([^ ]*\).*/\1/p')) on port $PORT"

    # Configuration for the app. All paths are absolute and inside
    # $QPKG_ROOT so they survive a volume migration.
    HOME="$PICHOME"
    PICOCLAW_HOME="$PICHOME"
    PICOCLAW_CONFIG="$PICHOME/config.json"
    PICOCLAW_BINARY="$CLI"
    XDG_CONFIG_HOME="$PICHOME/.config"
    XDG_CACHE_HOME="$PICHOME/.cache"
    # QTS's /tmp is a small tmpfs; keep the app's scratch files on the
    # volume.
    TMPDIR="$DATA/tmp"
    export HOME PICOCLAW_HOME PICOCLAW_CONFIG PICOCLAW_BINARY
    export XDG_CONFIG_HOME XDG_CACHE_HOME TMPDIR

    cd "$QPKG_ROOT" || { err_msg "cannot cd to $QPKG_ROOT"; exit 1; }

    # -console: no GUI, no systray, no browser. -no-browser: the launcher
    # would otherwise try to open a browser, which does not exist on QTS.
    if [ -n "$HOST" ]; then
        set -- -console -no-browser -host "$HOST" --port "$PORT"
    else
        set -- -console -no-browser -public --port "$PORT"
    fi

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
        "$_SETSID" /bin/sh -c 'echo $$ > "$1"; trap "" HUP; shift; exec "$@"' \
            picoclawdetach "$PIDF" "$BIN" "$@" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    elif [ -x /bin/busybox ] && /bin/busybox setsid true >/dev/null 2>&1; then
        _DETACH="busybox-setsid"
        /bin/busybox setsid /bin/sh -c 'echo $$ > "$1"; trap "" HUP; shift; exec "$@"' \
            picoclawdetach "$PIDF" "$BIN" "$@" </dev/null >>"$LOG" 2>>"$CONSOLE" &
    else
        # Last resort. trap "" HUP is exactly what nohup does, but it does NOT
        # create a new session — if QTS kills this process group, the launcher
        # dies with it. Record enough context to diagnose that if it happens.
        _DETACH="trap-hup"
        log_msg "no setsid found; PATH=$PATH"
        /bin/sh -c 'echo $$ > "$1"; trap "" HUP; shift; exec "$@"' \
            picoclawdetach "$PIDF" "$BIN" "$@" </dev/null >>"$LOG" 2>>"$CONSOLE" &
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
            err_msg "picoclaw-launcher exited during startup; see $CONSOLE"
        else
            err_msg "picoclaw-launcher did not become ready within 15s"
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

    # The web console has no password until one is set. The launcher says so
    # on every start; repeat it in the package log, because the console is
    # reachable from the LAN.
    if grep -q 'First-time setup' "$CONSOLE" 2>/dev/null; then
        log_msg "WARNING: no dashboard password yet — open http://<nas>:$PORT/launcher-setup and set one"
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

    # SIGTERM first: the launcher traps it and shuts its HTTP server and its
    # SQLite database down in order.
    kill -TERM "$_pid" 2>/dev/null

    _n=0
    while [ "$_n" -lt 25 ]; do
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
        _n=$((_n + 1))
    done

    if kill -0 "$_pid" 2>/dev/null; then
        err_msg "did not exit on SIGTERM, sending SIGKILL"
        kill -9 "$_pid" 2>/dev/null
        sleep 1
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
    for _f in "$LOG" "$PICHOME"/logs/*.log; do
        [ -f "$_f" ] || continue
        SIZE=$(wc -c < "$_f" 2>/dev/null || echo 0)
        [ "$SIZE" -gt "$LOGSZ_MAX" ] || continue

        _i=$LOG_KEEP
        while [ $_i -gt 1 ]; do
            _prev=$((_i - 1))
            [ -f "$_f.$_prev" ] && mv -f "$_f.$_prev" "$_f.$_i"
            _i=$_prev
        done
        mv -f "$_f" "$_f.1"
        : > "$_f"
        log_msg "rotated $_f ($SIZE bytes)"
    done
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
