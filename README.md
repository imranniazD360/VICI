# VICIdial 12 Ultimate Installer (OpenSUSE)

One bash script that **detects everything first**, checks the host against the ViciBox 12.0.2 stack, then installs VICIdial from the OS box through Asterisk — optionally from a ViciBox 12 ISO — and migrates older databases in schema order.

Target stack (official ViciBox **12.0.2**):

| Layer | Required |
| --- | --- |
| OS | openSUSE Leap **15.6** (ViciBox 12 image or stock Leap) |
| PHP | **8.2** (not 7.x; `mysql_*` is gone) |
| Database | MariaDB **10.11+** with `explicit_defaults_for_timestamp = Off` |
| Telephony | Asterisk **18** with the five VICIdial patches |
| Application | VICIdial **2.14** SVN trunk, DB schema **1729+** |

Copy `install-vicidial12-opensuse.sh` to the server and run it as **root**. Do not use `zypper dup` on a ViciDial box.

```bash
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh help
```

## What it does (always in this order)

1. **Detect other services** — Apache, nginx, PHP-FPM, MariaDB/MySQL, PostgreSQL, Asterisk, DAHDI, FreeSWITCH, Kamailio, Postfix, firewalld, Docker, chronyd, existing VICIdial/ViciBox, and listeners on 80/443/3306/5038/5060/4569.
2. **Requirements matrix** — CPU, RAM, disk, OS, arch, PHP version, Asterisk version, MariaDB version, DB schema, time sync, SELinux/AppArmor. Each row is PASS / WARN / FAIL.
3. **Conflicts** — nginx/lighttpd vs Apache, MySQL vs MariaDB, FreeSWITCH vs Asterisk. Stop them with `--stop-conflicts` or keep them with `--keep-conflicts --force`.
4. **ISO (optional)** — verify checksum, mount, look for RPM `repodata`, add a zypper repo when present. On a ViciBox-installed OS, Phase 2 uses `vicibox-express` / `vicibox-install`.
5. **Install box → Asterisk** — base packages, PHP 8.2 + Apache, MariaDB + TIMESTAMP bugfix, DAHDI, Asterisk 18 (patched), VICIdial SVN, schema, crontab, firewall.
6. **Database migration** — backup, optional dump import, then `upgrade_2.0.5.sql` → `2.2` → `2.4` → `2.6` → `2.8` → `2.10` → `2.12` → `2.14` without skipping majors.

## Commands

### 1. Detect only (no changes)

```bash
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
```

`check` prints the requirements table and exits non-zero if anything FAILs.

### 2. Install from a ViciBox 12 ISO

**Path A — boot the ISO (Phase 1), then this script (Phase 2)**

```bash
# On any machine: fetch the official image
./install-vicidial12-opensuse.sh download-iso --iso /root/ViciBox_V12.x86_64-12.0.2.iso

# Write USB (destroys that device)
./install-vicidial12-opensuse.sh write-usb \
  --iso /root/ViciBox_V12.x86_64-12.0.2.iso \
  --device /dev/sdb

# Boot the target server from that USB, finish the ViciBox OS install,
# set a static IP (`yast lan`), timezone (`vicibox-timezone`), then:
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
```

**Path B — already on openSUSE Leap 15.6, ISO file on disk**

```bash
./install-vicidial12-opensuse.sh iso-verify --iso /root/ViciBox_V12.x86_64-12.0.2.iso
./install-vicidial12-opensuse.sh install \
  --iso /root/ViciBox_V12.x86_64-12.0.2.iso \
  --role express \
  --yes --stop-conflicts
```

Official ISO URLs:

- Standard (single disk / VM / hardware RAID): `https://download.vicidial.com/iso/vicibox/server/ViciBox_V12.x86_64-12.0.2.iso`
- MD RAID1: `https://download.vicidial.com/iso/vicibox/server/ViciBox_V12.x86_64-12.0.2-md.iso`

### 3. Scratch install on stock openSUSE Leap 15.6 (no ISO)

Builds the same stack from zypper packages + Asterisk 18 source with VICIdial patches:

```bash
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
```

Roles:

| `--role` | What gets installed |
| --- | --- |
| `express` | Database + web + telephony on one box (≤ ~20 agents) |
| `database` | MariaDB, schema, TIMESTAMP fix |
| `web` | Apache + PHP 8.2 + VICIdial web files |
| `telephony` | DAHDI + Asterisk 18 + keepalives |
| `archive` | vsftpd archive role |

### 4. Database migration

Never skip major SQL files. The script walks the chain in order and re-applies `upgrade_2.14.sql` for incremental schema on already-2.14 systems.

```bash
# Upgrade the local asterisk database in place
./install-vicidial12-opensuse.sh migrate --yes

# Import an old dump, then walk schema upgrades
./install-vicidial12-opensuse.sh migrate --dump /root/old-asterisk.sql.gz --yes
```

A gzip-verified backup is written under `/root/vicidial-backups/<timestamp>/` first.

## PHP, Asterisk, and MariaDB gates

- **PHP &lt; 8.0** already installed → FAIL (VICIdial 2.14 will break).
- **PHP 8.0–8.1** → WARN (installer still tries to put 8.2 on Leap 15.6).
- **PHP 8.2** → PASS.
- **Asterisk 11/13** already installed → FAIL (rebuild required; use `--force` plus a maintenance window).
- **Asterisk 18** → PASS.
- **MariaDB 10.11** → PASS, and the ViciBox 12.0.1 TIMESTAMP bugfix is applied:

```bash
echo "explicit_defaults_for_timestamp = Off" >> /etc/my.cnf.d/general.cnf
systemctl restart mariadb
```

Passwords are random by default and stored mode `0600` in `/root/vicidial-credentials.txt`. `--legacy-passwords` keeps the historic `cron/1234` pair (insecure).

## After install

```bash
reboot
screen -ls          # expect ~10–12 keepalive sockets after a few minutes
asterisk -r         # sendcron should log on/off
```

Open `http://<server-ip>/vicidial/welcome.php` — default admin is **6666 / 1234**. Change it immediately.

Firewall (Express): TCP 80/443/22, UDP/TCP 5060, UDP 4569, TCP 5038, UDP **10000–20000** (RTP). Port **3306 stays closed** to the internet on a single box.

## Options

| Flag | Meaning |
| --- | --- |
| `--iso PATH` | ViciBox 12 ISO |
| `--role express` | Server role |
| `--server-ip` / `--public-ip` | Bind IP and `sip.conf` `externip` |
| `--yes` | Non-interactive |
| `--force` | Continue despite FAIL rows |
| `--dry-run` | Print actions only |
| `--stop-conflicts` | Stop nginx/MySQL/FreeSWITCH/etc. |
| `--skip-asterisk-build` | Keep an existing Asterisk |
| `--skip-firewall` | Do not change firewalld |
| `--legacy-passwords` | Historic VICIdial DB passwords |

Logs: `/var/log/vicidial-installer/`.

## Safety

- This script **changes the target server** (packages, services, database, firewall). Run `detect` / `check` first.
- It does not replace a full ViciBox Phase 1 disk install; for a from-USB OS install, still boot the official ISO, then use this script for detection, Phase 2, bugfixes, and schema migration.
- VICIdial itself is AGPL software from [vicidial.org](https://www.vicidial.org/). This repository only ships the installer.
