#!/usr/bin/env bash
# migrate-common.sh (7.2.0) - what the two moves share: deploy/migrate-layout.sh (the folders, the service, the command) and deploy/migrate-db-name.sh (the data file name). Sourced by both, after deploy/layout.sh.
# The caller sets: P (the test folder, empty on a real box), PREF_DIR, STATE (its journal file), TAG (the word in its lines), and START_EPOCH before the health check.

P="${AQ_ROOT_PREFIX:-}"          # test seam: every file the scripts touch lives under this folder (empty on a real box)
NAP_SEC="${AQ_MIG_NAP:-}"        # test seam: the length of every wait (seconds)
say(){ echo "[${TAG:-MIGRATE}] $*" >&2; }
nap(){ sleep "${NAP_SEC:-$1}"; }
set_state(){   # set_state STATE STEP [REASON]
    mkdir -p "$PREF_DIR" 2>/dev/null || true
    local r="${3:-}"; r="${r//$'\n'/ }"
    printf 'state=%s\nstep=%s\nts=%s\nreason=%s\n' "$1" "${2:-}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$r" > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null || true
}
get_state(){ sed -n 's/^state=//p' "$STATE" 2>/dev/null | tail -n 1; }
state_field(){ sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
# systemd: enable/disable work on the files (and with a test folder, inside it); the rest talks to the running manager
sysd(){ if [ -n "${AQ_MIG_NOBLOCK:-}" ] && [ "${1:-}" = start ]; then shift; systemctl start --no-block "$@"; else systemctl "$@"; fi; }
sysd_files(){ if [ -n "$P" ]; then systemctl --root="$P" "$@"; else systemctl "$@"; fi; }
# failure injection, for the tests only (it is honoured only when a test folder is set): AQ_MIG_FAIL_AT=<step> makes that step fail, AQ_MIG_KILL_AT=<step> ends the script abruptly there
_inject(){
    [ -n "$P" ] || return 0
    [ "${AQ_MIG_KILL_AT:-}" = "$1" ] && kill -9 $$
    [ "${AQ_MIG_FAIL_AT:-}" = "$1" ] && return 1
    return 0
}

# ── the data file, read through the bot's own Python (every box has it; the sqlite3 command is not installed everywhere) ───────────────────────────────────────────────────────────────────────────────────────
mig_python(){ printf '%s' "${AQ_MIG_PYTHON:-$1/venv/bin/python3}"; }      # $1 = the install folder
db_scalar(){   # db_scalar INSTALL_DIR DB "SQL": the first column of the first row, read-only; prints nothing when it cannot be read
    local py; py="$(mig_python "$1")"
    if [ -x "$py" ] || command -v "$py" >/dev/null 2>&1; then
        "$py" - "$2" "$3" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=10)
    r = c.execute(sys.argv[2]).fetchone()
    print("" if r is None else r[0])
except Exception:
    pass
PY
    elif command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -readonly "$2" "$3" 2>/dev/null | head -n 1
    fi
}
pending_orders(){   # pending_orders INSTALL_DIR DB: the number of orders being placed right now (0 when it cannot be read)
    local n; [ -f "$2" ] || { echo 0; return; }
    n="$(db_scalar "$1" "$2" "SELECT COUNT(*) FROM order_intents WHERE status IN ('PENDING','RESOLVING')")"
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}
export QUIET_WHY=""
wait_quiet(){   # wait_quiet INSTALL_DIR DB: 0 when the bot is quiet. An order being placed is waited for a little; a restore waiting for review and a currency switch under way are not waited for (a later window). QUIET_WHY says what is going on.
    local q=0 qmax="${AQ_MIG_QUIET_WAIT:-90}" ph dd; dd="$(dirname "$2")"
    if [ -e "$dd/RESTORE_PENDING" ]; then QUIET_WHY="a restore is waiting for review"; return 1; fi
    ph="$(db_scalar "$1" "$2" "SELECT json_extract(value, '\$.phase') FROM app_settings WHERE key='switch_currency_state'")"
    case "$ph" in pending_restart|winding_down) QUIET_WHY="a currency switch is under way"; return 1 ;; esac
    while [ "$(pending_orders "$1" "$2")" != 0 ]; do
        if [ "$q" -ge "$qmax" ]; then QUIET_WHY="an order is being placed"; return 1; fi
        nap 3; q=$((q + 3))
    done
    return 0
}
layout_ok(){   # the layout file, when there is one, is readable and every line is a comment, a blank or KEY=value (a known key, plain path characters)
    local f line k v; f="$(aq_layout_file)"
    [ -e "$f" ] || return 0
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ""|"#"*) continue ;; esac
        case "$line" in *=*) ;; *) return 1 ;; esac
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in INSTALL_DIR|DATA_DIR|DB_NAME|SERVICE_NAME|CLI_NAME|PREF_DIR|BACKUP_ROOT|LOG_PREFIX|UPDATE_UNIT|NGINX_SITE|SSL_DIR) ;; *) return 1 ;; esac
        case "$v" in ""|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    done < "$f"
    return 0
}
# The folder / data-file names written INSIDE data (.env and the settings table of the data file) are turned into the new ones by the ONE rule in deploy/layout_paths.py (byte for byte core/layout_paths.py, which the
# bot's restore uses too).
paths_python(){ local py; py="$(mig_python "$1")"; if [ -x "$py" ] || command -v "$py" >/dev/null 2>&1; then printf '%s' "$py"; else printf '%s' python3; fi; }
# db_rewrite_settings INSTALL_DIR DB SAVED_JSON TARGET_INSTALL TARGET_DATA TARGET_DB_NAME: prints the number of values changed (the old values are kept in SAVED_JSON for the put-back)
db_rewrite_settings(){
    local py; py="$(paths_python "$1")"
    "$py" "$HERE/layout_paths.py" settings "$2" "$4" "$5" "$6" "$3"
}
db_restore_settings(){   # db_restore_settings INSTALL_DIR DB SAVED_JSON: put the old values back
    local py; py="$(paths_python "$1")"; [ -f "$3" ] || return 0
    "$py" "$HERE/layout_paths.py" restore-settings "$2" "$3" >/dev/null
}
env_rewrite(){   # env_rewrite INSTALL_DIR ENV_FILE TARGET_INSTALL TARGET_DATA TARGET_DB_NAME: prints the number of places changed
    local py; py="$(paths_python "$1")"
    "$py" "$HERE/layout_paths.py" env "$2" "$3" "$4" "$5" 2>/dev/null
}

