#!/bin/bash
# 7.3.38: the settings are called VN_<name>; the earlier AQ_<name> is still accepted until the sunset (BACKLOG row 17) (a caller that still sets it is mapped here; VN_ wins).
_vn_env_compat() { local _v _n; for _v in $(compgen -v); do case "$_v" in AQ_*) _n="VN_${_v#AQ_}"; [ -n "${!_n:-}" ] || export "$_n=${!_v}";; esac; done; }; _vn_env_compat
# VardynNode — Activate license key (for customers who deployed in trial mode)
# Phase 4.11.2 (fix17q-DEPLOY-5 FEATURE)
#
# Use this after purchasing Starter/Pro/Elite tier to activate your license.
# Bot switches from trial mode to licensed mode after restart.

set -euo pipefail

# ── VardynNode setup logging + failure guidance (Phase 4.40.4) ────────────────
# Saves the full run to a log the customer can send us, and prints clear
# next-steps on ANY failure — including silent set -e/set -u aborts.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy/layout.sh"      # 7.1.4: the install layout, in one place
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/licence_key.sh"      # 7.3.37: what a licence key looks like, in one place (AQP- and VDN-)
if [[ "${_VN_LOGGED:-}" != "1" ]]; then
    export _VN_LOGGED=1
    export _VN_LOG="${LAY_LOG_PREFIX}$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
    install -m 600 /dev/null "$_VN_LOG" 2>/dev/null || true   # pre-create at 600; perms survive a failed run
    bash "$0" "$@" 2>&1 | tee "$_VN_LOG"
    _rc=${PIPESTATUS[0]}
    exit "$_rc"
fi

_vn_fail_footer() {
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    echo ""
    echo "=================================================================="
    echo "  ⚠  Setup did not complete (exit code $rc)."
    echo ""
    echo "  This is unexpected — we can help you fix it quickly:"
    echo "    • A full log was saved to:"
    echo "        ${_VN_LOG:-(scroll up and copy the output above)}"
    echo "    • Email that log to:  hello@vardynnode.com"
    echo "      (or reply to your welcome email and attach it)"
    echo "    • Self-help guide:    https://vardynnode.com/faq.html"
    echo "=================================================================="
}
trap _vn_fail_footer EXIT
# ─────────────────────────────────────────────────────────────────────────────

APP_DIR="$LAY_INSTALL_DIR"
# A1c (4.40.1): primary key file is .license_key (matches checker.py KEY_FILE default).
# .aql_key kept as legacy read-fallback in checker.py; do NOT delete it.
LICENSE_KEY_FILE="$APP_DIR/.license_key"
AQL_KEY_FILE="$APP_DIR/.aql_key"    # legacy — kept for back-compat, not written here

[[ -d "$APP_DIR" ]] || { echo "[FATAL] VardynNode not installed at $APP_DIR"; exit 1; }
cd "$APP_DIR"

echo "──────────────────────────────────────────────"
echo "  VardynNode — License Activation"
echo "──────────────────────────────────────────────"
echo ""

if [[ -f "$LICENSE_KEY_FILE" ]] && [[ -s "$LICENSE_KEY_FILE" ]]; then
    echo "Current state: LICENSED"
    echo "Existing license: $LICENSE_KEY_FILE"
    echo ""
    read -p "Replace existing license? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" =~ ^y(es)?$ ]] || { echo "Cancelled."; exit 0; }
else
    echo "Current state: TRIAL MODE (no license configured)"
    echo ""
fi

echo "Format expected: $VN_KEY_FORMS"
echo ""
read -rp "Paste your license key: " LICENSE_KEY

[[ -z "$LICENSE_KEY" ]] && { echo "[FATAL] Empty license key."; exit 1; }

if ! vn_key_ok "$LICENSE_KEY"; then
    echo "[WARN] That does not look like a licence key ($VN_KEY_FORMS)"
    read -p "Continue anyway? [y/N]: " CONFIRM2
    [[ "${CONFIRM2,,}" =~ ^y(es)?$ ]] || { echo "Cancelled."; exit 0; }
fi

# 7.3.37: a key of either form is stored as the licence server knows it: capitals, no blanks around (the dashboard, Telegram and the setup page store it the same way)
if vn_key_ok "$LICENSE_KEY"; then LICENSE_KEY="${LICENSE_KEY//[[:space:]]/}"; LICENSE_KEY="${LICENSE_KEY^^}"; fi
echo -n "$LICENSE_KEY" > "$LICENSE_KEY_FILE"
chmod 600 "$LICENSE_KEY_FILE"
echo "[OK] License key written to $LICENSE_KEY_FILE (chmod 600)"
echo ""
echo "Restarting bot to activate license..."
systemctl restart ${LAY_SERVICE} || true
sleep 3

if systemctl is-active --quiet ${LAY_SERVICE}; then
    echo "[OK] Bot restarted successfully"
    echo ""
    echo "Check license status:"
    echo "  journalctl -u ${LAY_SERVICE} -n 30 --no-pager | grep -i license"
    echo "Or view in dashboard → License panel"
else
    echo "[ERROR] Bot failed to restart. Check: journalctl -u ${LAY_SERVICE} -n 50 --no-pager"
    exit 1
fi
