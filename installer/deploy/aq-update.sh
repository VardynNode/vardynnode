#!/usr/bin/env bash
###############################################################################
# aq-update.sh — ApexQuant self-updater + auto-update manager (signature-verified).
#
#   Update now + offer auto-update:  curl -fsSL https://get.vardynnode.com/update | sudo bash
#   Configure auto-update only:      curl -fsSL https://get.vardynnode.com/update | sudo bash -s -- --setup
#   (serving: vardynnode.com; the origins are listed in ORIGINS below and tried in that order)
#   Enable / Disable:                sudo aq-update.sh --enable | --disable
#
# SECURITY: this script verifies ITS OWN minisign signature (same pinned key as the
# installer) before ever installing or exec'ing a refreshed copy — a compromised
# origin/CDN cannot push root code to the fleet. The actual update is done by the
# product's own install.sh --update, which minisign-verifies the dist. Fail-closed.
#
# The pinned minisign public key is embedded (identical to get-apexquant.sh).
# The pinned key is embedded below — nothing to install on customer boxes.
###############################################################################
set -uo pipefail

# ── ORIGINS (the ONE place the download domains are named; 7.1.2) ──────────────────────────────────────────────────────────────────────────────────────────
# Serving: vardynnode.com (website, installer, updater, downloads, ping). Backend (licence/AQL): apexquant.tech - it is not a serving origin any more. Two ordered lists, tried in this order;
# a network or HTTP failure of one origin moves on to the next. This list (and the one in get-apexquant.sh) is the one place an origin is named.
#   GET origins : the updater itself (/update, /update.minisig)
#   SITE origins: the package (/files/ApexQuant-Setup.zip, .sha256, .minisig) and the update ping (/update/ping)
# The package's checksum, zip and signature always come from the SAME origin (never mixed). The signature check is the same pinned key whatever the origin; a bad signature moves on to the next origin or fails closed.
GET_ORIGINS="${AQ_GET_ORIGINS:-https://get.vardynnode.com}"
SITE_ORIGINS="${AQ_SITE_ORIGINS:-https://vardynnode.com}"
# The older single-URL settings still work as overrides: when one is set it is the only URL used for that item (no fallback for it).
INSTALLER_URL="${AQ_INSTALLER_URL:-}"
UPDATER_URL="${AQ_UPDATER_URL:-}"
UPDATER_SIG_URL="${AQ_UPDATER_SIG_URL:-}"
SHA_URL="${AQ_SHA_URL:-}"
DIST_URL="${AQ_DIST_URL:-}"
ZIP_SIG_URL="${AQ_ZIP_SIG_URL:-}"
PING_URL="${AQ_PING_URL:-}"
# The install layout (7.1.4): the same block as deploy/layout.sh, copied verbatim because this file is served on its own; a gate test compares the copies.
# >>> AQ-LAYOUT
_aq_lay() {   # _aq_lay KEY DEFAULT
    local v=""
    if [ -r "${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}" ]; then
        v="$(sed -n "s/^$1=//p" "${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}" 2>/dev/null | tail -n 1 | tr -d '\r')"
    fi
    case "$v" in
        ""|*[!A-Za-z0-9_./-]*) v="$2" ;;
    esac
    printf '%s' "$v"
}
_aq_layout_load() {   # (7.2.0: a function, so a script can load the layout again after it has written a layout file)
    export LAY_INSTALL_DIR; LAY_INSTALL_DIR="$(_aq_lay INSTALL_DIR /root/ApexQuant)"
    export LAY_DATA_DIR; LAY_DATA_DIR="$(_aq_lay DATA_DIR /root/apexquant-data)"
    export LAY_DB_NAME; LAY_DB_NAME="$(_aq_lay DB_NAME apexquant.db)"
    export LAY_SERVICE; LAY_SERVICE="$(_aq_lay SERVICE_NAME apexquant)"
    export LAY_CLI; LAY_CLI="$(_aq_lay CLI_NAME apexquant)"
    export LAY_PREF_DIR; LAY_PREF_DIR="$(_aq_lay PREF_DIR /var/lib/apexquant)"
    export LAY_BACKUP_ROOT; LAY_BACKUP_ROOT="$(_aq_lay BACKUP_ROOT /var/backups/apexquant)"
    export LAY_LOG_PREFIX; LAY_LOG_PREFIX="$(_aq_lay LOG_PREFIX /root/apexquant-)"
    export LAY_UPDATE_UNIT; LAY_UPDATE_UNIT="$(_aq_lay UPDATE_UNIT apexquant-update)"
    export LAY_NGINX_SITE; LAY_NGINX_SITE="$(_aq_lay NGINX_SITE apexquant)"
    export LAY_SSL_DIR; LAY_SSL_DIR="$(_aq_lay SSL_DIR /etc/ssl/apexquant)"
    export LAY_OLD_DIR="${LAY_INSTALL_DIR}_old"
    export LAY_CLI_PATH="/usr/local/bin/${LAY_CLI}"
}
_aq_layout_load
# The names before the folder rename (LEGACY: what a box without a layout file has) and after it (NEW: what a fresh install writes first and the migration writes). The other names (the data file, the state,
# backup and update-unit names, the nginx site) are the same in both.
export LAY_LEGACY_INSTALL_DIR=/root/ApexQuant LAY_LEGACY_DATA_DIR=/root/apexquant-data LAY_LEGACY_DB_NAME=apexquant.db LAY_LEGACY_SERVICE=apexquant LAY_LEGACY_CLI=apexquant LAY_LEGACY_LOG_PREFIX=/root/apexquant-
export LAY_NEW_INSTALL_DIR=/root/VardynNode LAY_NEW_DATA_DIR=/root/vardynnode-data LAY_NEW_DB_NAME=vardynnode.db LAY_NEW_SERVICE=vardynnode LAY_NEW_CLI=vardynnode LAY_NEW_LOG_PREFIX=/root/vardynnode-
_aq_new_layout_text() {   # the content of the layout file of the new names (a fresh install writes the whole of it; the folder move writes it with "keepdb", the data file keeping its old name until deploy/migrate-db-name.sh renames it)
    printf '%s\n' "# The install layout (read by the bot and the scripts: core/layout.py, deploy/layout.sh). One KEY=VALUE per line." "INSTALL_DIR=$LAY_NEW_INSTALL_DIR" "DATA_DIR=$LAY_NEW_DATA_DIR"
    [ "${1:-}" = keepdb ] || printf '%s\n' "DB_NAME=$LAY_NEW_DB_NAME"
    printf '%s\n' "SERVICE_NAME=$LAY_NEW_SERVICE" "CLI_NAME=$LAY_NEW_CLI" "LOG_PREFIX=$LAY_NEW_LOG_PREFIX"
}
_aq_is_fresh_box() {   # no layout file, no old or new install (a venv), no old or new data folder: a box that has never had the bot
    local r="${AQ_ROOT_PREFIX:-}"
    [ ! -e "${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}" ] && [ ! -e "$r$LAY_LEGACY_DATA_DIR" ] && [ ! -e "$r$LAY_LEGACY_INSTALL_DIR/venv" ] && [ ! -e "$r$LAY_NEW_DATA_DIR" ] && [ ! -e "$r$LAY_NEW_INSTALL_DIR/venv" ]
}
_aq_adopt_new_layout() {   # [keepdb]: write the layout file of the new names (atomically) and load it; fails when a layout file already exists
    local f="${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}"
    [ ! -e "$f" ] || return 1
    mkdir -p "$(dirname "$f")" || return 1
    _aq_new_layout_text "${1:-}" > "$f.tmp.$$" || { rm -f "$f.tmp.$$"; return 1; }
    chmod 644 "$f.tmp.$$"
    mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
    _aq_layout_load
}
_aq_layout_absent() { [ ! -e "${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}" ]; }      # (7.3.36: the path of the layout file is written only in the layout block)
_aq_layout_remove() { rm -f "${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}"; }
# <<< AQ-LAYOUT
INSTALL_DIR="${AQ_INSTALL_DIR:-${AQ_ROOT_PREFIX:-}$LAY_INSTALL_DIR}"      # (AQ_ROOT_PREFIX: a test folder as the root of the box; empty on a real box)
DATA_DIR="${AQ_DATA_DIR:-${AQ_ROOT_PREFIX:-}$LAY_DATA_DIR}"          # installer's DATA_DIR (live DB lives here)
DB_PATH="${AQ_DB_PATH:-$DATA_DIR/$LAY_DB_NAME}"          # bot DB (positions table)
SERVICE="${AQ_SERVICE:-$LAY_SERVICE}"
HEALTH_URL="${AQ_HEALTH_URL:-}"                          # HTTP probe opt-in; default = systemctl is-active
REQUIRED_PYTHON="${AQ_REQUIRED_PYTHON:-python3.12}"
SELF_PATH="${AQ_SELF_PATH:-/usr/local/bin/aq-update.sh}"
PREF_DIR="${AQ_PREF_DIR:-$LAY_PREF_DIR}"; PREF_FILE="$PREF_DIR/auto-update"; SHA_STATE="$PREF_DIR/installed.sha256"
DEFER_FILE="$PREF_DIR/deferrals"                         # consecutive windows an update was held back for open positions
MAX_DEFERRALS="${AQ_MAX_DEFERRALS:-3}"
UNIT_DIR="${AQ_UNIT_DIR:-/etc/systemd/system}"
BACKUP_ROOT="${AQ_BACKUP_ROOT:-$LAY_BACKUP_ROOT}"
KEEP_SNAPSHOTS="${AQ_KEEP_SNAPSHOTS:-3}"                  # 6.16.58: the newest updater snapshots that stay (the bot reads the same defaults: core/retention.py)
KEEP_COPIES="${AQ_KEEP_COPIES:-2}"                        # 6.16.58: the newest previous installs that stay
# Pinned minisign public key — embedded (same value as get-apexquant.sh). It travels
# WITH this script, so there is NOTHING to install on customer boxes.
MINISIGN_PUB="RWRHtMOGHSz0oywqtMdW5cQkw2UE1llujBPPnUFkW1RGaz9qRFZHZKSj"
LOG="${AQ_LOG:-/var/log/aq-update.log}"; LOCK="${AQ_LOCK:-/var/lock/aq-update.lock}"
PRESERVE=(".env" ".aql_key" ".aql_install")      # 6.16.61 (H1): license/aql_pubkey.py is NOT kept across an update: the package carries the key the release build trusts, and its copy is the one installed (install.sh adopt_package_pubkey)
SKIP_ON_OPEN="${AQ_SKIP_ON_OPEN_POSITIONS:-1}"          # LIVE: defer update while positions are open
ZIP_NAMES="${AQ_ZIP_NAMES:-VardynNode-Setup.zip ApexQuant-Setup.zip}"      # 7.2.0: the package is published under both names (copies, each with its own checksum and signature); the new name is tried first at each origin, the old name is the fallback. Older updaters only know the old one
MIGRATE_OPTOUT="$PREF_DIR/no-migrate-layout"             # 7.2.0: this file keeps the box on the old folder names (apexquant --no-migrate-layout makes it)

