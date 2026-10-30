#!/usr/bin/env bash
# Check a VardynNode download: its SHA-256 checksum and its minisign signature (the public key is the one pinned inside the installer and the updater).
#
#   bash verify.sh                                  download VardynNode-Setup.zip, its .sha256 and its .minisig into a temporary folder and check them
#   bash verify.sh VardynNode-Setup.zip             check a file you already have (the .sha256 and .minisig are read from next to it, or downloaded)
#   bash verify.sh VardynNode-Setup.zip <sha256>    also compare the checksum with one you copied from the Download page or from a release's notes
#
# Needs: curl, sha256sum (or shasum), minisign (sudo apt install minisign). It does not run or unpack the package.
set -euo pipefail

PUBKEY="RWRHtMOGHSz0oywqtMdW5cQkw2UE1llujBPPnUFkW1RGaz9qRFZHZKSj"
BASE="https://vardynnode.com/files"
NAME="VardynNode-Setup.zip"

fail() { echo "FAILED: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required ($2)"; }
need curl "sudo apt install curl"
need minisign "sudo apt install minisign"
if command -v sha256sum >/dev/null 2>&1; then SUM() { sha256sum "$1" | cut -d' ' -f1; }; elif command -v shasum >/dev/null 2>&1; then SUM() { shasum -a 256 "$1" | cut -d' ' -f1; }; else fail "sha256sum or shasum is required"; fi

file="${1:-}"; expect="${2:-}"
tmp=""
if [ -z "$file" ]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    file="$tmp/$NAME"
    curl -fsSL "$BASE/$NAME" -o "$file" || fail "could not download $BASE/$NAME"
fi
[ -f "$file" ] || fail "no such file: $file"
base="$(basename "$file")"
dir="$(dirname "$file")"
for ext in sha256 minisig; do
    [ -s "$dir/$base.$ext" ] || curl -fsSL "$BASE/$base.$ext" -o "$dir/$base.$ext" || fail "could not get $base.$ext"
done

got="$(SUM "$file")"
want="$(cut -d' ' -f1 < "$dir/$base.sha256" | head -n1)"
echo "checksum of the file:      $got"
echo "checksum published (.sha256): $want"
[ "$got" = "$want" ] || fail "the checksum does not match the published one"
if [ -n "$expect" ]; then
    echo "checksum you gave:         $expect"
    [ "$got" = "$expect" ] || fail "the checksum does not match the one you gave"
fi
minisign -Vm "$file" -P "$PUBKEY" -x "$dir/$base.minisig" >/dev/null 2>&1 || fail "the signature is not valid for the public key $PUBKEY"
echo "OK: the checksum matches and the signature is valid ($base)."
