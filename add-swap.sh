#!/usr/bin/env bash
#
# add-swap.sh — create and enable a swapfile on a low-RAM VPS (Ubuntu).
# Prevents OOM kills on 1GB RAM boxes (mail servers, small LEMP stacks).
# Usage: sudo ./add-swap.sh [SIZE_GB]   (default: 2)

set -euo pipefail

SIZE_GB="${1:-2}"
SWAPFILE="/swapfile"

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root or with sudo." >&2
    exit 1
fi

# Already have swap? Nothing to do.
if swapon --show=NAME --noheadings | grep -q .; then
    echo "Swap is already active:"
    swapon --show
    exit 0
fi

echo "Creating ${SIZE_GB}GB swapfile at $SWAPFILE..."
fallocate -l "${SIZE_GB}G" "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1G count="$SIZE_GB"
chmod 600 "$SWAPFILE"
mkswap "$SWAPFILE"
swapon "$SWAPFILE"

# Persist across reboots
grep -q "$SWAPFILE" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab

# Gentle tuning: use swap only when RAM is really needed
sysctl -w vm.swappiness=10 >/dev/null
grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf

echo "Done. Current swap:"
free -h
