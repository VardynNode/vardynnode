#!/usr/bin/env bash
# 7.3.38: the settings are called VN_<name>; the earlier AQ_<name> is still accepted until the sunset (BACKLOG row 17) (a caller that still sets it is mapped here; VN_ wins).
_vn_env_compat() { local _v _n; for _v in $(compgen -v); do case "$_v" in AQ_*) _n="VN_${_v#AQ_}"; [ -n "${!_n:-}" ] || export "$_n=${!_v}";; esac; done; }; _vn_env_compat
# update_keys.sh — 5.23.0-fix20: Safe Binance API key update for VardynNode.
# 7.3.25: the cleared marker must be fresh (no older than an hour) and clean (no order left open); the new keys are checked against the exchange (read-only) BEFORE anything is written;
#         the override is written to a file the next start reads and logs (the old text promised a log line that nothing wrote).
# ============================================================================
#  ALWAYS run this AFTER completing "Switch Binance Account" on the dashboard.
#  Changing keys without that step may strand open orders on the old account.
#  On testnet, the bot is the ONLY way to cancel orders — no manual cancel UI.
# ============================================================================
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy/layout.sh"      # 7.1.4: the install layout, in one place
DATA_DIR="${DATA_DIR:-$LAY_DATA_DIR}"
APP_DIR="${APP_DIR:-$LAY_INSTALL_DIR}"

# 5.23.0-fix41 B4: resolve ENV_FILE to the DATA_DIR canonical .env (same file systemd reads).
# Pre-fix: bare ".env" resolved relative to CWD → key swaps went to the wrong file.
# Guard: warn + repair if $APP_DIR/.env is a plain file instead of a symlink to $DATA_DIR/.env.
if [ -f "$APP_DIR/.env" ] && [ ! -L "$APP_DIR/.env" ]; then
    echo "⚠ WARNING: $APP_DIR/.env is a plain file, not a symlink to $DATA_DIR/.env"
    echo "   Systemd reads $DATA_DIR/.env — this key update targets THAT file."
    echo "   Consider: ln -sf $DATA_DIR/.env $APP_DIR/.env"
fi
ENV_FILE="${ENV_FILE:-$DATA_DIR/.env}"
if [ ! -f "$ENV_FILE" ] && [ -f "$APP_DIR/.env" ]; then
    ENV_FILE="$APP_DIR/.env"  # fallback
fi
MARKER="$DATA_DIR/.switch_cleared"
OVERRIDE_FILE="$DATA_DIR/.switch_override"
MARKER_MAX_AGE="${VN_MARKER_MAX_AGE:-3600}"

echo ""
echo "================================================================"
echo "  VardynNode — Binance API Key Update"
echo "================================================================"
echo ""
echo "⚠️  WARNING: Changing API keys without first completing 'Switch"
echo "    Binance Account' on the dashboard may strand open bot orders"
echo "    on the old account (the bot loses access after the key change)."
echo "    On testnet there is no manual cancel UI — stranded orders cannot"
echo "    be recovered without the old credentials."
echo ""

CLEARED=0
OVERRIDDEN=0
if [ -f "$MARKER" ]; then
    # the marker carries its time and the number of orders left: a stale one (older than an hour) or one with orders left is not a cleared account
    MARKER_VERDICT=$(MARKER="$MARKER" MAXAGE="$MARKER_MAX_AGE" python3 - <<'PYEOF' 2>/dev/null || echo "unreadable"
import json, os, time
try:
    d = json.load(open(os.environ["MARKER"]))
    age = time.time() - float(d["epoch"])
    if age > float(os.environ["MAXAGE"]):
        print("stale:%d" % int(age // 60))
    elif int(d.get("open_orders") or 0) > 0:
        print("orders:%d" % int(d.get("open_orders")))
    else:
        print("ok:%s" % d.get("ts", "?"))
except Exception:
    print("unreadable")
PYEOF
)
    case "$MARKER_VERDICT" in
        ok:*)
            echo "✅ Switch-cleared marker found (cleared at ${MARKER_VERDICT#ok:})."
            echo "   Proceeding with key update."
            CLEARED=1
            ;;
        stale:*)
            echo "❌ The switch-cleared marker is ${MARKER_VERDICT#stale:} minutes old (the limit is $((MARKER_MAX_AGE / 60)) minutes)."
            echo "   Orders may have been placed since. Run 'Switch Binance Account' on the dashboard again, then run this script within the hour."
            exit 1
            ;;
        orders:*)
            echo "❌ The account was cleared with ${MARKER_VERDICT#orders:} order(s) still open."
            echo "   Run 'Switch Binance Account' on the dashboard again and wait for CLEARED."
            exit 1
            ;;
        *)
            echo "❌ The switch-cleared marker could not be read. Run 'Switch Binance Account' on the dashboard again."
            exit 1
            ;;
    esac