# ── the start guard: while a move is under way the service cannot start, and a one-shot unit puts an interrupted move right at boot ──────────────────────────────────────────────────────────────────────
# (the caller sets GUARD_NAMES = the unit names to guard, UNIT_DIR, PREF_DIR, HERE)
guard_file(){ printf '%s' "$PREF_DIR/migration-in-progress"; }
RECOVER_UNIT="${LAY_NEW_SERVICE}-migrate-recover"
guard_dropins(){      # [Unit] ConditionPathExists=!<guard file> for every name of the service (also its alias): the unit is skipped while the file exists
    local n g; g="$(guard_file)"; g="${g#"$P"}"
    for n in $GUARD_NAMES; do
        mkdir -p "$UNIT_DIR/$n.service.d" && printf '[Unit]\nConditionPathExists=!%s\n' "$g" > "$UNIT_DIR/$n.service.d/00-aq-migrating.conf" || return 1
    done
}
write_recover_script(){      # $1 = file: run at boot by the one-shot unit
    cat > "$1" <<'RECOVER'
#!/usr/bin/env bash
# Run at boot by the one-shot unit that exists only while a move is under way: an interrupted move is put back BEFORE the service starts, from this copy of the scripts (outside the folders that move).
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$H/layout.sh"
export TAG="MIGRATE-RECOVER"
# shellcheck source=migrate-common.sh
. "$H/migrate-common.sh"
PREF_DIR="${AQ_PREF_DIR:-$P$LAY_PREF_DIR}"; UNIT_DIR="${AQ_UNIT_DIR:-$P/etc/systemd/system}"
GUARD_NAMES="$LAY_LEGACY_SERVICE $LAY_NEW_SERVICE"
export AQ_MIG_NOBLOCK=1      # this runs before the service starts: a start is queued, never waited for
for s in migrate-db-name migrate-layout; do
    if [ "$(sed -n 's/^state=//p' "$PREF_DIR/$s.state" 2>/dev/null | tail -n 1)" = running ]; then
        say "an earlier move was cut short - putting it right before the service starts"
        bash "$H/$s.sh"
    fi
done
# nothing is left to put right (or it has been): the guard and this one-shot unit go
guard_off
case "$H" in "$PREF_DIR"/migrate-scripts) cd / && rm -rf "$H" ;; esac
exit 0
RECOVER
}
guard_on(){      # idempotent; puts the guard file, the drop-ins for both unit names, a copy of the scripts outside the moving folders and the one-shot recovery unit
    mkdir -p "$PREF_DIR" || return 1
    local sd="$PREF_DIR/migrate-scripts" g; g="$sd"; g="${g#"$P"}"
    if ! [ "$HERE" -ef "$sd" ]; then rm -rf "$sd"; mkdir -p "$sd" && cp -a "$HERE/." "$sd/" || return 1; fi
    write_recover_script "$sd/recover.sh" || return 1
    : > "$(guard_file)" || return 1
    guard_dropins || return 1
    printf '[Unit]\nDescription=Put an interrupted move to the new names right before the service starts\nAfter=local-fs.target\nBefore=%s\n\n[Service]\nType=oneshot\nExecStart=/bin/bash %s/recover.sh\n\n[Install]\nWantedBy=multi-user.target\n' \
        "$(for n in $GUARD_NAMES; do printf '%s.service ' "$n"; done)" "$g" > "$UNIT_DIR/$RECOVER_UNIT.service" || return 1
    sysd_files enable "$RECOVER_UNIT" >/dev/null 2>&1
    sysd daemon-reload 2>/dev/null
    return 0
}
guard_lift(){ rm -f "$(guard_file)"; }      # the state is whole again: the service may start (the drop-ins and the recovery unit stay until the move is finished, so a crash from here on is still put right at boot)
guard_off(){      # the move is finished or has been put back
    local n
    for n in $GUARD_NAMES; do
        rm -f "$UNIT_DIR/$n.service.d/00-aq-migrating.conf"
        rmdir "$UNIT_DIR/$n.service.d" 2>/dev/null
    done
    sysd_files disable "$RECOVER_UNIT" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$RECOVER_UNIT.service" "$(guard_file)"
    sysd daemon-reload 2>/dev/null
    return 0
}
scripts_cleanup(){ local sd="$PREF_DIR/migrate-scripts"; if ! [ "$HERE" -ef "$sd" ]; then rm -rf "$sd"; fi; }

