# VICIdial 12 installer for OpenSUSE (no ISO)

Scratch-install VICIdial 12 on **stock openSUSE Leap 15.6**. It does **not** download, mount, or boot the 2GB ViciBox ISO — that transfer is too slow on Hetzner and similar hosts.

The script detects services first, then builds the ViciBox 12.0.2 stack from packages and source:

| Layer | Installed |
| --- | --- |
| OS | openSUSE Leap **15.6** or **16.0** (Hetzner `installimage` or any Leap VPS) |
| Web | **Apache** (`apache2`) — checked, installed if missing, enabled, started, port 80 verified |
| PHP | **8.2–8.4** + `apache2-mod_php8` |
| Database | MariaDB **10.11+** — same install/enable/start/ping pattern + `explicit_defaults_for_timestamp = Off` |
| Telephony | Asterisk **18** with the five VICIdial patches + DAHDI |
| Application | VICIdial **2.14** SVN trunk, DB schema **1729+** |

Run as **root**. Never use `zypper dup`.

```bash
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh help
```

## Hetzner dedicated (recommended)

1. Boot **Rescue**, then install Leap from Hetzner mirrors (not the ViciBox ISO):

```text
installimage
```

Pick **openSUSE Leap 15.6** (or the newest Leap 15.x they list), disk layout, hostname, and SSH key. Reboot into the new OS.

2. SSH in as root and install VICIdial:

```bash
zypper ref
zypper up
reboot

# after reboot
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
```

3. Reboot again, then:

```bash
screen -ls
asterisk -r
```

Open `http://YOUR.SERVER.IP/vicidial/welcome.php` — default login **6666 / 1234** (change it). Credentials: `/root/vicidial-credentials.txt`.

Hetzner Cloud: create a VM, choose openSUSE Leap **15.6 or 16.0**. Do not attach the ViciBox ISO.

A **2 CPU / 4 GB / Leap 16.0** box is a lab profile. The script will warn (not fail) and compile Asterisk with one job so it can place a single test call. That is not a production dialer.

```bash
./install-vicidial12-opensuse.sh install --lab --role express --yes --stop-conflicts
```

(`--lab` is optional: 4 GB RAM auto-enables the same profile.)

## What the script does

1. **Detect services** — Apache, nginx, PHP-FPM, MariaDB/MySQL, PostgreSQL, Asterisk, DAHDI, FreeSWITCH, Kamailio, Postfix, firewalld, Docker, chronyd, existing VICIdial, ports 80/443/3306/5038/5060/4569.
2. **Required-service plan** — for the selected `--role`, print whether Apache / MariaDB / Asterisk / chronyd need **INSTALL + ENABLE + START** (same lifecycle as the database).
3. **Requirements matrix** — CPU, RAM, disk, OS, PHP, Apache, Asterisk, MariaDB, schema, time sync, SELinux/AppArmor.
4. **Conflicts** — stop nginx/MySQL/FreeSWITCH with `--stop-conflicts`.
5. **Scratch install** — zypper packages, PHP 8.2–8.4, Apache enable/start/port 80, MariaDB TIMESTAMP fix + ping, DAHDI, patched Asterisk 18, SVN, schema, crontab, firewall.
6. **Database migration** — backup, optional dump import, then `upgrade_2.0.5` → `2.2` → `2.4` → `2.6` → `2.8` → `2.10` → `2.12` → `2.14` (no skipped majors).

ISO commands (`download-iso`, `write-usb`, `--iso`) are rejected on purpose.

## Roles

```bash
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
```

| `--role` | What gets installed |
| --- | --- |
| `express` | Database + web + telephony on one box (≤ ~20 agents) |
| `database` | MariaDB, schema, TIMESTAMP fix |
| `web` | Apache (install/enable/start/:80) + PHP 8.2–8.4 + VICIdial web files |
| `telephony` | DAHDI + Asterisk 18 + keepalives |
| `archive` | vsftpd archive role |

## Migrate an old database

```bash
./install-vicidial12-opensuse.sh migrate --yes
./install-vicidial12-opensuse.sh migrate --dump /root/old-asterisk.sql.gz --yes
```

Backups go to `/root/vicidial-backups/<timestamp>/`.

## Options

| Flag | Meaning |
| --- | --- |
| `--role express` | Server role |
| `--server-ip` / `--public-ip` | Bind IP and `sip.conf` `externip` |
| `--yes` | Non-interactive |
| `--force` | Continue despite FAIL rows |
| `--dry-run` | Print actions only |
| `--stop-conflicts` | Stop nginx/MySQL/FreeSWITCH/etc. |
| `--skip-asterisk-build` | Keep an existing Asterisk 18 |
| `--skip-firewall` | Do not change firewalld |
| `--legacy-passwords` | Historic VICIdial DB passwords |

Logs: `/var/log/vicidial-installer/`.

Firewall (Express): TCP 80/443/22, UDP/TCP 5060, UDP 4569, TCP 5038, UDP **10000–20000**. Keep **3306** closed to the internet.

VICIdial is AGPL software from [vicidial.org](https://www.vicidial.org/). This repository only ships the installer.
