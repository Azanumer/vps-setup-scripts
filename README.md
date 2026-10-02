# VPS Setup Scripts

Bash scripts for getting a fresh Ubuntu VPS production-ready: LEMP stack, hardening, free SSL, and WordPress backups.

> **Warning:** run these on a **fresh** VPS (Ubuntu 22.04/24.04) with root or sudo access. Review a script before running it — never pipe unknown scripts into bash on a production server.

## Scripts

| Script | What it does |
|---|---|
| `lemp-ubuntu.sh` | Installs Nginx + PHP-FPM + MySQL + Redis + Certbot, configures UFW |
| `server-hardening.sh` | UFW firewall, Fail2Ban, SSH hardening basics |
| `backup-wordpress.sh` | Backs up a WordPress site (files + database) with 7-day retention |

## Quick start

```bash
chmod +x lemp-ubuntu.sh
sudo ./lemp-ubuntu.sh
```

WordPress backup via cron (daily 2 AM):

```bash
0 2 * * * /opt/scripts/backup-wordpress.sh /var/www/mysite mysite_db >> /var/log/wp-backup.log 2>&1
```

MIT licensed. Contributions welcome.
