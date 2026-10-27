#!/bin/bash
# ApexQuant — Update Telegram bot token + chat ID
# Phase 4.11 (DEPLOY-2): customer-managed API key setup script.
set -euo pipefail

# ── ApexQuant setup logging + failure guidance (Phase 4.40.4) ────────────────
# Saves the full run to a log the customer can send us, and prints clear
# next-steps on ANY failure — including silent set -e/set -u aborts.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy/layout.sh"      # 7.1.4: the install layout, in one place
if [[ "${_AQ_LOGGED:-}" != "1" ]]; then
    export _AQ_LOGGED=1
    export _AQ_LOG="${LAY_LOG_PREFIX}$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
    install -m 600 /dev/null "$_AQ_LOG" 2>/dev/null || true   # pre-create at 600; perms survive a failed run
    bash "$0" "$@" 2>&1 | tee "$_AQ_LOG"
    _rc=${PIPESTATUS[0]}
    exit "$_rc"
fi

_aq_fail_footer() {
    local rc=$?
    [[ $rc -eq 0 ]] && return 0
    echo ""
    echo "=================================================================="
    echo "  ⚠  Setup did not complete (exit code $rc)."
    echo ""
    echo "  This is unexpected — we can help you fix it quickly:"
    echo "    • A full log was saved to:"
    echo "        ${_AQ_LOG:-(scroll up and copy the output above)}"
    echo "    • Email that log to:  hello@vardynnode.com"
    echo "      (or reply to your welcome email and attach it)"
    echo "    • Self-help guide:    https://vardynnode.com/faq.html"
    echo "=================================================================="
}
trap _aq_fail_footer EXIT
# ─────────────────────────────────────────────────────────────────────────────

APP_DIR="$LAY_INSTALL_DIR"
ENV_FILE="$APP_DIR/.env"
[[ -L "$APP_DIR/.env" ]] && ENV_FILE=$(readlink -f "$APP_DIR/.env")

[[ -f "$ENV_FILE" ]] || { echo "[FATAL] .env not found. Has the bot been installed?"; exit 1; }

echo "──────────────────────────────────────────────"
echo "  VardynNode — Telegram Bot Setup"
echo "──────────────────────────────────────────────"
echo ""
echo "How to get a Telegram bot token:"
echo "  1. Open Telegram, search for @BotFather"
echo "  2. Send /newbot — choose a name and username"
echo "  3. Copy the token (looks like 123456:ABC-DEF...)"
echo ""
echo "How to get your chat ID:"
echo "  1. Send /start to your new bot"
echo "  2. Open: https://api.telegram.org/bot<TOKEN>/getUpdates"
echo "  3. Find \"chat\":{\"id\": <NUMBER>} — that's your chat ID"
echo ""
read -p "Continue? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" =~ ^y(es)?$ ]] || { echo "Cancelled."; exit 0; }

read -rp "TELEGRAM_TOKEN: " TG_TOKEN
read -rp "TELEGRAM_CHAT_ID: " TG_CHAT_ID
[[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && { echo "[FATAL] Both fields required."; exit 1; }
[[ ! "$TG_TOKEN" =~ ^[0-9]+:.+ ]] && echo "[WARN] Token format looks wrong — expected format 123456:ABCDEF..."
[[ ! "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]] && echo "[WARN] Chat ID should be a number (possibly negative for groups)"

update_env_var() {
    local key="$1" value="$2" tmp="${ENV_FILE}.tmp"
    grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

update_env_var "TELEGRAM_TOKEN" "$TG_TOKEN"
update_env_var "TELEGRAM_CHAT_ID" "$TG_CHAT_ID"
chmod 600 "$ENV_FILE"
echo "[OK] Telegram config written to $ENV_FILE (chmod 600)"
echo "[OK] Restarting bot..."
systemctl restart ${LAY_SERVICE} || true
sleep 3
systemctl is-active --quiet ${LAY_SERVICE} \
    && echo "[OK] Bot running. Send a message to your bot to verify alerts." \
    || { echo "[ERROR] Bot failed to restart. Check: journalctl -u ${LAY_SERVICE} -n 50"; exit 1; }
