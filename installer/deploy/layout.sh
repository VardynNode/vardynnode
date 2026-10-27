#!/usr/bin/env bash
# The install layout for the scripts (7.1.4): ONE place. Sourced by install.sh, update_*.sh and build_dist.sh; the block between the markers is
# copied verbatim into deploy/aq-update.sh and deploy/get-apexquant.sh (they are served on their own and run before a package exists); a gate test
# compares the three copies. Its twin for Python is core/layout.py: the two must give the same answers.
# A layout file (/etc/vardynnode/layout or the path in AQ_LAYOUT_FILE; one KEY=VALUE per line) may change the defaults; a value must be plain path
# characters, anything else gives the default. With no file nothing changes: the defaults are the layout every box has today.
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

# ── 7.2.0: what the installer and the migration write, in ONE place (so a migrated box and a fresh install get the same files) ─────────────────────────────────────────────────────────────────────────────
aq_layout_file() { printf '%s' "${AQ_LAYOUT_FILE:-/etc/vardynnode/layout}"; }      # where the layout file is (the block above reads the same path)
aq_env_file_get() {      # <suffix> <settings file>: the value of VARDYNNODE_<suffix> in the file, else of APEXQUANT_<suffix> (the last line of each wins; quotes, spaces and CR removed; a blank value is not set). The same rule as core/envnames.py (7.3.2).
    local f="$2" v n
    for n in "VARDYNNODE_$1" "APEXQUANT_$1"; do
        v="$(sed -n "s/^${n}=//p" "$f" 2>/dev/null | tail -n 1 | tr -d '"'"'"' \r')"
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
    return 0
}
aq_drop_new_layout() { rm -f "$(aq_layout_file)"; _aq_layout_load; }      # take the layout file away again (the box stays on the old names)
# The service unit: the template (deploy/apexquant.service) with its markers filled in; on the new names the unit also answers to the old name (Alias=), so "systemctl restart apexquant" keeps working.
aq_render_unit() {   # aq_render_unit TEMPLATE INSTALL_DIR DATA_DIR DB_NAME SERVICE   -> the unit text on stdout
    local alias_sed="/^@AQ_ALIAS@\$/d"
    [ "$5" = "$LAY_NEW_SERVICE" ] && alias_sed="s#^@AQ_ALIAS@\$#Alias=${LAY_LEGACY_SERVICE}.service#"
    sed -e "s#@AQ_INSTALL_DIR@#$2#g" -e "s#@AQ_DATA_DIR@#$3#g" -e "s#@AQ_DB_NAME@#$4#g" -e "s#@AQ_SERVICE@#$5#g" -e "$alias_sed" "$1"
}
# The command: a small script that runs the bot's entry point; on the new names the old command stays as a script that hands over to the new one.
aq_cli_shim_text() {   # aq_cli_shim_text INSTALL_DIR   -> the command script on stdout
    printf '%s\n' '#!/usr/bin/env bash' \
        "# VardynNode CLI shim (installed by install.sh). Wraps the bot's Python entrypoint" \
        "# so customers run the command with a flag instead of a full python path." \
        "exec \"$1/venv/bin/python3\" \"$1/main.py\" \"\$@\""
}
aq_cli_legacy_shim_text() {   # aq_cli_legacy_shim_text NEW_CLI_PATH   -> the old command, handing over to the new one
    printf '%s\n' '#!/usr/bin/env bash' \
        "# The old command name: it hands over to the new one (installed by install.sh and by the folder-name migration)." \
        "exec \"$1\" \"\$@\""
}
