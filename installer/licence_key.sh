#!/usr/bin/env bash
# 7.3.38: the settings are called VN_<name>; the earlier AQ_<name> is still accepted until the sunset (BACKLOG row 17) (a caller that still sets it is mapped here; VN_ wins).
_vn_env_compat() { local _v _n; for _v in $(compgen -v); do case "$_v" in AQ_*) _n="VN_${_v#AQ_}"; [ -n "${!_n:-}" ] || export "$_n=${!_v}";; esac; done; }; _vn_env_compat
# 7.3.37: the shell side of core/license_key.py: THE one place the scripts know what a licence key looks like.
# Two forms are valid: AQP-XXXX-XXXX-XXXX-XXXX (4 groups of 4 uppercase hex characters) and VDN-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX (6 groups).
# Usage:  . "$(dirname "$0")/licence_key.sh";  vn_key_ok "$KEY" || echo "not a key"
VN_KEY_FORMS="AQP-XXXX-XXXX-XXXX-XXXX or VDN-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"
vn_key_ok() {
    local k="${1:-}"
    k="${k#"${k%%[![:space:]]*}"}"      # surrounding blanks off
    k="${k%"${k##*[![:space:]]}"}"
    k="${k^^}"
    [[ "$k" =~ ^(AQP-[0-9A-F]{4}(-[0-9A-F]{4}){3}|VDN-[0-9A-F]{4}(-[0-9A-F]{4}){5})$ ]]
}
