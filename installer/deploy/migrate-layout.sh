#!/usr/bin/env bash
# migrate-layout.sh (7.2.0) - move an existing box from the old folder, service and command names (ApexQuant) to the new ones (VardynNode). Called by aq-update.sh after the package is verified and before
# the normal install step (and by "apexquant --migrate-layout"); safe to run again (a box that is already moved does nothing).
#
#   what it does:  backs up, stops the service, renames the install folder and the data folder (same file system only), leaves the old names as links to the new ones, points every link inside the folders at the
#                  new names, writes the new unit (the old name stays as an alias), the new command (the old one hands over to it) and the layout file, starts the service and checks it.
#   the check:     the service stays active, the dashboard answers, the running marker is fresh, and the log shows no [FATAL]. If any of it fails everything is put back (the old folders, unit, command and
#                  links; the old service is started again) and the box is marked migrate-failed. A box marked migrate-failed is not tried again unless a person asks for it (apexquant --migrate-layout).
#   the journal:   $PREF_DIR/migrate-layout.state (state=running|done|failed, step=..., reason=...). A run that finds "running" was cut short (a crash, a power loss): it puts everything back first.
#   opt-out:       the file $PREF_DIR/no-migrate-layout (or AQ_NO_MIGRATE_LAYOUT=1) keeps a box on the old names.
#   exit codes:    0 moved (or already moved)   1 failed, put back   2 failed, could NOT be put back completely (manual attention)   10 not applicable (custom layout, nothing installed, the new folders
#                  already exist, a folder on its own mount)   11 not quiet (an order is being placed; nothing was changed, try again at the next window)   12 opted out   13 marked migrate-failed earlier
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/layout.sh"
export TAG="MIGRATE-LAYOUT"
# shellcheck source=migrate-common.sh
. "$HERE/migrate-common.sh"      # the pieces the two moves share (the journal, the health check, the quiet check, the unit check)

TPL="${AQ_UNIT_TEMPLATE:-$HERE/apexquant.service}"
LAYOUT_FILE="$(aq_layout_file)"
UNIT_DIR="${AQ_UNIT_DIR:-$P/etc/systemd/system}"
BIN_DIR="${AQ_BIN_DIR:-$P/usr/local/bin}"
PREF_DIR="${AQ_PREF_DIR:-$P$LAY_PREF_DIR}"
BACKUP_ROOT="${AQ_BACKUP_ROOT:-$P$LAY_BACKUP_ROOT}"
export STATE; STATE="$PREF_DIR/migrate-layout.state"
JDIR="$PREF_DIR/migrate-layout"      # the originals that a rollback puts back (rebuilt for every attempt)
SAVED="$JDIR/saved"
OPTOUT_FILE="$PREF_DIR/no-migrate-layout"
FORCE="${AQ_MIGRATE_FORCE:-0}"

# the names: what the box has now (the old ones) and what it gets
O_INSTALL="$LAY_LEGACY_INSTALL_DIR"; O_DATA="$LAY_LEGACY_DATA_DIR"; O_SERVICE="$LAY_LEGACY_SERVICE"; O_CLI="$LAY_LEGACY_CLI"      # always the old names (also when a cut-short run left the layout file written: it is then put back)
N_INSTALL="$LAY_NEW_INSTALL_DIR"; N_DATA="$LAY_NEW_DATA_DIR"; N_SERVICE="$LAY_NEW_SERVICE"; N_CLI="$LAY_NEW_CLI"
DB_NAME="$LAY_DB_NAME"
OI="$P$O_INSTALL"; OD="$P$O_DATA"; NI="$P$N_INSTALL"; ND="$P$N_DATA"
export GUARD_NAMES; GUARD_NAMES="$O_SERVICE $N_SERVICE"      # the unit names the start guard covers (migrate-common.sh)

