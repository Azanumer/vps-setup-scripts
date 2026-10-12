#!/usr/bin/env bash
#
# configure-ufw.sh — idempotent UFW firewall setup for a WordPress VPS.
#
#   sudo ./configure-ufw.sh [--ssh-port 5829] [--allow-extra 8080/tcp]
#
# Default policy: deny incoming, allow outgoing. Opens SSH (rate-limited),
# HTTP and HTTPS. Safe to re-run: only changes what is missing.
#
set -u

SSH_PORT=22
EXTRA=()

while [ $# -gt 0 ]; do
	case "$1" in
		--ssh-port)
			[ $# -ge 2 ] || { echo "error: --ssh-port needs a value" >&2; exit 2; }
			SSH_PORT="$2"; shift 2 ;;
		--allow-extra)
			[ $# -ge 2 ] || { echo "error: --allow-extra needs a rule like 8080/tcp" >&2; exit 2; }
			EXTRA+=("$2"); shift 2 ;;
		-h|--help)
			echo "Usage: configure-ufw.sh [--ssh-port N] [--allow-extra PORT/proto]"; exit 0 ;;
		*) echo "error: unknown option $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 2; }
command -v ufw >/dev/null 2>&1 || { echo "UFW is not installed (apt install ufw)." >&2; exit 2; }

# Guard: never lock yourself out when changing the SSH port over SSH.
if [ -n "${SSH_CONNECTION:-}" ] && [ "$SSH_PORT" != "22" ]; then
	if ! ufw status | grep -qw "${SSH_PORT}/tcp"; then
		echo "NOTE: you are connected over SSH on port 22; keeping 22 open as well."
		EXTRA+=("22/tcp")
	fi
fi

need() { # need <status-word> <rule-description> -> 0 if the rule already exists
	ufw status | grep -q "$1" && return 1 || return 0
}

CHANGED=0
add_rule() { # add_rule <description> <ufw-args...>
	local desc="$1"; shift
	ufw "$@" >/dev/null
	echo " + $desc"
	CHANGED=1
}

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# SSH with rate limiting (defeats casual brute-force).
if need "${SSH_PORT}/tcp.*LIMIT"; then
	ufw limit "$SSH_PORT"/tcp >/dev/null
	echo " + SSH port $SSH_PORT (rate-limited)"
	CHANGED=1
fi

need "^80/tcp" && add_rule "HTTP 80/tcp" allow 80/tcp
need "^443/tcp" && add_rule "HTTPS 443/tcp" allow 443/tcp

for rule in "${EXTRA[@]}"; do
	port="${rule%%/*}"
	if need "^${port}"; then
		add_rule "extra $rule" allow "$rule"
	fi
done

ufw --force enable >/dev/null 2>&1
ufw logging low >/dev/null

if [ "$CHANGED" -eq 0 ]; then
	echo "UFW already matches the desired state — nothing changed."
else
	echo "UFW is active with the rules above."
fi
ufw status numbered
