#!/usr/bin/env bash
# 7.3.37: the shell side of core/license_key.py: THE one place the scripts know what a licence key looks like.
# Two forms are valid: AQP-XXXX-XXXX-XXXX-XXXX (4 groups of 4 uppercase hex characters) and VDN-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX (6 groups).
# Usage:  . "$(dirname "$0")/licence_key.sh";  aq_key_ok "$KEY" || echo "not a key"
AQ_KEY_FORMS="AQP-XXXX-XXXX-XXXX-XXXX or VDN-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
aq_key_ok() {
    local k="${1:-}"
    k="${k#"${k%%[![:space:]]*}"}"      # surrounding blanks off
    k="${k%"${k##*[![:space:]]}"}"
    k="${k^^}"
    [[ "$k" =~ ^(AQP-[0-9A-F]{4}(-[0-9A-F]{4}){3}|VDN-[0-9A-F]{4}(-[0-9A-F]{4}){5})$ ]]
}