# ── the pieces (each one is a step; a step that returns non-zero fails the migration) ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
report_old_names(){      # files this installer did not make that still name the old folders: they keep working through the old-name links; named here so the owner knows
    local f list=""
    for f in "$P/etc/cron.d"/* "$P/etc/logrotate.d"/* "$P/etc/sudoers.d"/* "$P/var/spool/cron/crontabs"/* "$P/etc/nginx/sites-available"/* "$P/etc/nginx/conf.d"/* "$P/usr/local/bin"/* "$P/usr/local/sbin"/* "$UNIT_DIR"/*.service "$UNIT_DIR"/*.timer "$UNIT_DIR"/*.service.d/*.conf; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        case "$f" in */aq-update.sh|*/"$O_SERVICE".service|*/"$O_SERVICE".service.prev|*/"$O_CLI") continue ;; esac
        grep -qIE "$O_INSTALL|$O_DATA" "$f" 2>/dev/null && list="$list ${f#"$P"}"
    done
    [ -z "$list" ] || say "these files name the old folders and keep working through the old-name links:$list"
}
step_stop(){
    mkdir -p "$OD" 2>/dev/null
    printf '{"ts": %s}' "$(date +%s)" > "$OD/update_in_progress.json.tmp" 2>/dev/null && mv -f "$OD/update_in_progress.json.tmp" "$OD/update_in_progress.json" 2>/dev/null   # the next start says "after an update"
    [ -f "$OD/running.marker" ] && echo 1 > "$JDIR/had_marker"
    sysd stop "$O_SERVICE" 2>/dev/null
    local _i; for _i in 1 2 3 4 5 6 7 8; do sysd is-active --quiet "$O_SERVICE" || return 0; nap 5; done
    return 1
}
step_backup(){
    local bk="$BACKUP_ROOT/layout-$TS" db b
    mkdir -p "$bk/data" "$SAVED" && chmod 700 "$bk" || return 1
    for db in "$OD"/*.db; do
        [ -e "$db" ] || continue; b="$(basename "$db")"
        if command -v sqlite3 >/dev/null 2>&1 && sqlite3 "$db" ".backup '$bk/data/$b'" 2>/dev/null; then :
        else cp -a "$db" "$db-wal" "$db-shm" "$bk/data/" 2>/dev/null || cp -a "$db" "$bk/data/" || return 1; fi
    done
    for b in .env .aql_key .aql_install .license_key aql_pubkey.py; do [ -e "$OD/$b" ] && cp -a "$OD/$b" "$bk/data/" 2>/dev/null; done
    # every link inside the two folders (the venv's own are left alone): I = install folder, D = data folder
    { find "$OI" -maxdepth 3 -type l -not -path "$OI/venv/*" -printf 'I\t%P\t%l\n' 2>/dev/null; find "$OD" -maxdepth 2 -type l -printf 'D\t%P\t%l\n' 2>/dev/null; } > "$SAVED/links" || true
    ls -d "$OI".OLD-* "$OI".failed-* "${OI}_old" 2>/dev/null > "$SAVED/copies" || true
    echo "$bk" > "$SAVED/backup_dir"
    return 0
}
step_move_data(){ mv "$OD" "$ND"; }
step_move_install(){ mv "$OI" "$NI"; }
step_move_copies(){   # the earlier installs kept beside the install folder follow it (the updater's one retention rule counts them by the new name)
    local c n; : > "$JDIR/moved"
    while IFS= read -r c; do
        [ -n "$c" ] && [ -e "$c" ] || continue
        n="$NI${c#$OI}"
        mv "$c" "$n" || return 1
        printf '%s\t%s\n' "$c" "$n" >> "$JDIR/moved"
    done < "$SAVED/copies"
    return 0
}
link_target(){   # the target of an old link, pointed at the new names
    local t="$1"
    case "$t" in
        "$O_DATA"|"$O_DATA"/*) t="$N_DATA${t#$O_DATA}" ;;
        "$O_INSTALL"|"$O_INSTALL"/*) t="$N_INSTALL${t#$O_INSTALL}" ;;
    esac
    printf '%s' "$t"
}
step_compat_links(){   # the old names stay as links to the new folders (relative when both are in the same folder, so they also hold in a test folder)
    local ti="$N_INSTALL" td="$N_DATA"
    [ "$(dirname "$N_INSTALL")" = "$(dirname "$O_INSTALL")" ] && ti="$(basename "$N_INSTALL")"
    [ "$(dirname "$N_DATA")" = "$(dirname "$O_DATA")" ] && td="$(basename "$N_DATA")"
    ln -s "$ti" "$OI" && ln -s "$td" "$OD"
}
step_repoint_links(){
    local w rel tgt new base
    while IFS=$'\t' read -r w rel tgt; do
        [ -n "$rel" ] || continue
        new="$(link_target "$tgt")"
        [ "$new" = "$tgt" ] && continue
        if [ "$w" = I ]; then base="$NI"; else base="$ND"; fi
        ln -sfn "$new" "$base/$rel" || return 1
    done < "$SAVED/links"
    return 0
}
step_env_paths(){      # a path of the old folders in .env follows the folders, by the one rule of deploy/layout_paths.py (the original is kept for the put-back)
    [ -f "$ND/.env" ] || return 0
    cp -a "$ND/.env" "$SAVED/env" || return 1
    env_rewrite "$NI" "$ND/.env" "$N_INSTALL" "$N_DATA" "$DB_NAME" >/dev/null
}
step_settings_paths(){      # the same for a setting of the data file that holds one of the old folders (the old values are kept in $SAVED/settings.json)
    [ -f "$ND/$DB_NAME" ] || return 0
    local n; n="$(db_rewrite_settings "$NI" "$ND/$DB_NAME" "$SAVED/settings.json" "$N_INSTALL" "$N_DATA" "$DB_NAME")" || return 1
    [ -z "$n" ] || [ "$n" = 0 ] || say "$n setting(s) of the data file named the old folders and now name the new ones"
    return 0
}
step_unit(){
    local rdir src; rdir="$(mktemp -d)"; src="$rdir/$N_SERVICE.service"
    aq_render_unit "$TPL" "$N_INSTALL" "$N_DATA" "$DB_NAME" "$N_SERVICE" > "$src" || { rm -rf "$rdir"; return 1; }
    [ -s "$src" ] || { rm -rf "$rdir"; return 1; }
    if ! verify_unit "$src"; then say "the new service unit did not pass systemd's check"; rm -rf "$rdir"; return 1; fi
    sysd_files disable "$O_SERVICE" >/dev/null 2>&1      # the boot link of the old unit goes (the new unit's own is made below)
    if [ -e "$UNIT_DIR/$O_SERVICE.service" ] || [ -L "$UNIT_DIR/$O_SERVICE.service" ]; then
        cp -a "$UNIT_DIR/$O_SERVICE.service" "$UNIT_DIR/$O_SERVICE.service.prev" && rm -f "$UNIT_DIR/$O_SERVICE.service" || { rm -rf "$rdir"; return 1; }
    fi
    cp "$src" "$UNIT_DIR/$N_SERVICE.service.new" && chmod 644 "$UNIT_DIR/$N_SERVICE.service.new" && mv -f "$UNIT_DIR/$N_SERVICE.service.new" "$UNIT_DIR/$N_SERVICE.service"
    local rc=$?; rm -rf "$rdir"
    [ "$rc" = 0 ] || return "$rc"
    # an owner's drop-in files (systemctl edit) follow the unit; a path of the old folders in them is pointed at the new ones
    if [ -d "$UNIT_DIR/$O_SERVICE.service.d" ]; then
        mkdir -p "$UNIT_DIR/$N_SERVICE.service.d" && cp -a "$UNIT_DIR/$O_SERVICE.service.d/." "$UNIT_DIR/$N_SERVICE.service.d/" && rm -rf "$UNIT_DIR/$O_SERVICE.service.d" || return 1      # (the new name already has the guard's drop-in: the owner's files are merged in, never nested)
        sed -i -e "s#$O_DATA#$N_DATA#g" -e "s#$O_INSTALL#$N_INSTALL#g" "$UNIT_DIR/$N_SERVICE.service.d"/*.conf 2>/dev/null
    fi
    guard_dropins      # the guard's drop-in moved with the folder: it is written again for both names
}
step_cli(){
    mkdir -p "$BIN_DIR"
    aq_cli_shim_text "$N_INSTALL" > "$BIN_DIR/$N_CLI.new" && chmod 755 "$BIN_DIR/$N_CLI.new" && mv -f "$BIN_DIR/$N_CLI.new" "$BIN_DIR/$N_CLI" || return 1
    aq_cli_legacy_shim_text "$BIN_DIR/$N_CLI" > "$BIN_DIR/$O_CLI.new" && chmod 755 "$BIN_DIR/$O_CLI.new" && mv -f "$BIN_DIR/$O_CLI.new" "$BIN_DIR/$O_CLI"
}
step_layout(){      # the commit point: from here the bot and the scripts read the new names
    rm -f "$LAYOUT_FILE" 2>/dev/null
    _aq_adopt_new_layout keepdb      # the data file keeps its name until the second move (deploy/migrate-db-name.sh) has renamed it
}
step_start(){
    sysd daemon-reload || return 1
    sysd reset-failed "$N_SERVICE" 2>/dev/null
    sysd_files enable "$N_SERVICE" >/dev/null 2>&1 || return 1      # makes the boot link and, from the unit's Alias=, the old name
    sysd start "$N_SERVICE" || return 1
}
step_health(){ local had=0; [ -f "$JDIR/had_marker" ] && had=1; mig_health "$N_SERVICE" "$ND" "$had"; }

# ── putting everything back ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Every part looks at what is there now, so it works after a failure at any step and after a run that was cut short.
do_rollback(){
    local w rel tgt base c n
    guard_on      # nothing can start the service while it is put back (a crash in here is put right at boot by the recovery unit)
    sysd stop "$N_SERVICE" 2>/dev/null; sysd stop "$O_SERVICE" 2>/dev/null
    sysd_files disable "$N_SERVICE" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$N_SERVICE.service" "$UNIT_DIR/$N_SERVICE.service.new"
    rm -rf "$UNIT_DIR/$N_SERVICE.service.d"
    [ -d "$SAVED/dropins" ] && { rm -rf "$UNIT_DIR/$O_SERVICE.service.d"; cp -a "$SAVED/dropins" "$UNIT_DIR/$O_SERVICE.service.d"; guard_dropins; }
    [ -L "$UNIT_DIR/$O_SERVICE.service" ] && rm -f "$UNIT_DIR/$O_SERVICE.service"          # the alias
    if [ -f "$UNIT_DIR/$O_SERVICE.service.prev" ] && [ ! -e "$UNIT_DIR/$O_SERVICE.service" ]; then
        cp -a "$UNIT_DIR/$O_SERVICE.service.prev" "$UNIT_DIR/$O_SERVICE.service" && rm -f "$UNIT_DIR/$O_SERVICE.service.prev"
    fi
    rm -f "$LAYOUT_FILE"; [ -e "$SAVED/layout" ] && cp -a "$SAVED/layout" "$LAYOUT_FILE"
    rmdir "$(dirname "$LAYOUT_FILE")" 2>/dev/null      # the folder the new layout file made, when nothing else is in it
    rm -f "$BIN_DIR/$N_CLI" "$BIN_DIR/$N_CLI.new" "$BIN_DIR/$O_CLI.new"
    [ -e "$SAVED/cli" ] && cp -a "$SAVED/cli" "$BIN_DIR/$O_CLI"
    [ -L "$OI" ] && rm -f "$OI"; [ -L "$OD" ] && rm -f "$OD"
    [ -d "$NI" ] && [ ! -e "$OI" ] && mv "$NI" "$OI"
    [ -d "$ND" ] && [ ! -e "$OD" ] && mv "$ND" "$OD"
    if [ -f "$JDIR/moved" ]; then
        while IFS=$'\t' read -r c n; do [ -n "$n" ] && [ -e "$n" ] && [ ! -e "$c" ] && mv "$n" "$c"; done < "$JDIR/moved"
    fi
    if [ -f "$SAVED/links" ]; then
        while IFS=$'\t' read -r w rel tgt; do
            [ -n "$rel" ] || continue
            if [ "$w" = I ]; then base="$OI"; else base="$OD"; fi
            [ -d "$base" ] && ln -sfn "$tgt" "$base/$rel"
        done < "$SAVED/links"
    fi
    [ -f "$SAVED/env" ] && [ -d "$OD" ] && cp -a "$SAVED/env" "$OD/.env"
    [ -f "$SAVED/settings.json" ] && [ -f "$OD/$DB_NAME" ] && db_restore_settings "$OI" "$OD/$DB_NAME" "$SAVED/settings.json"
    sysd daemon-reload 2>/dev/null
    sysd_files enable "$O_SERVICE" >/dev/null 2>&1
    sysd reset-failed "$O_SERVICE" 2>/dev/null
    rm -f "$OD/update_in_progress.json"
    [ -e "$OI/main.py" ] && [ -e "$OD" ] || return 1
    guard_off      # the old state is whole again
    sysd start "$O_SERVICE" 2>/dev/null
    [ -n "${AQ_MIG_NOBLOCK:-}" ] && return 0
    nap 3
    sysd is-active --quiet "$O_SERVICE"
}
fail(){   # fail REASON - put everything back, mark the box, leave
    say "FAILED: $1 - putting everything back"
    if do_rollback; then
        scripts_cleanup
        set_state failed "$STEP" "$1"; say "everything is back as it was; this box is marked migrate-failed and is not tried again by itself"; exit 1
    fi
    set_state failed "$STEP" "$1 (rollback incomplete - manual attention)"; say "WARNING: the rollback is not complete - manual attention (backup: $(cat "$SAVED/backup_dir" 2>/dev/null))"; exit 2
}
run(){ STEP="$1"; set_state running "$STEP"; _inject "$STEP" || fail "step $STEP failed"; "step_$1" || fail "step $1 failed"; _inject "after_$1" || fail "step $1 failed afterwards"; }

# ── start ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || [ -n "${AQ_TEST_NONROOT:-}" ] || { say "must run as root"; exit 10; }
STEP=start; TS="$(date +%Y%m%d-%H%M%S)"; export START_EPOCH; START_EPOCH="$(date +%s)"
mkdir -p "$PREF_DIR" 2>/dev/null

# a run that was cut short: put everything back first (the layout file may already be written)
if [ "$(get_state)" = running ]; then
    say "an earlier run was cut short (step $(sed -n 's/^step=//p' "$STATE" | tail -n 1)) - putting everything back"
    STEP="$(sed -n 's/^step=//p' "$STATE" | tail -n 1)"
    if do_rollback; then scripts_cleanup; set_state failed "$STEP" "interrupted"; say "everything is back as it was; this box is marked migrate-failed"; exit 1; fi
    set_state failed "$STEP" "interrupted (rollback incomplete - manual attention)"; exit 2
fi
if [ "$LAY_INSTALL_DIR" = "$N_INSTALL" ] && [ "$LAY_DATA_DIR" = "$N_DATA" ] && [ "$LAY_SERVICE" = "$N_SERVICE" ] && [ "$LAY_CLI" = "$N_CLI" ]; then
    [ "$(get_state)" = "done" ] || set_state "done" "already" "already on the new names"
    say "already on the new names; everything was left as it is"; exit 0
fi
if [ "$LAY_INSTALL_DIR" != "$LAY_LEGACY_INSTALL_DIR" ] || [ "$LAY_DATA_DIR" != "$LAY_LEGACY_DATA_DIR" ] || [ "$LAY_SERVICE" != "$LAY_LEGACY_SERVICE" ] || [ "$LAY_CLI" != "$LAY_LEGACY_CLI" ] || [ "$LAY_LOG_PREFIX" != "$LAY_LEGACY_LOG_PREFIX" ]; then
    say "this box has its own layout - not changed"; exit 10
fi
layout_ok || { say "the layout file cannot be read or is not valid - not changed"; exit 10; }
if [ "$FORCE" != 1 ]; then
    [ "$(get_state)" = failed ] && { say "this box is marked migrate-failed - not tried again by itself (apexquant --migrate-layout tries it on request)"; exit 13; }
    if [ -e "$OPTOUT_FILE" ] || [ "${AQ_NO_MIGRATE_LAYOUT:-0}" = 1 ]; then say "opted out - the old names stay"; exit 12; fi
fi
[ -e "$OI/main.py" ] && [ -d "$OD" ] || { say "no installed bot found at $O_INSTALL / $O_DATA - nothing to move"; exit 10; }
[ -e "$NI" ] || [ -L "$NI" ] || [ -e "$ND" ] || [ -L "$ND" ] && { say "$N_INSTALL or $N_DATA already exists - not changed"; exit 10; }
if [ -L "$OI" ] || [ -L "$OD" ]; then say "$O_INSTALL or $O_DATA is a link - not changed"; exit 10; fi
if ! same_fs "$OI" || ! same_fs "$OD"; then say "$O_INSTALL or $O_DATA is on its own file system and cannot be renamed - not changed"; exit 10; fi
# room for the backup (twice the data files)
_need=$(( $(du -sk "$OD" 2>/dev/null | cut -f1) * 2 + 1024 )); _have="$(df -Pk "$(dirname "$BACKUP_ROOT")" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ "$_have" =~ ^[0-9]+$ ]] && [ "$_have" -lt "$_need" ]; then say "not enough free space for the backup - not changed"; exit 10; fi

# quiet: no order is being placed (wait a little for it to finish; nothing has been changed yet)
wait_quiet "$OI" "$OD/$DB_NAME" || { say "$QUIET_WHY - not now (nothing changed); it will be tried again at the next window"; exit 11; }
report_old_names

rm -rf "$JDIR"; mkdir -p "$SAVED"
# what a rollback puts back (saved before anything is changed, and before the journal says "running")
[ -e "$UNIT_DIR/$O_SERVICE.service" ] && { cp -a "$UNIT_DIR/$O_SERVICE.service" "$SAVED/unit" || { say "could not save the service unit - not changed"; exit 10; }; }
[ -e "$LAYOUT_FILE" ] && { cp -a "$LAYOUT_FILE" "$SAVED/layout" || { say "could not save the layout file - not changed"; exit 10; }; }
[ -e "$BIN_DIR/$O_CLI" ] && { cp -a "$BIN_DIR/$O_CLI" "$SAVED/cli" || { say "could not save the command - not changed"; exit 10; }; }
[ -d "$UNIT_DIR/$O_SERVICE.service.d" ] && { cp -a "$UNIT_DIR/$O_SERVICE.service.d" "$SAVED/dropins" || { say "could not save the unit's drop-in files - not changed"; exit 10; }; }
guard_on || { say "could not set the start guard - not changed"; guard_off; exit 10; }
set_state running start
say "moving $O_INSTALL -> $N_INSTALL, $O_DATA -> $N_DATA, service $O_SERVICE -> $N_SERVICE"
run stop
run backup
run move_data
run move_install
run move_copies
run compat_links
run repoint_links
run env_paths
run settings_paths
run unit
run cli
run layout
guard_lift      # the new state is whole: the service may start; a crash from here on is still put right at boot (the journal says running)
run start
run health
printf '{"ts": %s}' "$(date +%s)" > "$ND/layout_moved.json" 2>/dev/null      # the bot says "moved to its new name" once, on its next start (system/runstate.py, core/app_main.py)
set_state "done" health "moved"
guard_off
scripts_cleanup
ls -dt "$BACKUP_ROOT"/layout-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
rm -f "$OD/update_in_progress.json" "$ND/update_in_progress.json" 2>/dev/null
say "done - the box is on the new names (the old names still work as links)"
exit 0
