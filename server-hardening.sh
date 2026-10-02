#!/usr/bin/env bash
#
# server-hardening.sh — Basic hardening for an Ubuntu VPS.
# Sets up UFW, Fail2Ban, and safe SSH defaults.
#
# Usage: sudo ./server-hardening.sh
# NOTE: creates an SSH config backup at /etc/ssh/sshd_config.bak
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "==> UFW: default deny incoming, allow outgoing..."
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

echo "==> Fail2Ban: enabling SSH jail..."
systemctl enable --now fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF
systemctl restart fail2ban

echo "==> SSH: disabling password auth for root, keeping key auth..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# Only restart SSH if a non-root sudo user exists OR you use key auth.
# If you still log in with a password, comment the next line out first!
systemctl restart sshd

echo ""
echo "Hardening done. IMPORTANT:"
echo "  - Make sure your SSH KEY works before closing this session:"
echo "      ssh -i your-key.pem user@server"
echo "  - If you lost key access, restore: cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config"