log(){ echo "$(date -u '+%F %T') UTC  $*" | tee -a "$LOG" >&2; }
die(){ log "ERROR: $*"; _write_status failed "$*"; exit 1; }      # 6.16.56: a failed run says so on the dashboard (it kept showing the last "success")
warn(){ log "WARN: $*"; }
_write_status(){   # $1=state  $2=detail  — durable handoff to the bot dashboard (decoupled). 7.3.36 (install F6): written with python3's own sqlite3 module (the sqlite3 command-line tool is not installed on a fresh server)
    [ -n "${DB_PATH:-}" ] && command -v python3 >/dev/null 2>&1 || return 0
    AQ_ST="${1:-}" AQ_DT="${2:-}" AQ_FV="${_from_ver:-}" AQ_TV="${_target_ver:-}" AQ_PKG="$(short "${REMOTE_SHA:-}")" AQ_TS="$(date -u '+%Y-%m-%d %H:%M:%S')" python3 - "$DB_PATH" <<'PYST' 2>/dev/null || true
import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=10)
c.execute("CREATE TABLE IF NOT EXISTS update_status(id INTEGER PRIMARY KEY CHECK(id=1), state TEXT, detail TEXT, from_ver TEXT, to_ver TEXT, pkg TEXT, ts_utc TEXT)")
c.execute("INSERT INTO update_status(id,state,detail,from_ver,to_ver,pkg,ts_utc) VALUES(1,?,?,?,?,?,?) "
          "ON CONFLICT(id) DO UPDATE SET state=excluded.state, detail=excluded.detail, from_ver=excluded.from_ver, to_ver=excluded.to_ver, pkg=excluded.pkg, ts_utc=excluded.ts_utc",
          (os.environ["AQ_ST"], os.environ["AQ_DT"], os.environ["AQ_FV"], os.environ["AQ_TV"], os.environ["AQ_PKG"], os.environ["AQ_TS"]))
c.commit()
c.close()
PYST
}
_fail_banner(){   # $1 = state: "restored" | "manual"
    printf "\n\033[31m===================================================\n" >&2
    printf "  \342\234\226 UPDATE FAILED\n" >&2
    printf "  Attempted: VardynNode %s (%s)\n" "${_target_ver:-new version}" "$(short "${REMOTE_SHA:-unknown}")" >&2
    printf "  Time: %s  (%s)\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(date -u '+%Y-%m-%d %H:%M UTC')" >&2
    printf "\n" >&2
    if [ "$1" = "restored" ]; then
        printf "  Your previous version was restored and the bot is\n" >&2
        printf "  running normally. Your funds and settings are safe.\n" >&2
        printf "  Your trading carries on as normal; the update is tried again next time.\n" >&2
    else
        printf "  \342\232\240 The bot is NOT running. Action required:\n" >&2
        printf "    1) Check status:  systemctl status %s\n" "$SERVICE" >&2
        printf "    2) View the log:  tail -n 50 %s\n" "$LOG" >&2
        printf "    3) Email that log to hello@vardynnode.com for help.\n" >&2
    fi
    printf "===================================================\033[0m\n\n" >&2
}
short(){ local s="${1:-}"; [ -n "$s" ] && printf '%s' "${s:0:12}" || printf 'none'; }
[ "$(id -u)" = 0 ] || [ -n "${AQ_TEST_NONROOT:-}" ] || die "must run as root"
cd /root 2>/dev/null || cd / 2>/dev/null || true   # never run from inside the dir we rename
mkdir -p "$(dirname "$LOG")" "$PREF_DIR"
command -v curl >/dev/null || die "curl not found"

