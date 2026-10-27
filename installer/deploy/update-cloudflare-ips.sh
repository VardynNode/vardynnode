#!/usr/bin/env bash
# update-cloudflare-ips.sh — 5.23.0-fix31-fix1
# Refreshes /etc/nginx/conf.d/cloudflare-ips.conf from Cloudflare's official lists.
# Run by cloudflare-ips.timer weekly. Safe to run manually at any time.
#
# Safety rails (LOCKED — do not relax):
#   - curl -f (fail on HTTP error) + --max-time 10
#   - Sanity gate: both CF anchor ranges must be present or REFUSE
#   - Atomic write via temp file; nginx -t validated before reload
#   - On ANY failure: keep current file, never wipe, never widen trust
set -euo pipefail

OUT="${AQ_CF_OUT:-/etc/nginx/conf.d/cloudflare-ips.conf}"      # (the override is for the tests)
TMP=$(mktemp)
CANDIDATE="${OUT}.candidate"

log() { echo "[CF-IPS] $*" | tee -a "${AQ_CF_LOG:-/var/log/cloudflare-ips-update.log}"; }
fail() { log "ERROR: $*"; rm -f "$TMP" "$CANDIDATE"; exit 1; }

log "Starting Cloudflare IP range update ($(date -u +%FT%TZ))"

# Fetch IPv4 and IPv6 lists
V4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 2>&1) \
    || fail "fetch v4 failed: $V4"
V6=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 2>&1) \
    || fail "fetch v6 failed: $V6"

# Sanity gate: must contain two known CF anchors (non-empty sane response)
echo "$V4" | grep -q "104.16.0.0/13" \
    || fail "sanity fail: 104.16.0.0/13 missing — keeping current list"
echo "$V4" | grep -q "172.64.0.0/13" \
    || fail "sanity fail: 172.64.0.0/13 missing — keeping current list"

# Build new conf
{
    echo "# Cloudflare IP ranges — auto-generated $(date -u +%FT%TZ)"
    echo "# Source: cloudflare.com/ips-v4 + /ips-v6  DO NOT EDIT (overwritten weekly)"
    echo ""
    echo "# IPv4"
    for ip in $V4; do echo "set_real_ip_from ${ip};"; done
    echo ""
    echo "# IPv6"
    for ip in $V6; do echo "set_real_ip_from ${ip};"; done
    echo ""
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
} > "$TMP"

cp "$TMP" "$CANDIDATE"
rm -f "$TMP"

# 7.3.36 (install F13): nginx is asked about the NEW list, not the old one. The candidate file sits under a name nginx does not read, so `nginx -t` used to test the CURRENT configuration and the new list went live
# untested (a bad list would have shown only at the next restart). Now: the current list is kept aside, the new one is moved in, nginx tests the real configuration, and on failure the current list is put back.
BACKUP="${OUT}.bak.$$"
if [ -f "$OUT" ]; then cp -p "$OUT" "$BACKUP"; fi
mv "$CANDIDATE" "$OUT"
if nginx -t >/dev/null 2>&1; then
    rm -f "$BACKUP"
    systemctl reload nginx
    log "CF IP ranges updated successfully ($(wc -l < "$OUT") lines)"
else
    log "nginx -t FAILED with new list — putting the current list back"
    if [ -f "$BACKUP" ]; then mv "$BACKUP" "$OUT"; else rm -f "$OUT"; fi
    exit 1
fi