else
    echo "❌ No switch-cleared marker found."
    echo ""
    echo "   The safest path is:"
    echo "   1. Dashboard → Bot Config → 🔄 Switch Binance Account"
    echo "   2. Complete PIN + 2FA + double-confirm → wait for CLEARED"
    echo "   3. Then run this script again."
    echo ""
    printf "   Type SWITCH-ANYWAY to override (this is logged): "
    read -r OVERRIDE
    if [ "$OVERRIDE" != "SWITCH-ANYWAY" ]; then
        echo "Aborted. Run the dashboard Switch flow first."
        exit 1
    fi
    OVERRIDDEN=1
    echo "OVERRIDE: proceeding without a cleared marker (the next start logs it)."
fi

# Prompt for new keys
echo ""
printf "New BINANCE_API_KEY: "
read -r NEW_KEY
printf "New BINANCE_API_SECRET: "
read -rs NEW_SECRET
echo ""

if [ -z "$NEW_KEY" ] || [ -z "$NEW_SECRET" ]; then
    echo "Error: API key and secret cannot be empty."
    exit 1
fi

# 7.3.25: the new keys are checked against the exchange (one read-only call: the account) BEFORE anything is written. The keys go to the checker in its environment, never on a command line.
CHECK_MODE="$(grep -E '^TRADING_MODE=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr '[:lower:]' '[:upper:]' || true)"
if [ "$CHECK_MODE" = "TESTNET" ]; then CHECK_BASE_DEFAULT="https://testnet.binance.vision"; else CHECK_BASE_DEFAULT="https://api.binance.com"; fi
CHECK_BASE="${VN_BINANCE_BASE:-$CHECK_BASE_DEFAULT}"
KEY_VERDICT=$(AQK="$NEW_KEY" AQS="$NEW_SECRET" AQB="$CHECK_BASE" python3 - <<'PYEOF' 2>/dev/null || echo "unreachable"
import hmac, hashlib, json, os, time, urllib.request, urllib.error
base = os.environ["AQB"].rstrip("/")
q = "timestamp=%d&recvWindow=10000" % int(time.time() * 1000)
sig = hmac.new(os.environ["AQS"].encode(), q.encode(), hashlib.sha256).hexdigest()
req = urllib.request.Request(base + "/api/v3/account?" + q + "&signature=" + sig, headers={"X-MBX-APIKEY": os.environ["AQK"]})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.loads(r.read().decode())
    print("ok" if "balances" in d else "unexpected")
except urllib.error.HTTPError as e:
    try:
        code = json.loads(e.read().decode()).get("code")
    except Exception:
        code = None
    print("refused:%s" % (code if code is not None else e.code))
except Exception:
    print("unreachable")
PYEOF
)
case "$KEY_VERDICT" in
    ok)
        echo "✅ The exchange accepted the new keys (read-only check)."
        ;;
    refused:*)
        echo "❌ The exchange refused the new keys (code ${KEY_VERDICT#refused:}): check the key, the secret and the IP restriction. Nothing was written."
        exit 1
        ;;
    *)
        echo "❌ The new keys could not be checked against the exchange (no answer, or an unexpected one). Nothing was written; try again in a minute."
        exit 1
        ;;
esac

# Back up the current .env
cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# Update BINANCE_API_KEY and BINANCE_API_SECRET in-place
sed -i "s|^BINANCE_API_KEY=.*|BINANCE_API_KEY=$NEW_KEY|" "$ENV_FILE"
sed -i "s|^BINANCE_API_SECRET=.*|BINANCE_API_SECRET=$NEW_SECRET|" "$ENV_FILE"

echo "✅ Keys updated in $ENV_FILE."
echo ""
if [ $CLEARED -eq 1 ]; then
    rm -f "$MARKER"
    echo "   Cleared-marker removed."
fi
if [ $OVERRIDDEN -eq 1 ]; then
    # the next start reads this file and logs it once (and keeps it in the audit table)
    printf '{"ts": "%s", "user": "%s"}\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "${SUDO_USER:-${USER:-unknown}}" > "$OVERRIDE_FILE"
    echo "   The override is recorded; the next start logs it."
fi
echo "   Restart VardynNode to connect with the new account:"
echo "   systemctl restart ${LAY_SERVICE}"
echo ""