load_pref(){ cat "$PREF_FILE" 2>/dev/null || echo ""; }
save_pref(){ echo "$1" > "$PREF_FILE"; }
have_tty(){ { exec 3</dev/tty; } 2>/dev/null; }

# ── H1: verify a file's minisign signature with the pinned key (fail-closed) ──
verify_sig(){   # $1=file  $2=sigfile  → 0 only if signature valid under the pinned key
    local pk="$MINISIGN_PUB"
    case "$pk" in RWQREPLACE_*|"" ) log "minisign pubkey not embedded — refusing unsigned self-update"; return 1;; esac
    if ! command -v minisign >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq minisign >/dev/null 2>&1 || true
    fi
    command -v minisign >/dev/null 2>&1 || { log "minisign not installed and could not install — refusing unsigned self-update"; return 1; }
    [ -s "$1" ] && [ -s "$2" ] || return 1
    minisign -Vm "$1" -P "$pk" -x "$2" >/dev/null 2>&1
}

# the package download: curl's own progress meter when a person is watching (stderr is a terminal), quiet otherwise (the timer's log stays clean); the exit status is what the origin loop relies on
zip_fetch(){ if [ -t 2 ]; then curl -fSL --retry 3 --max-time 300 "$1" -o "$2"; else curl -fSL --retry 3 --max-time 300 "$1" -o "$2" 2>/dev/null; fi; }
# the host of a URL, for the one plain line that says which origin served a file
origin_of(){ local u="${1#*://}"; printf '%s' "${u%%/*}"; }
# the URLs of the updater to try, in order: an override, else every GET origin
updater_urls(){
    if [ -n "$UPDATER_URL" ]; then printf '%s\n' "$UPDATER_URL"
    elif [ -n "$INSTALLER_URL" ]; then printf '%s\n' "$INSTALLER_URL/update"
    else local o; for o in $GET_ORIGINS; do printf '%s\n' "$o/update"; done; fi
}
# fetch updater + its .minisig (from the SAME origin) to temp, verify, then print the verified temp path (or nothing); the next origin is tried when one fails or does not verify
VERIFIED_UPD=""
fetch_verified_updater(){
    local tmp sig u su; tmp="$(mktemp)"; sig="$(mktemp)"; VERIFIED_UPD=""
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        su="${UPDATER_SIG_URL:-$u.minisig}"
        if curl -fsSL --max-time 30 "$u" -o "$tmp" 2>/dev/null \
           && curl -fsSL --max-time 30 "$su" -o "$sig" 2>/dev/null \
           && [ -s "$tmp" ] && bash -n "$tmp" 2>/dev/null && verify_sig "$tmp" "$sig"; then
            rm -f "$sig"; VERIFIED_UPD="$tmp"
            [ -n "${AQ_UPD_SERVED:-}" ] || { log "updater copy served by $(origin_of "$u")" >&2; export AQ_UPD_SERVED=1; }
            return 0
        fi
        log "updater copy from $(origin_of "$u") not usable (unreachable, missing or not correctly signed) — trying the next origin" >&2
    done < <(updater_urls)
    rm -f "$tmp" "$sig"; return 1
}

install_self(){
    [ "$(readlink -f "$0" 2>/dev/null || echo)" = "$SELF_PATH" ] && return 0
    # run from a real local file → trust the local copy
    if [ -f "$0" ] && install -m 0755 "$0" "$SELF_PATH" 2>/dev/null; then return 0; fi
    # piped bootstrap: prefer a signature-verified copy...
    local v; if fetch_verified_updater; then v="$VERIFIED_UPD"; install -m 0755 "$v" "$SELF_PATH"; rm -f "$v"; return 0; fi
    # ...else fall back to TLS-only (trust-on-first-use; this run is user-initiated, same trust as the
    # installer). The AUTOMATIC self_refresh stays signature-strict, so the timer never execs unsigned.
    log "WARN: no signature-verified aq-update.sh (is /update.minisig published + re-signed?) — installing over TLS only (trust-on-first-use)"
    local tmp u; tmp="$(mktemp)"
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        if curl -fsSL --max-time 30 "$u" -o "$tmp" 2>/dev/null && [ -s "$tmp" ] && bash -n "$tmp" 2>/dev/null; then
            install -m 0755 "$tmp" "$SELF_PATH"; rm -f "$tmp"; return 0
        fi
    done < <(updater_urls)
    rm -f "$tmp"; die "could not obtain aq-update.sh (network?)"
}

self_refresh(){
    [ "${AQ_SELF_REFRESHED:-0}" = 1 ] && return 0; [ -f "$SELF_PATH" ] || return 0
    local v; fetch_verified_updater || { log "self-refresh skipped (no verified newer copy)"; return 0; }
    v="$VERIFIED_UPD"
    if ! cmp -s "$v" "$SELF_PATH"; then
        install -m 0755 "$v" "$SELF_PATH"; rm -f "$v"
        log "updater self-refreshed (signature-verified) — re-exec"; AQ_SELF_REFRESHED=1 exec "$SELF_PATH" "$@"
    fi
    rm -f "$v"
}

write_units(){
    mkdir -p "$UNIT_DIR"
    cat > $UNIT_DIR/${LAY_UPDATE_UNIT}.service <<UNIT
[Unit]
Description=VardynNode unattended version update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF_PATH
UNIT
    cat > $UNIT_DIR/${LAY_UPDATE_UNIT}.timer <<UNIT
[Unit]
Description=Check for VardynNode updates daily

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
}
enable_auto(){  install_self; write_units; systemctl enable --now ${LAY_UPDATE_UNIT}.timer; save_pref on;  log "auto-update ENABLED (daily ~04:30 +jitter)"; }
disable_auto(){ install_self; systemctl disable --now ${LAY_UPDATE_UNIT}.timer 2>/dev/null || true
    rm -f $UNIT_DIR/${LAY_UPDATE_UNIT}.timer $UNIT_DIR/${LAY_UPDATE_UNIT}.service
    systemctl daemon-reload; save_pref off; log "auto-update DISABLED"; }

