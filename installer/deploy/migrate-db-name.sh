#!/usr/bin/env bash
# 7.3.38: the settings are called VN_<name>; the earlier AQ_<name> is still accepted until the sunset (BACKLOG row 17) (a caller that still sets it is mapped here; VN_ wins).
_vn_env_compat() { local _v _n; for _v in $(compgen -v); do case "$_v" in AQ_*) _n="VN_${_v#AQ_}"; [ -n "${!_n:-}" ] || export "$_n=${!_v}";; esac; done; }; _vn_env_compat
# migrate-db-name.sh (7.2.0) - rename the data file apexquant.db -> vardynnode.db on a box that is already on the new folder names. Called by vn-update.sh AFTER the new version is installed and healthy
# (and by "apexquant --migrate-layout" after the folder move); safe to run again (a box that is already renamed does nothing).
#
#   why after the install: a version older than 7.1.4 names the data file in its own code. If the file were renamed under it, that version would open a NEW EMPTY database. The new version reads the name from the layout file.
#   what it does:  backs up the data files, stops the service, writes a clean checkpoint of the write-ahead log (so no -wal content is left behind), renames the data file together with its -wal / -shm companions and
#                  the copies the app keeps beside it (apexquant.db.before-*, .backup-<day>, .bak-*, ...), points the install folder's data-file link and APEXQUANT_DB_PATH (when .env sets it) at the new name, writes DB_NAME into the layout file,
#                  renders the service unit again, starts the service and checks it (the same health check as the folder move).
#   no link at the old name: SQLite names the -wal / -shm after the file it opened; a second path to the same file is a corruption risk we do not take. Every reader uses the layout's DB_PATH.
#   rollback:      the data files, the copies, the link, .env, the layout file and the unit go back; the service is started again. A box marked migrate-failed is not tried again unless a person asks for it.
#   exit codes:    0 renamed (or already)   1 failed, put back   2 failed, could NOT be put back completely   10 not applicable   11 not quiet (an order is being placed)   12 opted out   13 marked failed earlier
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/layout.sh"
export TAG="MIGRATE-DB"
# shellcheck source=migrate-common.sh
. "$HERE/migrate-common.sh"

TPL="${VN_UNIT_TEMPLATE:-$HERE/vardynnode.service}"
LAYOUT_FILE="$(vn_layout_file)"
UNIT_DIR="${VN_UNIT_DIR:-$P/etc/systemd/system}"
PREF_DIR="${VN_PREF_DIR:-$P$LAY_PREF_DIR}"
BACKUP_ROOT="${VN_BACKUP_ROOT:-$P$LAY_BACKUP_ROOT}"
export STATE; STATE="$PREF_DIR/migrate-db-name.state"      # (read by migrate-common.sh)
JDIR="$PREF_DIR/migrate-db-name"
SAVED="$JDIR/saved"
OPTOUT_FILE="$PREF_DIR/no-migrate-layout"
FORCE="${VN_MIGRATE_FORCE:-0}"

O_DB="$LAY_LEGACY_DB_NAME"; N_DB="$LAY_NEW_DB_NAME"
ID="$P$LAY_INSTALL_DIR"; DD="$P$LAY_DATA_DIR"; SVC="$LAY_SERVICE"
export GUARD_NAMES; GUARD_NAMES="$LAY_NEW_SERVICE $LAY_LEGACY_SERVICE"      # the unit names the start guard covers (migrate-common.sh)

