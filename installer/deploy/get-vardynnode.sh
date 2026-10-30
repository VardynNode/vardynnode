#!/usr/bin/env bash
# 7.3.38: the settings are called VN_<name>; the earlier AQ_<name> is still accepted until the sunset (BACKLOG row 17) (a caller that still sets it is mapped here; VN_ wins).
_vn_env_compat() { local _v _n; for _v in $(compgen -v); do case "$_v" in AQ_*) _n="VN_${_v#AQ_}"; [ -n "${!_n:-}" ] || export "$_n=${!_v}";; esac; done; }; _vn_env_compat
###############################################################################
# VardynNode — public one-command installer  (served at https://get.vardynnode.com)
#
#   curl -fsSL https://get.vardynnode.com | sudo bash
#
# Downloads the canonical dist from /files/ (the SITE origins below, in order; the next one is tried when one
# is unreachable, answers an error or does not verify), verifies its minisign signature (authenticity +
# integrity) with a PINNED key, extracts to the install folder (/root/VardynNode), and runs install.sh --unattended. The zip and its
# signature always come from the SAME origin. All logic lives in main(), invoked only on the LAST line — so a
# truncated curl|bash executes nothing.
###############################################################################
set -euo pipefail

# ORIGINS (the one place the download domains are named, here and in vn-update.sh). Serving: vardynnode.com. VN_DIST_URL / VN_SIG_URL still override: when set they are the only URLs used.
SITE_ORIGINS="${VN_SITE_ORIGINS:-https://vardynnode.com}"
DIST_URL="${VN_DIST_URL:-}"
SIG_URL="${VN_SIG_URL:-}"
# PINNED minisign public key — NOT env-overridable. To rotate, edit this line.
readonly VN_MINISIGN_PUBKEY="RWRHtMOGHSz0oywqtMdW5cQkw2UE1llujBPPnUFkW1RGaz9qRFZHZKSj"
# The install layout (7.1.4): the same block as deploy/layout.sh, copied verbatim because this file is served on its own; a gate test compares the copies.
# >>> VN-LAYOUT
_vn_lay() {   # _vn_lay KEY DEFAULT
    local v=""
    if [ -r "${VN_LAYOUT_FILE:-/etc/vardynnode/layout}" ]; then
        v="$(sed -n "s/^$1=//p" "${VN_LAYOUT_FILE:-/etc/vardynnode/layout}" 2>/dev/null | tail -n 1 | tr -d '\r')"
    fi
    case "$v" in
        ""|*[!A-Za-z0-9_./-]*) v="$2" ;;
    esac
    printf '%s' "$v"
}
_vn_layout_load() {   # (7.2.0: a function, so a script can load the layout again after it has written a layout file)
    export LAY_INSTALL_DIR; LAY_INSTALL_DIR="$(_vn_lay INSTALL_DIR /root/ApexQuant)"
    export LAY_DATA_DIR; LAY_DATA_DIR="$(_vn_lay DATA_DIR /root/apexquant-data)"
    export LAY_DB_NAME; LAY_DB_NAME="$(_vn_lay DB_NAME apexquant.db)"
    export LAY_SERVICE; LAY_SERVICE="$(_vn_lay SERVICE_NAME apexquant)"
    export LAY_CLI; LAY_CLI="$(_vn_lay CLI_NAME apexquant)"
    export LAY_PREF_DIR; LAY_PREF_DIR="$(_vn_lay PREF_DIR /var/lib/apexquant)"
    export LAY_BACKUP_ROOT; LAY_BACKUP_ROOT="$(_vn_lay BACKUP_ROOT /var/backups/apexquant)"
    export LAY_LOG_PREFIX; LAY_LOG_PREFIX="$(_vn_lay LOG_PREFIX /root/apexquant-)"
    export LAY_UPDATE_UNIT; LAY_UPDATE_UNIT="$(_vn_lay UPDATE_UNIT vardynnode-update)"
    export LAY_NGINX_SITE; LAY_NGINX_SITE="$(_vn_lay NGINX_SITE apexquant)"
    export LAY_SSL_DIR; LAY_SSL_DIR="$(_vn_lay SSL_DIR /etc/ssl/apexquant)"
    export LAY_OLD_DIR="${LAY_INSTALL_DIR}_old"
    export LAY_CLI_PATH="/usr/local/bin/${LAY_CLI}"
}
_vn_layout_load
# The names before the folder rename (LEGACY: what a box without a layout file has) and after it (NEW: what a fresh install writes first and the migration writes). The state folder, the backup folder, the
# web-server site and the certificate folder have two generations too (7.3.38: a fresh install writes the new ones, deploy/migrate-names.sh moves an existing box). The update timer is called vardynnode-update on every box (7.3.38); a box that still has the earlier pair (LEGACY_UPDATE_UNIT) is moved by deploy/vn-update.sh.
export LAY_LEGACY_INSTALL_DIR=/root/ApexQuant LAY_LEGACY_DATA_DIR=/root/apexquant-data LAY_LEGACY_DB_NAME=apexquant.db LAY_LEGACY_SERVICE=apexquant LAY_LEGACY_CLI=apexquant LAY_LEGACY_LOG_PREFIX=/root/apexquant- LAY_LEGACY_UPDATE_UNIT=apexquant-update
export LAY_LEGACY_PREF_DIR=/var/lib/apexquant LAY_LEGACY_BACKUP_ROOT=/var/backups/apexquant LAY_LEGACY_NGINX_SITE=apexquant LAY_LEGACY_SSL_DIR=/etc/ssl/apexquant
export LAY_NEW_INSTALL_DIR=/root/VardynNode LAY_NEW_DATA_DIR=/root/vardynnode-data LAY_NEW_DB_NAME=vardynnode.db LAY_NEW_SERVICE=vardynnode LAY_NEW_CLI=vardynnode LAY_NEW_LOG_PREFIX=/root/vardynnode-
export LAY_NEW_PREF_DIR=/var/lib/vardynnode LAY_NEW_BACKUP_ROOT=/var/backups/vardynnode LAY_NEW_NGINX_SITE=vardynnode LAY_NEW_SSL_DIR=/etc/ssl/vardynnode
_vn_new_layout_text() {   # the content of the layout file of the new names (a fresh install writes the whole of it; the folder move writes it with "keepdb": the data file keeps its old name until deploy/migrate-db-name.sh renames it, and the state folder, backup folder, site and certificate folder keep theirs until deploy/migrate-names.sh moves them)
    printf '%s\n' "# The install layout (read by the bot and the scripts: core/layout.py, deploy/layout.sh). One KEY=VALUE per line." "INSTALL_DIR=$LAY_NEW_INSTALL_DIR" "DATA_DIR=$LAY_NEW_DATA_DIR"
    [ "${1:-}" = keepdb ] || printf '%s\n' "DB_NAME=$LAY_NEW_DB_NAME"
    printf '%s\n' "SERVICE_NAME=$LAY_NEW_SERVICE" "CLI_NAME=$LAY_NEW_CLI" "LOG_PREFIX=$LAY_NEW_LOG_PREFIX"
    [ "${1:-}" = keepdb ] || printf '%s\n' "PREF_DIR=$LAY_NEW_PREF_DIR" "BACKUP_ROOT=$LAY_NEW_BACKUP_ROOT" "NGINX_SITE=$LAY_NEW_NGINX_SITE" "SSL_DIR=$LAY_NEW_SSL_DIR"
}
_vn_is_fresh_box() {   # no layout file, no old or new install (a venv), no old or new data folder: a box that has never had the bot
    local r="${VN_ROOT_PREFIX:-}"
    [ ! -e "${VN_LAYOUT_FILE:-/etc/vardynnode/layout}" ] && [ ! -e "$r$LAY_LEGACY_DATA_DIR" ] && [ ! -e "$r$LAY_LEGACY_INSTALL_DIR/venv" ] && [ ! -e "$r$LAY_NEW_DATA_DIR" ] && [ ! -e "$r$LAY_NEW_INSTALL_DIR/venv" ]
}
_vn_adopt_new_layout() {   # [keepdb]: write the layout file of the new names (atomically) and load it; fails when a layout file already exists
    local f="${VN_LAYOUT_FILE:-/etc/vardynnode/layout}"
    [ ! -e "$f" ] || return 1
    mkdir -p "$(dirname "$f")" || return 1
    _vn_new_layout_text "${1:-}" > "$f.tmp.$$" || { rm -f "$f.tmp.$$"; return 1; }
    chmod 644 "$f.tmp.$$"
    mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
    _vn_layout_load
}
_vn_layout_absent() { [ ! -e "${VN_LAYOUT_FILE:-/etc/vardynnode/layout}" ]; }      # (7.3.36: the path of the layout file is written only in the layout block)
_vn_layout_remove() { rm -f "${VN_LAYOUT_FILE:-/etc/vardynnode/layout}"; }
# <<< VN-LAYOUT
# 7.2.0: a box that has never had the bot installs on the NEW folder names: the layout file is written so everything below (and install.sh) uses them. A box that has the bot keeps the names it has.
# 7.3.36 (install F3): it is written inside main(), AFTER the preflight (root, apt, system, an install already here) and taken away again if the run stops before the installer starts: a failed
# preflight used to leave the file behind, and a later manual install from a zip then found a layout it could not use.
_VN_ADOPTED=0; _VN_INSTALL_STARTED=0
_vn_drop_adopted() {
    if [ "$_VN_ADOPTED" = 1 ] && [ "$_VN_INSTALL_STARTED" = 0 ]; then _vn_layout_remove; fi
}
APP_DIR="$LAY_INSTALL_DIR"
DATA_DIR="$LAY_DATA_DIR"
LOG="${VN_BOOTSTRAP_LOG:-${LAY_LOG_PREFIX}bootstrap.log}"      # (the override is for the tests)

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; NC=$'\033[0m'
say(){ echo "${GRN}[VardynNode]${NC} $*"; }
warn(){ echo "${YEL}[VardynNode]${NC} $*"; }
die(){ echo "${RED}[VardynNode] ERROR:${NC} $*" >&2; exit 1; }