# when both the old and the new name of the data file exist (a start between the rename and the layout write made an empty one), the REAL one is kept: more rows, then the larger file, then the renamed one.
# The other is put aside as <name>.empty-<time>; nothing is ever overwritten or discarded. settle_pair INSTALL_DIR OLD_PATH NEW_PATH TIMESTAMP -> the real one ends under OLD_PATH
db_rows_total(){
    local py; py="$(paths_python "$1")"
    "$py" - "$2" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=10)
    t = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    print(sum(c.execute('SELECT COUNT(*) FROM "%s"' % x).fetchone()[0] for x in t))
except Exception:
    print(-1)
PY
}
settle_pair(){
    local inst="$1" a="$2" b="$3" ts="$4" ra rb sa sb real other suf
    [ -e "$a" ] && [ -e "$b" ] || return 0
    ra="$(db_rows_total "$inst" "$a")"; rb="$(db_rows_total "$inst" "$b")"; sa="$(stat -c %s "$a")"; sb="$(stat -c %s "$b")"
    real="$b"; other="$a"
    if [ "$ra" -gt "$rb" ] || { [ "$ra" = "$rb" ] && [ "$sa" -gt "$sb" ]; }; then real="$a"; other="$b"; fi
    for suf in "" -wal -shm; do [ -e "$other$suf" ] && mv "$other$suf" "$other.empty-$ts$suf"; done
    say "both names of the data file existed: kept the one with the data ($(basename "$real")), put the other aside as $(basename "$other").empty-$ts"
    if [ "$real" = "$b" ]; then for suf in "" -wal -shm; do [ -e "$b$suf" ] && mv "$b$suf" "$a$suf"; done; fi
    return 0
}