# ── the steps ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
step_stop(){
    printf '{"ts": %s}' "$(date +%s)" > "$DD/update_in_progress.json.tmp" 2>/dev/null && mv -f "$DD/update_in_progress.json.tmp" "$DD/update_in_progress.json" 2>/dev/null
    [ -f "$DD/running.marker" ] && echo 1 > "$JDIR/had_marker"
    sysd stop "$SVC" 2>/dev/null
    local _i; for _i in 1 2 3 4 5 6 7 8; do sysd is-active --quiet "$SVC" || return 0; nap 5; done
    return 1
}
step_backup(){
    local bk="$BACKUP_ROOT/dbname-$TS" db
    mkdir -p "$bk" && chmod 700 "$bk" || return 1
    for db in "$DD"/*.db; do
        [ -e "$db" ] || continue
        cp -a "$db" "$bk/" || return 1
        [ -e "$db-wal" ] && { cp -a "$db-wal" "$bk/" || return 1; }
        [ -e "$db-shm" ] && cp -a "$db-shm" "$bk/" 2>/dev/null
    done
    echo "$bk" > "$SAVED/backup_dir"
    return 0
}
step_checkpoint(){   # all that the log holds goes into the data file; nothing may stay behind in a -wal
    local py; py="$(mig_python "$ID")"
    if [ -x "$py" ] || command -v "$py" >/dev/null 2>&1; then
        "$py" - "$DD/$O_DB" <<'PY' 2>/dev/null
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=30)
r = c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
c.close()
sys.exit(0 if r is not None and r[0] == 0 else 1)
PY
    elif command -v sqlite3 >/dev/null 2>&1; then
        [ "$(sqlite3 "$DD/$O_DB" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>/dev/null | cut -d'|' -f1)" = 0 ]
    else
        return 1
    fi
}
step_rename(){      # the data file with its companions together, then the copies the app made of itself
    local suf f rest; : > "$JDIR/moved"
    for suf in "" -wal -shm; do
        [ -e "$DD/$O_DB$suf" ] || continue
        mv "$DD/$O_DB$suf" "$DD/$N_DB$suf" || return 1
        printf '%s\t%s\n' "$DD/$O_DB$suf" "$DD/$N_DB$suf" >> "$JDIR/moved"
    done
    for f in "$DD/$O_DB".*; do      # every copy the app keeps beside the file: .before-*, .backup-<day>, .bak-*, .corrupt-*, .recovered-*, .pre-restore-* ...
        [ -e "$f" ] || continue
        rest="${f#"$DD/$O_DB".}"
        mv "$f" "$DD/$N_DB.$rest" || return 1
        printf '%s\t%s\n' "$f" "$DD/$N_DB.$rest" >> "$JDIR/moved"
    done
    [ -n "$(db_scalar "$ID" "$DD/$N_DB" 'SELECT COUNT(*) FROM sqlite_master')" ]      # the renamed file opens
}
step_integrity(){      # the renamed file is whole (checked before the service starts on it)
    [ "$(db_scalar "$ID" "$DD/$N_DB" 'PRAGMA integrity_check')" = ok ]
}
step_settings(){      # a setting that holds the path of the data file follows it (the old values are kept in $SAVED/settings.json)
    local n; n="$(db_rewrite_settings "$ID" "$DD/$N_DB" "$SAVED/settings.json" "$LAY_INSTALL_DIR" "$LAY_DATA_DIR" "$N_DB")" || return 1
    [ -z "$n" ] || [ "$n" = 0 ] || say "$n setting(s) of the data file named the old file and now name the new one"
    return 0
}
step_env(){      # APEXQUANT_DB_PATH (and any other value that names the data file) in .env, by the one rule of deploy/layout_paths.py (the original is kept for the put-back)
    [ -f "$DD/.env" ] || return 0
    env_rewrite "$ID" "$DD/.env" "$LAY_INSTALL_DIR" "$LAY_DATA_DIR" "$N_DB" >/dev/null
}
step_link(){      # the install folder's link to the data file
    rm -f "$ID/$O_DB"
    ln -sfn "$LAY_DATA_DIR/$N_DB" "$ID/$N_DB"
}
step_layout(){      # the commit point: from here the bot and the scripts read the new data file name (7.3.38: the file is edited, not written again: the four names of deploy/migrate-names.sh stay if it has already run)
    local t="$LAYOUT_FILE.tmp.$$"
    awk -v db="DB_NAME=$LAY_NEW_DB_NAME" '/^DB_NAME=/{next} {print} /^DATA_DIR=/{print db}' "$LAYOUT_FILE" > "$t" && chmod 644 "$t" && mv -f "$t" "$LAYOUT_FILE" || { rm -f "$t"; return 1; }
    _vn_layout_load
}
step_unit(){      # the unit again (its stop command names the data file)
    local rdir src rc; rdir="$(mktemp -d)"; src="$rdir/$SVC.service"
    vn_render_unit "$TPL" "$LAY_INSTALL_DIR" "$LAY_DATA_DIR" "$N_DB" "$SVC" > "$src" && [ -s "$src" ] || { rm -rf "$rdir"; return 1; }
    verify_unit "$src" || { say "the new service unit did not pass systemd's check"; rm -rf "$rdir"; return 1; }
    cp -a "$UNIT_DIR/$SVC.service" "$UNIT_DIR/$SVC.service.prev" 2>/dev/null
    cp "$src" "$UNIT_DIR/$SVC.service.new" && chmod 644 "$UNIT_DIR/$SVC.service.new" && mv -f "$UNIT_DIR/$SVC.service.new" "$UNIT_DIR/$SVC.service"
    rc=$?; rm -rf "$rdir"; return $rc
}
step_start(){
    sysd daemon-reload || return 1
    sysd reset-failed "$SVC" 2>/dev/null
    sysd start "$SVC" || return 1
}
step_health(){ local had=0; [ -f "$JDIR/had_marker" ] && had=1; mig_health "$SVC" "$DD" "$had"; }

# ── putting everything back (each part looks at what is there now) ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
do_rollback(){
    local f rest suf
    guard_on      # nothing can start the service while it is put back (a crash in here is put right at boot by the recovery unit)
    sysd stop "$SVC" 2>/dev/null
    [ -e "$SAVED/unit" ] && cp -a "$SAVED/unit" "$UNIT_DIR/$SVC.service"
    rm -f "$UNIT_DIR/$SVC.service.prev" "$UNIT_DIR/$SVC.service.new"
    [ -e "$SAVED/layout" ] && cp -a "$SAVED/layout" "$LAYOUT_FILE"
    rm -f "$LAYOUT_FILE".tmp.*
    settle_pair "$ID" "$DD/$O_DB" "$DD/$N_DB" "$TS"      # if a start made an empty file under one name, the real data is kept
    for suf in "" -wal -shm; do
        [ -e "$DD/$N_DB$suf" ] && [ ! -e "$DD/$O_DB$suf" ] && mv "$DD/$N_DB$suf" "$DD/$O_DB$suf"
    done
    for f in "$DD/$N_DB".*; do
        [ -e "$f" ] || continue
        rest="${f#"$DD/$N_DB".}"
        [ -e "$DD/$O_DB.$rest" ] || mv "$f" "$DD/$O_DB.$rest"
    done
    [ -f "$SAVED/settings.json" ] && [ -f "$DD/$O_DB" ] && db_restore_settings "$ID" "$DD/$O_DB" "$SAVED/settings.json"
    [ -e "$SAVED/env" ] && cp -a "$SAVED/env" "$DD/.env"
    rm -f "$ID/$N_DB"
    [ -e "$SAVED/dblink" ] && ln -sfn "$(cat "$SAVED/dblink")" "$ID/$O_DB"
    sysd daemon-reload 2>/dev/null
    sysd reset-failed "$SVC" 2>/dev/null
    rm -f "$DD/update_in_progress.json"
    [ -e "$DD/$O_DB" ] || return 1
    guard_off      # the old state is whole again
    sysd start "$SVC" 2>/dev/null
    [ -n "${VN_MIG_NOBLOCK:-}" ] && return 0
    nap 3
    sysd is-active --quiet "$SVC"
}
fail(){
    say "FAILED: $1 - putting everything back"
    if do_rollback; then
        scripts_cleanup
        set_state failed "$STEP" "$1"; say "everything is back as it was; this box is marked migrate-failed and is not tried again by itself"; exit 1
    fi
    set_state failed "$STEP" "$1 (rollback incomplete - manual attention)"; say "WARNING: the rollback is not complete - manual attention (backup: $(cat "$SAVED/backup_dir" 2>/dev/null))"; exit 2
}
run(){ STEP="$1"; set_state running "$STEP"; _inject "$STEP" || fail "step $STEP failed"; "step_$1" || fail "step $1 failed"; _inject "after_$1" || fail "step $1 failed afterwards"; }

# ── start ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || [ -n "${VN_TEST_NONROOT:-}" ] || { say "must run as root"; exit 10; }
STEP=start; TS="$(date +%Y%m%d-%H%M%S)"; export START_EPOCH; START_EPOCH="$(date +%s)"      # (START_EPOCH is read by migrate-common.sh)
mkdir -p "$PREF_DIR" 2>/dev/null

if [ "$(get_state)" = running ]; then      # an earlier run was cut short: put everything back first
    STEP="$(state_field step)"
    say "an earlier run was cut short (step $STEP) - putting everything back"
    if do_rollback; then scripts_cleanup; set_state failed "$STEP" "interrupted"; say "everything is back as it was; this box is marked migrate-failed"; exit 1; fi
    set_state failed "$STEP" "interrupted (rollback incomplete - manual attention)"; exit 2
fi
# 7.3.38: the layout file written by the folder move, with or without the four names that deploy/migrate-names.sh adds (it may have run first)
layout_shape_ok(){
    local cur; cur="$(cat "$LAYOUT_FILE")"
    [ "$cur" = "$(_vn_new_layout_text keepdb)" ] || [ "$cur" = "$(_vn_new_layout_text keepdb; printf '%s\n' "PREF_DIR=$LAY_NEW_PREF_DIR" "BACKUP_ROOT=$LAY_NEW_BACKUP_ROOT" "NGINX_SITE=$LAY_NEW_NGINX_SITE" "SSL_DIR=$LAY_NEW_SSL_DIR")" ]
}
if [ "$LAY_DB_NAME" = "$N_DB" ]; then
    [ "$(get_state)" = "done" ] || set_state "done" "already" "already on the new data file name"
    say "the data file already has the new name; it was left as it is"; exit 0
fi
if [ "$LAY_INSTALL_DIR" != "$LAY_NEW_INSTALL_DIR" ] || [ "$LAY_DATA_DIR" != "$LAY_NEW_DATA_DIR" ] || [ "$LAY_SERVICE" != "$LAY_NEW_SERVICE" ] || [ "$LAY_DB_NAME" != "$O_DB" ] || [ ! -f "$LAYOUT_FILE" ] \
   || ! layout_shape_ok; then
    say "this box is not on the new folder names (or has its own layout) - the data file keeps its name"; exit 10
fi
layout_ok || { say "the layout file cannot be read or is not valid - not changed"; exit 10; }
if [ "$FORCE" != 1 ]; then
    [ "$(get_state)" = failed ] && { say "this box is marked migrate-failed - not tried again by itself (apexquant --migrate-layout tries it on request)"; exit 13; }
    if [ -e "$OPTOUT_FILE" ] || [ "${VN_NO_MIGRATE_LAYOUT:-0}" = 1 ]; then say "opted out - the data file keeps its name"; exit 12; fi
fi
ls "$ID"/core/layout.* >/dev/null 2>&1 || { say "the installed version does not read the layout file yet - the data file keeps its name"; exit 10; }
[ -f "$DD/$O_DB" ] && [ ! -L "$DD/$O_DB" ] || { say "no data file $O_DB in $LAY_DATA_DIR (or it is a link) - nothing to rename"; exit 10; }
if [ -e "$DD/$N_DB" ] || [ -L "$DD/$N_DB" ]; then say "$N_DB already exists in $LAY_DATA_DIR - not changed"; exit 10; fi
_envpath="$(vn_env_file_get DB_PATH "$DD/.env")"      # 7.3.2: VARDYNNODE_DB_PATH first, then APEXQUANT_DB_PATH
if [ -n "$_envpath" ] && [ "$_envpath" != "$LAY_DATA_DIR/$O_DB" ] && [ "$_envpath" != "$LAY_LEGACY_DATA_DIR/$O_DB" ]; then say "the data file path is set to its own value in .env - not changed"; exit 10; fi
_need=$(( $(du -sk "$DD" 2>/dev/null | cut -f1) * 2 + 1024 )); _have="$(df -Pk "$(dirname "$BACKUP_ROOT")" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ "$_have" =~ ^[0-9]+$ ]] && [ "$_have" -lt "$_need" ]; then say "not enough free space for the backup - not changed"; exit 10; fi
[ -f "$UNIT_DIR/$SVC.service" ] || { say "no service unit $SVC.service - not changed"; exit 10; }
wait_quiet "$ID" "$DD/$O_DB" || { say "$QUIET_WHY - not now (nothing changed); it will be tried again at the next window"; exit 11; }

rm -rf "$JDIR"; mkdir -p "$SAVED"
cp -a "$UNIT_DIR/$SVC.service" "$SAVED/unit" && cp -a "$LAYOUT_FILE" "$SAVED/layout" || { say "could not save the unit and the layout file - not changed"; exit 10; }
[ -f "$DD/.env" ] && { cp -a "$DD/.env" "$SAVED/env" || { say "could not save .env - not changed"; exit 10; }; }
[ -L "$ID/$O_DB" ] && readlink "$ID/$O_DB" > "$SAVED/dblink"
guard_on || { say "could not set the start guard - not changed"; guard_off; exit 10; }
set_state running start
say "renaming the data file $O_DB -> $N_DB in $LAY_DATA_DIR"
run stop
run backup
run checkpoint
run rename
run integrity
run settings
run env
run link
run layout
run unit
guard_lift      # the new state is whole: the service may start; a crash from here on is still put right at boot (the journal says running)
run start
run health
set_state "done" health "renamed"
guard_off
scripts_cleanup
ls -dt "$BACKUP_ROOT"/dbname-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
rm -f "$DD/update_in_progress.json" 2>/dev/null
say "done - the data file is $N_DB now"
exit 0
