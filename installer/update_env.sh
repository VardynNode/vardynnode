#!/bin/bash
# ApexQuant — Update optional environment variables (FRED, AI providers)
# Phase 4.11 (DEPLOY-2): customer-managed API key setup script.
# All values are optional — press Enter to skip any.
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
echo "  VardynNode — Optional API Keys"
echo "  (Press Enter to skip any key)"
echo "──────────────────────────────────────────────"
echo ""
echo "FRED_API_KEY: Free macro data (St. Louis Fed)"
echo "  Get yours at: fred.stlouisfed.org/docs/api/api_key.html"
read -rp "FRED_API_KEY (Enter to skip): " FRED_KEY
echo ""
echo "AI Provider keys (Elite tier only — for AI Commentary)"
# 7.3.4: the AI providers come from the program's one registry (core/ai_models.py): one prompt per provider key, whatever providers the installed version offers
AI_KEY_NAMES=$(cd "$APP_DIR" && "$([ -x "$APP_DIR/venv/bin/python" ] && echo "$APP_DIR/venv/bin/python" || echo python3.12)" -c 'from core import ai_models as m; print(" ".join(k for k in m.key_envs() if k != "AI_API_KEY"))' 2>/dev/null || true)
declare -A AI_KEY_VALUES
for K in $AI_KEY_NAMES; do
    read -rp "$K (Enter to skip): " AI_KEY_VALUES[$K]
done
read -rp "AI_API_KEY (custom endpoint key, Enter to skip): " CUSTOM_AI_KEY
read -rp "AI_BASE_URL (custom OpenAI-compatible endpoint URL, Enter to skip): " CUSTOM_AI_URL
read -rp "AI_MODEL (custom endpoint model name, Enter to skip): " CUSTOM_AI_MODEL

update_env_var() {
    local key="$1" value="$2" tmp="${ENV_FILE}.tmp"
    [[ -z "$value" ]] && return
    grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "[OK] ${key} updated"
}

update_env_var "FRED_API_KEY" "$FRED_KEY"
for K in $AI_KEY_NAMES; do update_env_var "$K" "${AI_KEY_VALUES[$K]}"; done
update_env_var "AI_API_KEY" "$CUSTOM_AI_KEY"
update_env_var "AI_BASE_URL" "$CUSTOM_AI_URL"
update_env_var "AI_MODEL" "$CUSTOM_AI_MODEL"
chmod 600 "$ENV_FILE"

CHANGED=0
[[ -n "$FRED_KEY" || -n "$CUSTOM_AI_KEY" || -n "$CUSTOM_AI_URL" || -n "$CUSTOM_AI_MODEL" ]] && CHANGED=1
for K in $AI_KEY_NAMES; do [[ -n "${AI_KEY_VALUES[$K]}" ]] && CHANGED=1; done
if [[ $CHANGED -eq 1 ]]; then
    echo ""; echo "[OK] .env updated (chmod 600). Restarting bot..."
    systemctl restart ${LAY_SERVICE} || true
    sleep 3
    systemctl is-active --quiet ${LAY_SERVICE} \
        && echo "[OK] Bot running." \
        || { echo "[ERROR] Bot failed to restart. Check: journalctl -u ${LAY_SERVICE} -n 50"; exit 1; }
else
    echo "No changes made."
fi
