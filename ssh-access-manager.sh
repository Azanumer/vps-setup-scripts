#!/usr/bin/env bash
#
# ssh-access-manager.sh — Manage SSH authorized_keys for a user, safely.
#
# Keys added by this tool are tagged with a comment prefix "managed:<label>"
# so --list/--remove can distinguish managed keys from hand-edited ones.
# Every write backs up authorized_keys first, sets strict 600/700 perms,
# and validates keys with ssh-keygen before touching anything.
#
# Usage:
#   ./ssh-access-manager.sh --user deploy --add "ssh-ed25519 AAAA... alice@laptop" --label alice-laptop
#   ./ssh-access-manager.sh --user deploy --list
#   ./ssh-access-manager.sh --user deploy --remove --label alice-laptop
#   ./ssh-access-manager.sh --user deploy --remove-key "ssh-ed25519 AAAA..."
#   ./ssh-access-manager.sh --user deploy --revoke-all --yes     # offboarding: drop every managed key
#
# Run as root (or the target user with --user $USER).

set -euo pipefail

TARGET_USER=""
LABEL=""
ADD_KEY=""
REMOVE_KEY=""
ACTION=""
ASSUME_YES=0

usage() {
    sed -n '2,18p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)       TARGET_USER="$2"; shift 2 ;;
        --add)        ADD_KEY="$2"; ACTION="add"; shift 2 ;;
        --label)      LABEL="$2"; shift 2 ;;
        --list)       ACTION="list"; shift ;;
        --remove)     ACTION="remove"; shift ;;
        --remove-key) REMOVE_KEY="$2"; ACTION="remove-key"; shift 2 ;;
        --revoke-all) ACTION="revoke-all"; shift ;;
        --yes)        ASSUME_YES=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$TARGET_USER" ]]; then
    echo "ERROR: --user is required" >&2; usage; exit 2
fi
if [[ -z "$ACTION" ]]; then
    echo "ERROR: one of --add/--list/--remove/--remove-key/--revoke-all is required" >&2; usage; exit 2
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$TARGET_USER' does not exist" >&2; exit 2
fi
if [[ "$ACTION" == "add" && -z "$LABEL" ]]; then
    echo "ERROR: --label is required with --add (e.g. alice-laptop)" >&2; exit 2
fi

HOME_DIR="$(eval echo "~$TARGET_USER")"
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

ensure_ssh_dir() {
    if [[ ! -d "$SSH_DIR" ]]; then
        mkdir -p "$SSH_DIR"
    fi
    if [[ ! -f "$AUTH_KEYS" ]]; then
        touch "$AUTH_KEYS"
    fi
    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
    chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
}

backup() {
    local bak="$AUTH_KEYS.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$AUTH_KEYS" "$bak"
    echo "Backup: $bak"
}

# Validate a key line without writing it anywhere.
validate_key() {
    local key="$1"
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$key" > "$tmp"
    if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

fingerprint_of() {
    local key="$1"
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$key" > "$tmp"
    ssh-keygen -l -f "$tmp" 2>/dev/null | awk '{print $2, $4}'
    rm -f "$tmp"
}

list_keys() {
    ensure_ssh_dir
    local i=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        i=$((i + 1))
        local managed=""
        if [[ "$line" =~ managed:([^[:space:]]+) ]]; then
            managed=" [managed:${BASH_REMATCH[1]}]"
        fi
        local fp
        fp="$(fingerprint_of "$line" || echo 'INVALID KEY')"
        printf '%d) %s%s\n   %s\n' "$i" "$fp" "$managed" "$line"
    done < "$AUTH_KEYS"
    [[ "$i" -eq 0 ]] && echo "(no keys)"
}

case "$ACTION" in
    list)
        echo "Authorized keys for $TARGET_USER:"
        list_keys
        ;;

    add)
        if ! validate_key "$ADD_KEY"; then
            echo "ERROR: the provided key failed ssh-keygen validation — not added" >&2
            exit 2
        fi
        ensure_ssh_dir
        # Exact-line dedupe.
        if grep -qxF "$ADD_KEY" "$AUTH_KEYS" 2>/dev/null; then
            echo "Key already present — nothing to do."
            exit 0
        fi
        # Same key material under another label? warn, don't duplicate.
        local newfp existing
        newfp="$(fingerprint_of "$ADD_KEY")"
        existing="$(list_keys | grep -F "$newfp" || true)"
        if [[ -n "$existing" ]]; then
            echo "WARNING: this key material is already installed:"
            echo "$existing"
            echo "Use --remove with the old label first, or press Ctrl-C to abort."
            if [[ "$ASSUME_YES" -eq 0 ]]; then read -r -p "Add anyway? [y/N] " ans; [[ "$ans" == [yY] ]] || exit 0; fi
        fi
        backup
        printf '%s managed:%s\n' "$ADD_KEY" "$LABEL" >> "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        echo "Added key ($newfp) as managed:$LABEL for $TARGET_USER"
        ;;

    remove)
        if [[ -z "$LABEL" ]]; then
            echo "ERROR: --label is required with --remove" >&2; exit 2
        fi
        ensure_ssh_dir
        if ! grep -q "managed:$LABEL" "$AUTH_KEYS" 2>/dev/null; then
            echo "No managed key with label '$LABEL' found."
            exit 0
        fi
        backup
        grep -v "managed:$LABEL" "$AUTH_KEYS" > "$AUTH_KEYS.tmp" || true
        mv "$AUTH_KEYS.tmp" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        echo "Removed managed key(s) with label '$LABEL' for $TARGET_USER"
        ;;

    remove-key)
        if ! validate_key "$REMOVE_KEY"; then
            echo "ERROR: the provided key failed validation" >&2; exit 2
        fi
        ensure_ssh_dir
        if ! grep -qxF "$REMOVE_KEY" "$AUTH_KEYS" 2>/dev/null; then
            echo "That exact key line is not present."
            exit 0
        fi
        backup
        grep -vxF "$REMOVE_KEY" "$AUTH_KEYS" > "$AUTH_KEYS.tmp" || true
        mv "$AUTH_KEYS.tmp" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        echo "Removed key for $TARGET_USER"
        ;;

    revoke-all)
        ensure_ssh_dir
        if ! grep -q "managed:" "$AUTH_KEYS" 2>/dev/null; then
            echo "No managed keys to revoke."
            exit 0
        fi
        echo "The following managed keys will be REVOKED for $TARGET_USER:"
        grep "managed:" "$AUTH_KEYS"
        if [[ "$ASSUME_YES" -eq 0 ]]; then
            read -r -p "Revoke all managed keys? [y/N] " ans
            [[ "$ans" == [yY] ]] || { echo "Aborted."; exit 0; }
        fi
        backup
        grep -v "managed:" "$AUTH_KEYS" > "$AUTH_KEYS.tmp" || true
        mv "$AUTH_KEYS.tmp" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        echo "All managed keys revoked for $TARGET_USER (hand-edited keys untouched)"
        ;;
esac