prompt_pref(){
    local cur ans def hint; cur="$(load_pref)"; def="${cur:-on}"
    if have_tty; then [ "$def" = on ] && hint="[Y/n]" || hint="[y/N]"
        printf "\nEnable automatic daily updates for VardynNode? %s " "$hint" >/dev/tty
        read -r ans <&3 || ans=""; [ -n "$ans" ] || ans="$([ "$def" = on ] && echo y || echo n)"
    else ans="$([ "$def" = on ] && echo y || echo n)"; fi
    if [[ "$ans" =~ ^[Yy] ]]; then enable_auto;  { echo "✓ Automatic updates ON.  Off any time: sudo aq-update.sh --disable" >/dev/tty; } 2>/dev/null || true
    else disable_auto; { echo "✓ Automatic updates OFF. Update manually: curl -fsSL $(updater_urls | head -1) | sudo bash" >/dev/tty; } 2>/dev/null || true; fi
}

# fingerprint = name+size (content-change signal); installer swaps also detected via .OLD.
# (mtime deliberately excluded so an identical re-extract is not counted as a change.)
fingerprint(){ find "$INSTALL_DIR" -type f -printf '%P %s\n' 2>/dev/null | sort | sha256sum | awk '{print $1}'; }
newest_old(){ ls -dt ${INSTALL_DIR}.OLD-* 2>/dev/null | head -1 || true; }
# The package "units": one line per origin, "sha-url dist-url signature-url", in order. An explicit override of any of the three URLs makes ONE unit from the overrides (the first site origin fills the others).
build_units(){
    UNITS=()
    if [ -n "$SHA_URL$DIST_URL$ZIP_SIG_URL" ]; then
        local o1="${SITE_ORIGINS%% *}"
        local d="${DIST_URL:-$o1/files/ApexQuant-Setup.zip}"
        UNITS+=("${SHA_URL:-$o1/files/ApexQuant-Setup.zip.sha256} $d ${ZIP_SIG_URL:-$d.minisig}")
    else
        local o z; for o in $SITE_ORIGINS; do for z in $ZIP_NAMES; do UNITS+=("$o/files/$z.sha256 $o/files/$z $o/files/$z.minisig"); done; done
    fi
}
# the published checksum of one origin: 64 hex characters or nothing (a page that is not a checksum is a failure of that origin)
fetch_sha(){ local s; s="$(curl -fsSL --max-time 20 "$1" 2>/dev/null | tr -d '\r' | awk 'NF{print $1;exit}' | tr 'A-F' 'a-f')"; [[ "$s" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$s"; }
# the first origin that answers with a checksum: sets REMOTE_SHA and UNIT_NO (empty/0 when none does)
select_unit(){
    REMOTE_SHA=""; UNIT_NO=0
    local i u s; build_units
    for ((i=0; i<${#UNITS[@]}; i++)); do
        read -r u _ <<< "${UNITS[$i]}"
        if s="$(fetch_sha "$u")" && [ -n "$s" ]; then REMOTE_SHA="$s"; UNIT_NO=$i; return 0; fi
        log "checksum from $(origin_of "$u") not available — trying the next origin"
    done
    return 1
}
ping_update(){
    if [ -n "$PING_URL" ]; then curl -fsS --max-time 8 "${PING_URL}?v=${1:-applied}" >/dev/null 2>&1 || true; return 0; fi
    local o; for o in $SITE_ORIGINS; do curl -fsS --max-time 8 "$o/update/ping?v=${1:-applied}" >/dev/null 2>&1 && return 0; done; return 0
}

# L3/U1 + U4: defer (at most MAX_DEFERRALS windows in a row) if the LIVE bot holds open positions — counted directly from the
# positions table (closed rows are deleted, so COUNT(*) = open). Fail-open if the
# mode/db/sqlite can't be determined (never block updates on an unknown).
positions_open(){
    [ "$SKIP_ON_OPEN" = 1 ] || return 1
    command -v python3 >/dev/null 2>&1 || { log "python3 not available — cannot check open positions; proceeding"; return 1; }
    [ -f "$DB_PATH" ] || return 1
    # 7.3.36 (install F6): python3's own sqlite3 module (the sqlite3 command-line tool is not installed on a fresh server), and the mode is read the way the bot reads it: the saved settings first (the dashboard's
    # "go LIVE" writes them there), then .env
    local n; n="$(python3 - "$DB_PATH" "$INSTALL_DIR/.env" <<'PYPO' 2>/dev/null || echo ''
import sqlite3, sys
db, env = sys.argv[1], sys.argv[2]
mode = ""
c = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
try:
    r = c.execute("SELECT value FROM app_settings WHERE key='TRADING_MODE'").fetchone()
    mode = (r[0] if r and r[0] else "") or ""
except Exception:
    mode = ""
if not str(mode).strip():
    try:
        for ln in open(env, encoding="utf-8", errors="ignore"):
            if ln.startswith("TRADING_MODE="):
                mode = ln.split("=", 1)[1].strip()
    except Exception:
        pass
mode = str(mode).strip().strip('"').strip("'").upper()
if mode != "LIVE":
    print("NOTLIVE")
else:
    print(int(c.execute("SELECT COUNT(*) FROM positions").fetchone()[0]))
PYPO
)"
    [ "$n" = "NOTLIVE" ] && return 1
    [[ "$n" =~ ^[0-9]+$ ]] || { log "could not read positions table — proceeding"; return 1; }
    [ "$n" -gt 0 ]
}

# M2 + U3: snapshot config AND the real DB (DATA_DIR); returns the snapshot dir via stdout. Called AFTER the service is stopped. The data files are
# copied with SQLite's own online-backup command (consistent even if a writer were still running); without the sqlite3 tool the files are copied
# with their -wal/-shm companions (the service is stopped, so the set is consistent).
# 6.16.58: ONE retention rule: keep the newest $KEEP_SNAPSHOTS of the updater's snapshots (config-*), the newest $KEEP_COPIES previous installs (.OLD-*) and 1 failed one (.failed-*). Never the live data file or install,
# never called during a rollback. A run that finds nothing new makes no snapshot (it ends before the staging step).
prune_copies(){
    local s="$KEEP_SNAPSHOTS" n="$KEEP_COPIES"; [[ "$s" =~ ^[1-9][0-9]*$ ]] || s=3; [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=2
    ls -dt "$BACKUP_ROOT"/config-* 2>/dev/null | tail -n +$((s+1)) | xargs -r rm -rf
    ls -dt ${INSTALL_DIR}.OLD-* 2>/dev/null | tail -n +$((n+1)) | xargs -r rm -rf
    ls -dt ${INSTALL_DIR}.failed-* 2>/dev/null | tail -n +2 | xargs -r rm -rf
}
make_snapshot(){
    local snap="$BACKUP_ROOT/config-$1"; mkdir -p "$snap"
    ( cd "$INSTALL_DIR" && for f in "${PRESERVE[@]}"; do [ -e "$f" ] && { mkdir -p "$snap/$(dirname "$f")"; cp -a "$f" "$snap/$f"; }; done ) 2>/dev/null || true
    if [ -d "$DATA_DIR" ]; then
        mkdir -p "$snap/data"
        local db b
        for db in "$DATA_DIR"/*.db; do
            [ -e "$db" ] || continue; b="$(basename "$db")"
            if command -v sqlite3 >/dev/null 2>&1 && sqlite3 "$db" ".backup '$snap/data/$b'" 2>/dev/null; then :
            else cp -a "$db" "$db-wal" "$db-shm" "$snap/data/" 2>/dev/null || cp -a "$db" "$snap/data/" 2>/dev/null || true; fi
        done
    fi
    ( cd "$INSTALL_DIR" && cp -a ./*.db "$snap/" 2>/dev/null || true )
    printf '%s' "$snap"
}
restore_config(){   # $1 = snapshot dir
    local snap="$1"
    ( cd "$INSTALL_DIR" && for f in "${PRESERVE[@]}"; do
        [ ! -e "$f" ] && [ -e "$snap/$f" ] && { mkdir -p "$(dirname "$f")"; cp -a "$snap/$f" "$f"; log "restored missing $f"; }; done ) 2>/dev/null || true
    if [ -d "$DATA_DIR" ] && [ -d "$snap/data" ]; then
        for db in "$snap/data"/*.db; do [ -e "$db" ] || continue; b="$(basename "$db")"; [ -e "$DATA_DIR/$b" ] || { cp -a "$db" "$DATA_DIR/$b"; log "restored missing DB $b"; }; done
    fi
}

# U2: the newest copy of the data file the NEW build made of itself before changing it (apexquant.db.before-<from>-to-<to>-<time>), written after
# the stop of this run. Prints its path, or nothing.
bot_predate_copy(){   # $1 = epoch of this run's stop
    local f best="" bt=0 t
    for f in "$DATA_DIR"/${LAY_DB_NAME}.before-*; do
        [ -f "$f" ] || continue
        case "$f" in *.tmp) continue;; esac
        t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        if [ "$t" -ge "$1" ] && [ "$t" -ge "$bt" ]; then best="$f"; bt="$t"; fi
    done
    printf '%s' "$best"
}
restore_db_for_rollback(){   # $1 = epoch of this run's stop
    local c; c="$(bot_predate_copy "$1")"
    if [ -n "$c" ]; then
        systemctl stop "$SERVICE" 2>/dev/null || true
        rm -f "$DB_PATH-wal" "$DB_PATH-shm"
        if cp -a "$c" "$DB_PATH.restoring" && mv -f "$DB_PATH.restoring" "$DB_PATH"; then
            log "restored your data file from the copy the new version made before changing it ($(basename "$c")) — the previous version sees the data it knew"
        else
            rm -f "$DB_PATH.restoring"; warn "could not restore the data file from $(basename "$c") — MANUAL ATTENTION"
        fi
    else
        log "the new version made no copy of the data file during this run — the data file is left as it is (config snapshot $SNAP)"
    fi
}

# 6.16.59: the stop of this run is marked in the data folder, so the start after it says "after an update" instead of calling the stop unexpected (read once by the bot, system/runstate.py)
mark_updating(){ printf '{"ts": %s}' "$(date +%s)" > "$DATA_DIR/update_in_progress.json.tmp" 2>/dev/null && mv -f "$DATA_DIR/update_in_progress.json.tmp" "$DATA_DIR/update_in_progress.json" 2>/dev/null || true; }
# 6.16.56: every start/restart of the service in this script goes through ONE function that first clears a failed state (a service the manager gave up on refuses a plain start)
svc(){ systemctl reset-failed "$SERVICE" 2>/dev/null || true; systemctl "$1" "$SERVICE"; }

# ── 7.2.0: the move to the new folder names (deploy/migrate-layout.sh does the work; this is the caller) ─────────────────────────────────────────────────────────────────────────────────────
# After a successful move the layout file names the new folders: load it again and take the new names for everything below. (AQ_ROOT_PREFIX is a test folder; it is empty on a real box.)
reload_layout(){
    _aq_layout_load
    local p="${AQ_ROOT_PREFIX:-}"
    INSTALL_DIR="$p$LAY_INSTALL_DIR"; DATA_DIR="$p$LAY_DATA_DIR"; DB_PATH="$DATA_DIR/$LAY_DB_NAME"; SERVICE="$LAY_SERVICE"
}
# Is this box on the old names and its folders the ones the layout says (no override of the folders, as only the tests make)?
on_old_names(){ [ "$LAY_INSTALL_DIR" = "$LAY_LEGACY_INSTALL_DIR" ] && [ "$INSTALL_DIR" = "${AQ_ROOT_PREFIX:-}$LAY_INSTALL_DIR" ] && [ "$DATA_DIR" = "${AQ_ROOT_PREFIX:-}$LAY_DATA_DIR" ]; }
# maybe_migrate DEPLOY_DIR: run migrate-layout.sh from DEPLOY_DIR (a folder that is not the install folder) and act on how it ended.
# 0 = go on (moved, not needed, not now, opted out, held back); 1 = stop (the move failed and could not be put back)
maybe_migrate(){
    local d="$1" rc l
    [ -f "$d/migrate-layout.sh" ] && [ -f "$d/migrate-common.sh" ] && [ -f "$d/layout_paths.py" ] && [ -f "$d/layout.sh" ] && [ -f "$d/apexquant.service" ] || { log "folder names: this package has no move to the new names - skipped"; return 0; }
    on_old_names || return 0
    log "folder names: checking this box for the move to the new names (the move runs from $d, working folder $(pwd))"
    AQ_PREF_DIR="$PREF_DIR" AQ_BACKUP_ROOT="$BACKUP_ROOT" AQ_UNIT_DIR="$UNIT_DIR" bash "$d/migrate-layout.sh" 2>&1 | while IFS= read -r l; do log "  | ${l#\[MIGRATE-LAYOUT\] }"; done
    rc=${PIPESTATUS[0]}
    case "$rc" in
        0)  reload_layout; log "folder names: the box is on the new names now ($INSTALL_DIR)"; ping_update migrated ;;
        1)  log "folder names: the move failed and everything was put back - this box stays on the old names and is not tried again by itself"; ping_update migrate-failed ;;
        2)  log "folder names: the move failed and could NOT be put back completely - MANUAL ATTENTION"; ping_update migrate-failed
            _write_status failed "Folder move failed; manual attention"; return 1 ;;
        10) log "folder names: not applicable to this box - the old names stay" ;;
        11) log "folder names: an order is being placed - not now, tried again at the next window" ;;
        12) log "folder names: this box is held on the old names (opt-out)"; ping_update opted-out ;;
        13) log "folder names: an earlier move failed on this box - not tried again by itself" ;;
        *)  log "folder names: the move ended with code $rc" ;;
    esac
    return 0
}
# the move on its own (no new package): from a copy of the installed deploy folder, so the script does not sit inside the folder it renames
migrate_installed(){
    [ -f "$INSTALL_DIR/deploy/migrate-layout.sh" ] || { log "folder names: the installed version has no move to the new names"; return 0; }
    on_old_names || return 0
    local t rc; t="$(mktemp -d)"; cp -a "$INSTALL_DIR/deploy/." "$t/" || { rm -rf "$t"; return 0; }
    maybe_migrate "$t"; rc=$?; rm -rf "$t"; return $rc
}

# The data file (apexquant.db -> vardynnode.db) is renamed in a second move, AFTER the new version is installed and healthy (a version older than 7.1.4 names the file in its own code and would open a new empty one).
# Only a box that is already on the new folder names and whose data file still has the old name; deploy/migrate-db-name.sh checks the rest.
db_rename_pending(){ [ "$LAY_INSTALL_DIR" = "$LAY_NEW_INSTALL_DIR" ] && [ "$LAY_DB_NAME" = "$LAY_LEGACY_DB_NAME" ] && [ "$INSTALL_DIR" = "${AQ_ROOT_PREFIX:-}$LAY_INSTALL_DIR" ] && [ "$DATA_DIR" = "${AQ_ROOT_PREFIX:-}$LAY_DATA_DIR" ]; }
maybe_rename_db(){   # $1 = a folder that is not the install folder, holding migrate-db-name.sh
    local d="$1" rc l
    db_rename_pending || return 0
    [ -f "$d/migrate-db-name.sh" ] && [ -f "$d/migrate-common.sh" ] && [ -f "$d/layout_paths.py" ] && [ -f "$d/layout.sh" ] && [ -f "$d/apexquant.service" ] || return 0
    log "data file name: checking this box for the rename to vardynnode.db"
    AQ_PREF_DIR="$PREF_DIR" AQ_BACKUP_ROOT="$BACKUP_ROOT" AQ_UNIT_DIR="$UNIT_DIR" bash "$d/migrate-db-name.sh" 2>&1 | while IFS= read -r l; do log "  | ${l#\[MIGRATE-DB\] }"; done
    rc=${PIPESTATUS[0]}
    case "$rc" in
        0)  reload_layout; log "data file name: the data file is $LAY_DB_NAME now" ;;
        1)  log "data file name: the rename failed and everything was put back - the file keeps its name and is not tried again by itself"; ping_update migrate-failed ;;
        2)  log "data file name: the rename failed and could NOT be put back completely - MANUAL ATTENTION"; ping_update migrate-failed
            _write_status failed "Data file rename failed; manual attention"; return 1 ;;
        10) log "data file name: not applicable to this box - the file keeps its name" ;;
        11) log "data file name: an order is being placed - not now, tried again at the next window" ;;
        12) log "data file name: this box is held on the old names (opt-out)" ;;
        13) log "data file name: an earlier rename failed on this box - not tried again by itself" ;;
        *)  log "data file name: the rename ended with code $rc" ;;
    esac
    return 0
}
rename_db_installed(){   # from a copy of the installed deploy folder
    db_rename_pending || return 0
    [ -f "$INSTALL_DIR/deploy/migrate-db-name.sh" ] || return 0
    local t rc; t="$(mktemp -d)"; cp -a "$INSTALL_DIR/deploy/." "$t/" || { rm -rf "$t"; return 0; }
    maybe_rename_db "$t"; rc=$?; rm -rf "$t"; return $rc
}

# ── args ─────────────────────────────────────────────────────────────────────
MIGRATE_NOW=0
case "${1:-}" in
    --enable)  enable_auto; exit 0 ;;
    --disable) disable_auto; exit 0 ;;
    --setup)   install_self; prompt_pref; exit 0 ;;
    --no-migrate-layout) mkdir -p "$PREF_DIR"; : > "$MIGRATE_OPTOUT"; echo "This box stays on the old folder names (a package update does not move them)."; exit 0 ;;
    --migrate-layout) MIGRATE_NOW=1; rm -f "$MIGRATE_OPTOUT" ;;      # on request: moves the box to the new names now (also one that was held back or whose earlier move failed)
    --help|-h) echo "usage: aq-update.sh [--setup|--enable|--disable|--migrate-layout|--no-migrate-layout]  (no arg = update now + offer auto-update)"; exit 0 ;;
    "" )       : ;;
    * )        die "unknown option: $1" ;;
esac

# ── update run ───────────────────────────────────────────────────────────────
# install.sh --update is an IN-PLACE finalizer (migrate secrets + rebuild venv + restart);
# it does NOT download code. So we must download + verify + extract the new dist OURSELVES,
# rename the current install to OLD (install.sh recovers the live license/pubkey from it),
# then finalize — mirroring the manual scp+extract+install flow.
self_refresh "$@"
install_self
exec 9>"$LOCK"; flock -n 9 || { log "another run in progress — skip"; exit 0; }
[ -d "$INSTALL_DIR" ] || die "install dir $INSTALL_DIR not found — is the bot installed?"
if [ "$MIGRATE_NOW" = 1 ]; then
    if ! on_old_names; then
        if db_rename_pending; then MIGRATE_NOW=2; else log "folder names: this box is already on the new names (or has its own layout) - nothing to move"; exit 0; fi
    fi
fi
if [ "$MIGRATE_NOW" = 1 ]; then
    export AQ_MIGRATE_FORCE=1
    migrate_installed || exit 1
    rename_db_installed; exit $?
fi
if [ "$MIGRATE_NOW" = 2 ]; then
    export AQ_MIGRATE_FORCE=1
    rename_db_installed; exit $?
fi
command -v "$REQUIRED_PYTHON" >/dev/null 2>&1 || { log "SKIP: $REQUIRED_PYTHON not found — not a supported update target."; _write_status skipped "Unsupported OS (needs $REQUIRED_PYTHON)"; exit 0; }
command -v unzip >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip >/dev/null 2>&1 || true
command -v unzip >/dev/null 2>&1 || die "unzip not available (apt-get install unzip)"

_from_ver="$( (cd "$INSTALL_DIR" && ./venv/bin/python -c 'import core.version as v; print(v.BUILD_PHASE)') 2>/dev/null | tail -1 )"
select_unit || true; LOCAL_SHA="$(cat "$SHA_STATE" 2>/dev/null || echo "")"
if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
    log "already current (pkg $(short "$REMOTE_SHA")) — no update, not counted"
    _write_status checked_no_update "Already up to date"
    # 7.2.0: a box still on the old names (the move was not quiet enough, or its opt-out was lifted since) is moved now; the same quiet rule as an update (open positions defer it, at most MAX_DEFERRALS windows)
    if { on_old_names || db_rename_pending; } && [ ! -e "$MIGRATE_OPTOUT" ] && [ -f "$INSTALL_DIR/deploy/migrate-layout.sh" ]; then
        _mdef="$(cat "$PREF_DIR/migrate-deferrals" 2>/dev/null || echo 0)"; [[ "$_mdef" =~ ^[0-9]+$ ]] || _mdef=0
        if positions_open && [ "$_mdef" -lt "$MAX_DEFERRALS" ]; then
            echo $((_mdef + 1)) > "$PREF_DIR/migrate-deferrals"; log "folder names: open positions present (LIVE) - the move waits for the next window ($((_mdef + 1)) of $MAX_DEFERRALS)"
        else
            rm -f "$PREF_DIR/migrate-deferrals"; migrate_installed || exit 1; rename_db_installed || exit 1
        fi
    fi
    [ -z "$(load_pref)" ] && prompt_pref || true; exit 0
fi
[ -n "$REMOTE_SHA" ] || die "cannot read the package checksum from any origin ($SITE_ORIGINS) — nothing was installed"
log "new package: $(short "$REMOTE_SHA") (was $(short "$LOCAL_SHA"))"
if positions_open; then
    _def="$(cat "$DEFER_FILE" 2>/dev/null || echo 0)"; [[ "$_def" =~ ^[0-9]+$ ]] || _def=0
    if [ "$_def" -lt "$MAX_DEFERRALS" ]; then
        _def=$((_def + 1)); echo "$_def" > "$DEFER_FILE"
        log "open positions present (LIVE) — deferring update to next window ($_def of $MAX_DEFERRALS)"
        _write_status skipped "Deferred — open positions (window $_def of $MAX_DEFERRALS)"; exit 0
    fi
    log "open positions still present after $MAX_DEFERRALS deferred windows — updating anyway (positions are saved and checked again when the bot restarts)"
else
    rm -f "$DEFER_FILE"
fi
TS="$(date +%Y%m%d-%H%M%S)"; _target_ver=""

# 1) the code package (downloaded and verified in step 2)
_parent="$(dirname "$INSTALL_DIR")"
TMP_ZIP="$(mktemp "${_parent}/aq-dist.XXXXXX.zip")"
# 2) DOWNLOAD + VERIFY, one origin at a time: the checksum, the zip and the signature of ONE origin are used together (never mixed). The sha256 must equal that origin's published checksum; minisign too when it
#    publishes a signature. An origin that cannot be reached, answers an error, has a different checksum or a signature that is not valid is passed over for the next one; nothing is ever accepted on a bad
#    signature, and when no origin gives a verified package nothing is installed.
_unsigned=0      # 7.3.25: set when an origin gave a package with no signature
download_package(){
    local i idx u d g s order=("$UNIT_NO") _zsig act
    for ((i=0; i<${#UNITS[@]}; i++)); do [ "$i" = "$UNIT_NO" ] || order+=("$i"); done
    _zsig="$(mktemp)"
    for idx in "${order[@]}"; do
        read -r u d g <<< "${UNITS[$idx]}"
        if [ "$idx" = "$UNIT_NO" ]; then s="$REMOTE_SHA"; else s="$(fetch_sha "$u")" || s=""; fi
        [ -n "$s" ] || { log "checksum from $(origin_of "$u") not available — trying the next origin"; continue; }
        log "downloading $d ..."
        rm -f "$TMP_ZIP"
        zip_fetch "$d" "$TMP_ZIP" && [ -s "$TMP_ZIP" ] || { log "download from $(origin_of "$d") failed — trying the next origin"; continue; }
        act="$(sha256sum "$TMP_ZIP" | awk '{print $1}')"
        [ "$act" = "$s" ] || { log "checksum mismatch from $(origin_of "$d") (got $(short "$act"), want $(short "$s")) — trying the next origin"; continue; }
        if curl -fsSL --max-time 30 "$g" -o "$_zsig" 2>/dev/null && [ -s "$_zsig" ]; then
            verify_sig "$TMP_ZIP" "$_zsig" || { log "dist signature from $(origin_of "$d") is NOT valid — not used, trying the next origin"; continue; }
            log "dist signature verified ✓"
        else
            # 7.3.25 (the owner's ruling): a package with no signature (or none that could be fetched) is NEVER installed: the checksum comes from the same origin as the zip and proves nothing about who published it.
            # The next origin is tried; when none gives a signed package nothing is installed, the running version is kept and the status says so.
            _unsigned=1
            log "no dist signature published by $(origin_of "$d") — a package without a verified signature is never installed — trying the next origin"
            continue
        fi
        REMOTE_SHA="$s"; rm -f "$_zsig"
        log "package served by $(origin_of "$d")"
        return 0
    done
    rm -f "$_zsig" "$TMP_ZIP"; return 1
}
if ! download_package; then
    if [ "$_unsigned" = 1 ]; then
        die "No signed update package was available, so nothing was installed. Your current version keeps running."
    fi
    die "no origin gave a verified package — nothing was installed"
fi

# 2b) UNPACK the verified package into a staging folder beside the install (same file system), and check it, BEFORE anything on the box is touched. The package's top folder keeps its old name (older updaters unpack
#     straight into /root and expect it); it is moved into place under whatever name the layout says.
STAGE="$(mktemp -d "${_parent}/aq-stage.XXXXXX")"
if ! unzip -oq "$TMP_ZIP" -d "$STAGE"; then rm -rf "$STAGE" "$TMP_ZIP"; die "extract failed — nothing was changed"; fi
rm -f "$TMP_ZIP"
STAGE_TOP=""; for _d in "$STAGE"/*/; do [ -d "$_d" ] && STAGE_TOP="${_d%/}"; done
[ -n "$STAGE_TOP" ] && [ -f "$STAGE_TOP/install.sh" ] || { rm -rf "$STAGE"; die "bad dist (no install.sh) — nothing was changed"; }

# 2b-2) 7.3.36 (install F7): what the installer needs is checked BEFORE the bot is stopped and the folders are swapped (it was checked only inside the installer, after the stop: a box that failed these was stopped,
#       rolled back and restarted every night). Python 3.12 must be able to make an environment, and there must be room for the new one beside the old one (the size of the old one plus 300 MB; 1.5 GB when it has none).
if ! "$REQUIRED_PYTHON" -c 'import venv, ensurepip' >/dev/null 2>&1; then
    rm -rf "$STAGE"; log "SKIP: $REQUIRED_PYTHON cannot make a Python environment (its venv package is missing). Nothing was changed."
    _write_status skipped "Python 3.12 cannot make a Python environment (its venv package is missing)"; exit 0
fi
_need_kb=1572864; [ -d "$INSTALL_DIR/venv" ] && _need_kb=$(( $(du -sk "$INSTALL_DIR/venv" 2>/dev/null | cut -f1) + 307200 ))
_free_kb="${AQ_DISK_FREE_KB:-$(df -Pk "$_parent" 2>/dev/null | awk 'NR==2 {print $4}')}"
if [[ "$_need_kb" =~ ^[0-9]+$ && "$_free_kb" =~ ^[0-9]+$ ]] && [ "$_free_kb" -lt "$_need_kb" ]; then
    _nx="$(awk -v k="$_need_kb" 'BEGIN { printf "%.1f", k / 1048576 }')"; _fy="$(awk -v k="$_free_kb" 'BEGIN { printf "%.1f", k / 1048576 }')"
    rm -rf "$STAGE"; log "SKIP: There is not enough free disk space to refresh the bot's Python environment: about $_nx GB is needed and $_fy GB is free. Free some space and run the update again. Nothing was changed."
    _write_status skipped "Not enough free disk space for the update (about $_nx GB needed, $_fy GB free)"; exit 0
fi

# 2c) FOLDER NAMES (7.2.0): a box still on the old names moves to the new ones now, from the new package's own script, at this quiet moment (the gate above) and before the install step. It is on by default;
#     a failed move is put back by itself and not tried again; "apexquant --no-migrate-layout" holds a box back.
maybe_migrate "$STAGE_TOP/deploy" || { rm -rf "$STAGE"; exit 1; }

# 3) STAGE — config/db snapshot, then rename current install aside as OLD (secret source + rollback)
OLD_DIR="${INSTALL_DIR}.OLD-$TS"
mark_updating
systemctl stop "$SERVICE" 2>/dev/null || true
rm -f "$UNIT_DIR/$SERVICE.service.prev"      # 6.16.56: only a unit saved by THIS run's installer may be put back on a rollback
STOP_EPOCH="$(date +%s)"
prune_copies      # first, so the new snapshot has room (the copies of earlier updates were never removed)
SNAP="$(make_snapshot "$TS")"
mv "$INSTALL_DIR" "$OLD_DIR" || { rm -rf "$STAGE"; svc start 2>/dev/null || true; die "could not move current install aside"; }

# 4) the new dist (unpacked and checked in step 2b) goes into place under the install folder's name
if ! mv "$STAGE_TOP" "$INSTALL_DIR"; then
    rm -rf "$INSTALL_DIR"; mv "$OLD_DIR" "$INSTALL_DIR"; rm -rf "$STAGE"
    svc start 2>/dev/null || true; die "could not put the new version in place — restored previous install"
fi
rm -rf "$STAGE"
[ -f "$INSTALL_DIR/install.sh" ] || { rm -rf "$INSTALL_DIR"; mv "$OLD_DIR" "$INSTALL_DIR"; svc start 2>/dev/null || true; die "bad dist (no install.sh) — restored previous install"; }

# 5) FINALIZE via install.sh --update <OLD_DIR> — recovers the LIVE license/pubkey from OLD
#    (not the stale aql-secrets-backup), rebuilds venv, restarts.
INSTALLER_FAILED=0; INST_LOG="$(mktemp)"
chmod +x "$INSTALL_DIR/install.sh"
_target_ver="$( (cd "$INSTALL_DIR" && ./venv/bin/python -c 'import core.version as v; print(v.BUILD_PHASE)') 2>/dev/null | tail -1 )"
log "finalizing via install.sh --update $OLD_DIR"
AQ_OLD_VENV_DIR="$OLD_DIR/venv" AQ_NONINTERACTIVE=1 AQ_FORCE=1 AQ_FROM_UPDATER=1 bash "$INSTALL_DIR/install.sh" --update "$OLD_DIR" >"$INST_LOG" 2>&1 || INSTALLER_FAILED=1      # 7.3.36 (F12): the old environment is parked here: the installer measures it
[ "$INSTALLER_FAILED" = 1 ] && { log "installer exited non-zero — last lines:"; tail -n 20 "$INST_LOG" | while IFS= read -r _l; do log "  | $_l"; done; }
cat "$INST_LOG" >> "$LOG" 2>/dev/null || true; rm -f "$INST_LOG"
restore_config "$SNAP"
# 7.3.25: the version being installed is read AGAIN now that the installer has built the venv (the read above ran before it existed on a real box, so the status recorded an empty target)
[ -n "$_target_ver" ] || _target_ver="$( (cd "$INSTALL_DIR" && ./venv/bin/python -c 'import core.version as v; print(v.BUILD_PHASE)') 2>/dev/null | tail -1 )"

healthy(){ systemctl is-active --quiet "$SERVICE" || return 1
    [ -z "$HEALTH_URL" ] || curl -fsS --max-time 8 "$HEALTH_URL" >/dev/null 2>&1 || return 1; return 0; }

# 6) SUSTAINED health — must stay up through the window (catches a delayed FATAL gate)
_stayed_up=1
for _i in $(seq 1 "${AQ_HEALTH_WINDOW_CHECKS:-6}"); do
    sleep 5
    if [ "$INSTALLER_FAILED" = 1 ] || ! healthy; then _stayed_up=0; break; fi
done
if [ "$INSTALLER_FAILED" = 0 ] && [ "$_stayed_up" = 1 ]; then
    echo "$REMOTE_SHA" > "$SHA_STATE"; rm -f "$DEFER_FILE"
    # version is baked into the compiled core/version.so — read it via the bot's venv
    _ver="$( (cd "$INSTALL_DIR" && ./venv/bin/python -c 'import core.version as v; print(v.BUILD_PHASE)') 2>/dev/null | tail -1 )"
    [ -z "$_ver" ] && _ver="$(short "$REMOTE_SHA")"
    ping_update "$(short "$REMOTE_SHA")"
    prune_copies      # 6.16.58: the one retention rule (this run's snapshot and the previous install are the newest and stay)
    _write_status success "Updated and healthy"
    log "update applied — new code staged + healthy ${AQ_HEALTH_WINDOW_CHECKS:-6}x5s, counted (pkg $(short "$REMOTE_SHA"))"
    rename_db_installed || exit 1      # 7.2.0: the data file takes the new name now that the new version runs (a failure puts it back and leaves the update as it is)
    printf "\n\033[32m===================================================\n"
    printf "  \342\234\224 UPDATE SUCCESSFUL\n"
    printf "  You are running VardynNode %s now.\n" "$_ver"
    printf "  Package: %s\n" "$(short "$REMOTE_SHA")"
    printf "  Updated: %s  (%s)\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    printf "\n"
    printf "  The bot has already restarted and is running.\n"
    printf "  Your trading carries on as normal.\n"
    printf "===================================================\033[0m\n\n"
    [ -z "$(load_pref)" ] && prompt_pref || true; exit 0
fi

# 7) ROLLBACK — swap the real previous install back
log "update unhealthy (installer_failed=$INSTALLER_FAILED) — rolling back to $OLD_DIR"
if [ -d "$OLD_DIR" ]; then
    rm -rf "${INSTALL_DIR}.failed-$TS" 2>/dev/null || true
    mv "$INSTALL_DIR" "${INSTALL_DIR}.failed-$TS" 2>/dev/null || true
    mv "$OLD_DIR" "$INSTALL_DIR"; restore_config "$SNAP"
    restore_db_for_rollback "$STOP_EPOCH"
    # 6.16.56: the service unit the failed update installed goes back to the one it replaced
    if [ -f "$UNIT_DIR/$SERVICE.service.prev" ]; then
        cp -a "$UNIT_DIR/$SERVICE.service.prev" "$UNIT_DIR/$SERVICE.service" && systemctl daemon-reload && log "service unit restored to the previous one"
    fi
    svc restart || true; sleep 5
    if healthy; then log "rollback SUCCESS — previous version restored"; _write_status rolled_back "Update failed; previous version restored and running"; _fail_banner restored; else log "rollback restored previous dir but health STILL failing — MANUAL ATTENTION (config $SNAP)"; _write_status failed "Update failed; bot not running — manual attention"; _fail_banner manual; fi
else
    log "no OLD_DIR to roll back to — MANUAL ATTENTION (config snapshot $SNAP)"; _write_status failed "Update failed; no rollback target — manual attention"; _fail_banner manual
fi
exit 1