main(){
    # bootstrap log holds credentials later — root-only BEFORE teeing.
    umask 077
    touch "$LOG"; chmod 600 "$LOG"
    exec > >(tee -a "$LOG") 2>&1
    say "VardynNode installer starting $(date -u)"

    # 1) preflight
    [[ $EUID -eq 0 || -n "${VN_TEST_NONROOT:-}" ]] || die "Run as root:  curl -fsSL https://get.vardynnode.com | sudo bash"      # (VN_TEST_NONROOT is for the tests only)
    command -v apt-get >/dev/null 2>&1 || die "Debian/Ubuntu (apt) only."
    . /etc/os-release 2>/dev/null || true
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        if [[ "${VN_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
            warn "Unsupported OS ${PRETTY_NAME:-unknown} — proceeding (VN_ALLOW_UNSUPPORTED_OS=1). Dist is Python 3.12 ABI-locked; likely to fail."
        else
            die "VardynNode requires Ubuntu 24.04 LTS (Python 3.12). Found ${PRETTY_NAME:-unknown}. Deploy a 24.04 image and retry.  (Advanced override: VN_ALLOW_UNSUPPORTED_OS=1)"
        fi
    fi
    # 7.3.36 (install F1 / F2): a WORKING install is refused with the update command; the data of an earlier install is kept and re-attached; a stopped install is finished. (The old tests refused both,
    # and offered "remove the data folder", which destroys the kept licence and settings.)
    if [[ -d "$APP_DIR/venv" && -f "${VN_UNIT_DIR:-/etc/systemd/system}/${LAY_SERVICE}.service" ]]; then
        die "VardynNode is already installed at $APP_DIR. To update it run:  curl -fsSL https://get.vardynnode.com/update | sudo bash"
    fi
    if [[ -f "$APP_DIR/main.py" ]]; then warn "An earlier install at $APP_DIR did not finish; it is set aside and the install is done again (your data is kept)."; fi
    if [[ -d "$DATA_DIR" ]]; then say "Data of an earlier install found at $DATA_DIR: it is kept and re-attached."; fi
    # a fresh box installs on the new folder names (the layout file is written now that the preflight has passed). 7.3.36 (install F2): so does a box whose layout file is gone but whose kept data sits in the NEW
    # data folder (a keep-data uninstall removed the file): it re-attaches to that data instead of quietly installing a second copy on the old names.
    if { [ "$(id -u)" = 0 ] || [ -n "${VN_TEST_NONROOT:-}" ]; }; then
        _vn_kept="no"
        if _vn_is_fresh_box; then _vn_kept="fresh"
        elif _vn_layout_absent && [ -d "${VN_ROOT_PREFIX:-}$LAY_NEW_DATA_DIR" ] && [ ! -e "${VN_ROOT_PREFIX:-}$LAY_LEGACY_DATA_DIR" ] && [ ! -e "${VN_ROOT_PREFIX:-}$LAY_LEGACY_INSTALL_DIR/venv" ]; then _vn_kept="kept"; fi
        if [ "$_vn_kept" != "no" ]; then
            _vn_keepdb=""; if [ "$_vn_kept" = "kept" ] && [ ! -e "${VN_ROOT_PREFIX:-}$LAY_NEW_DATA_DIR/$LAY_NEW_DB_NAME" ] && [ -e "${VN_ROOT_PREFIX:-}$LAY_NEW_DATA_DIR/$LAY_LEGACY_DB_NAME" ]; then _vn_keepdb="keepdb"; fi
            if _vn_adopt_new_layout $_vn_keepdb; then _VN_ADOPTED=1; APP_DIR="$LAY_INSTALL_DIR"; DATA_DIR="$LAY_DATA_DIR"; trap '_vn_drop_adopted' EXIT; fi
        fi
    fi

    # 2) deps (minisign mandatory — pinned-key verification is required)
    export DEBIAN_FRONTEND=noninteractive
    say "Installing prerequisites"
    apt-get update -y -qq
    apt-get install -y -qq --no-install-recommends curl ca-certificates unzip coreutils minisign
    command -v minisign >/dev/null 2>&1 || die "minisign is required for signature verification but could not be installed."

    # 3) download + MANDATORY signature verification (no sha256 fallback)
    local TMP_ZIP TMP_SIG o d g got=0 first=""
    TMP_ZIP="$(mktemp /root/vn-dist.XXXXXX.zip)"; TMP_SIG="${TMP_ZIP}.minisig"
    trap 'rm -f "$TMP_ZIP" "$TMP_SIG"; _vn_drop_adopted' EXIT
    # one origin at a time: its zip and its signature together; an origin that fails, or whose signature is not valid, is passed over (never accepted)
    local -a CANDS=()
    if [[ -n "$DIST_URL$SIG_URL" ]]; then
        d="${DIST_URL:-${SITE_ORIGINS%% *}/files/VardynNode-Setup.zip}"; CANDS+=("$d ${SIG_URL:-$d.minisig}")
    else
        # 7.2.0: the package is published under two names (copies, each with its own signature): the new name first, the old name as the fallback, at each origin
        local z; for o in $SITE_ORIGINS; do for z in VardynNode-Setup.zip ApexQuant-Setup.zip; do CANDS+=("$o/files/$z $o/files/$z.minisig"); done; done
    fi
    for c in "${CANDS[@]}"; do
        read -r d g <<< "$c"
        say "Downloading dist: $d"
        rm -f "$TMP_ZIP" "$TMP_SIG"
        curl -fSL --retry 3 "$d" -o "$TMP_ZIP" 2>/dev/null && [[ -s "$TMP_ZIP" ]] || { warn "Download from ${d#*://} failed — trying the next origin"; continue; }
        say "Fetching signature: $g"
        curl -fsSL "$g" -o "$TMP_SIG" 2>/dev/null && [[ -s "$TMP_SIG" ]] || { warn "Cannot fetch the signature from this origin — trying the next origin"; continue; }
        minisign -V -P "$VN_MINISIGN_PUBKEY" -m "$TMP_ZIP" -x "$TMP_SIG" >/dev/null 2>&1 \
            || { warn "SIGNATURE VERIFICATION FAILED for the download from ${d#*://} — not used, trying the next origin"; continue; }
        got=1; first="$d"; break
    done
    [[ "$got" == 1 ]] || die "No origin gave a download that is authentically signed by VardynNode. Aborting rather than install unverified."
    say "Signature verified (minisign, pinned key); package served by ${first#*://}"
    VN_PKG_SHA256="$(sha256sum "$TMP_ZIP" 2>/dev/null | awk '{print $1}')"      # 7.3.25: recorded after the install (see below)
    rm -f "$TMP_SIG"

    # count this install (curl|bash bypasses the website /dl/ping beacon) — fire-and-forget
    if [[ -n "${VN_BEACON_URL:-}" ]]; then curl -fsS -m 5 "$VN_BEACON_URL" -o /dev/null 2>&1 || true
    else for o in $SITE_ORIGINS; do curl -fsS -m 5 "$o/dl/ping?src=cli" -o /dev/null 2>&1 && break; done; fi

    # 4) unpack into a staging folder, check it, move it to the install folder (the package's top folder keeps its old name), run the installer from there
    say "Extracting to $APP_DIR"
    local STAGE STAGE_TOP="" _d
    STAGE="$(mktemp -d "$(dirname "$APP_DIR")/vn-stage.XXXXXX")"
    unzip -oq "$TMP_ZIP" -d "$STAGE" || { rm -rf "$STAGE"; die "Could not unpack the download (bad dist?)."; }
    for _d in "$STAGE"/*/; do [[ -d "$_d" ]] && STAGE_TOP="${_d%/}"; done
    [[ -n "$STAGE_TOP" && -f "$STAGE_TOP/install.sh" ]] || { rm -rf "$STAGE"; die "install.sh not found in the download (bad dist?)."; }
    if [[ -e "$APP_DIR" ]]; then mv "$APP_DIR" "$APP_DIR.unfinished-$(date +%s)" || { rm -rf "$STAGE"; die "Could not set the unfinished install at $APP_DIR aside."; }; fi
    mv "$STAGE_TOP" "$APP_DIR" || { rm -rf "$STAGE"; die "Could not move the package to $APP_DIR."; }
    rm -rf "$STAGE"
    [[ -f "$APP_DIR/install.sh" ]] || die "install.sh not found at $APP_DIR after extract (bad dist?)."
    cd "$APP_DIR"; chmod +x install.sh
    say "Running VardynNode installer (systemd, nginx, firewall, credentials)"
    _VN_INSTALL_STARTED=1      # from here the box is in the state of this install: the layout file stays
    VN_UNATTENDED=1 ./install.sh --unattended
    # 7.3.25: remember which package this box was installed from (the sha256 of the verified zip, the same number the site publishes next to it), so the first automatic update check
    # sees "already current" instead of installing the very same package again. Best effort: without it the only cost is one repeat install.
    if [[ -n "${VN_PKG_SHA256:-}" ]]; then
        mkdir -p "$LAY_PREF_DIR" 2>/dev/null && printf '%s\n' "$VN_PKG_SHA256" > "$LAY_PREF_DIR/installed.sha256" 2>/dev/null || true
    fi

    # 5) surface credentials + config commands
    local IP INSTALL_LOG HANDOVER
    IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
    INSTALL_LOG="$(ls -t ${LAY_LOG_PREFIX}install-*.log 2>/dev/null | head -1)"
    HANDOVER="$(ls -t "$APP_DIR"/handover-*.html 2>/dev/null | head -1)"
    say "Install complete."
    echo
    echo "  DASHBOARD:  https://${IP}/    (accept the self-signed cert the first time)"
    echo
    echo "  LOGIN (auto-generated password + PIN):"
    if [[ -n "$INSTALL_LOG" ]]; then
        grep -iE "dashboard password|password:|(^|[^A-Za-z])PIN([^A-Za-z]|:)|setup token" "$INSTALL_LOG" | sed 's/^/     /' || true
        echo "     Full details in:  $INSTALL_LOG"
    fi
    if [[ -n "$HANDOVER" ]]; then
        echo "     Handover report:  $HANDOVER"
        echo "                       (holds password + PIN; delete after saving: rm '$HANDOVER')"
    else
        echo "     Your password and PIN are in the install log above (and in the bootstrap log named below)."
    fi
    echo
    echo "  ADD LICENSE + BINANCE KEYS — run the guided setup ON THE SERVER:"
    echo "     ${LAY_CLI} --setup-gui         # token-gated wizard; prints a URL; self-closes when done"
    echo "     ${LAY_CLI} --show-setup-token  # re-print the setup token if needed"
    echo "     ${LAY_CLI} --config-gui        # edit settings later"
    echo
    echo "  Until a license is added, the bot runs in SAFE/paper mode (no exchange keys needed)."
    echo
    warn "This bootstrap log ($LOG) contains your password + PIN — delete it after saving:  rm '$LOG'"
    say "Docs & license: https://vardynnode.com"
}

main "$@"