same_fs(){   # a folder that is its own mount cannot be renamed into its parent's file system
    local d="$1" par; par="$(dirname "$1")"
    [ "$(stat -c %d "$d" 2>/dev/null)" = "$(stat -c %d "$par" 2>/dev/null)" ]
}
verify_unit(){   # the real checker of systemd, when this box has it (a test folder is its root: the unit is checked there by name, from the folder systemd reads at run time)
    command -v systemd-analyze >/dev/null 2>&1 || return 0
    if [ -z "$P" ]; then systemd-analyze verify "$1" >/dev/null 2>&1; return; fi
    local n d rc; n="$(basename "$1")"; d="$P/run/systemd/system"
    mkdir -p "$d" && cp "$1" "$d/$n" || return 1
    systemd-analyze --root="$P" verify "$n" >/dev/null 2>&1; rc=$?
    rm -f "$d/$n"; return $rc
}

# ── the health check: the service stays active, the dashboard answers, the running marker is fresh, the log shows no [FATAL] ──────────────────────────────────────────────────────────────────────────────
dash_port(){ local p; p="$(grep -E '^DASHBOARD_PORT=' "$1/.env" 2>/dev/null | tail -n 1 | cut -d= -f2 | tr -d '"'"'"' \r')"; [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" || echo 5005; }
dash_answers(){ local c; c="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "${AQ_MIG_HEALTH_URL:-http://127.0.0.1:$(dash_port "$1")/}" 2>/dev/null)"; [ -n "$c" ] && [ "$c" != 000 ]; }
marker_fresh(){   # marker_fresh DATA_DIR: the bot wrote its running marker after this run began
    local t; t="$(sed -n 's/.*"ts": *\([0-9]*\).*/\1/p' "$1/running.marker" 2>/dev/null | head -n 1)"
    [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge "$START_EPOCH" ]
}
log_fatal(){      # log_fatal SERVICE: a [FATAL] line in its log since the start
    command -v journalctl >/dev/null 2>&1 || return 1
    journalctl -u "$1" --since "$(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S')" --no-pager -q 2>/dev/null | grep -qF '[FATAL]'
}
mig_health(){   # mig_health SERVICE DATA_DIR HAD_MARKER(0|1): 0 when healthy
    local svc="$1" dd="$2" had="$3" need="${AQ_MIG_HEALTH_CHECKS:-6}" max="${AQ_MIG_HEALTH_MAX:-24}" i good=0 dash=0 mark=0
    for ((i=1; i<=max; i++)); do
        nap 5
        sysd is-active --quiet "$svc" || { say "the service is not active"; return 1; }
        if log_fatal "$svc"; then say "the log shows [FATAL]"; return 1; fi
        good=$((good + 1))
        dash_answers "$dd" && dash=1
        if [ "$had" = 0 ] || marker_fresh "$dd"; then mark=1; fi
        if [ "$good" -ge "$need" ] && [ "$dash" = 1 ] && [ "$mark" = 1 ]; then return 0; fi
    done
    [ "$dash" = 1 ] || say "the dashboard did not answer"
    [ "$mark" = 1 ] || say "the running marker is not fresh"
    return 1
}
