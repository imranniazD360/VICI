# VICIdial 12 — Complete Install Guide (OpenSUSE, no ISO)

Step-by-step documentation for the **VICI** scratch installer (`install-vicidial12-opensuse.sh`). This installs a **ViciBox 12–equivalent** stack on stock OpenSUSE Leap **without** downloading the 2GB ViciBox ISO.

| Item | Value |
| --- | --- |
| Installer version | 1.4.1+ |
| Target OS | openSUSE Leap **15.6** or **16.0** |
| Web | Apache 2 + PHP **8.2–8.3** (mod_php) |
| Database | MariaDB **10.11+** |
| Telephony | Asterisk **18.26.4** + DAHDI + VICIdial patches |
| Application | VICIdial **2.14** (SVN trunk) |
| DB schema target | **1729+** |
| Conference engine | **ConfBridge** (Asterisk 18 has no MeetMe) |

**License note:** VICIdial is AGPL software from [vicidial.org](https://www.vicidial.org/). This repo ships only the installer.

---

## Table of contents

1. [What this installer is (and is not)](#1-what-this-installer-is-and-is-not)
2. [Hardware and OS requirements](#2-hardware-and-os-requirements)
3. [Repository layout](#3-repository-layout)
4. [Commands and options](#4-commands-and-options)
5. [Roles](#5-roles)
6. [Install phases (what the script does)](#6-install-phases-what-the-script-does)
7. [Step-by-step: Hetzner dedicated (recommended)](#7-step-by-step-hetzner-dedicated-recommended)
8. [Step-by-step: Hetzner Cloud / VPS lab](#8-step-by-step-hetzner-cloud--vps-lab)
9. [After install: reboot, verify, first login](#9-after-install-reboot-verify-first-login)
10. [Default credentials and demo data](#10-default-credentials-and-demo-data)
11. [Agent softphone (required for agent UI)](#11-agent-softphone-required-for-agent-ui)
12. [Portal IP lists](#12-portal-ip-lists)
13. [Migrate an old VICIdial database](#13-migrate-an-old-vicidial-database)
14. [Important paths and files](#14-important-paths-and-files)
15. [Firewall ports](#15-firewall-ports)
16. [Day-2 operations](#16-day-2-operations)
17. [Troubleshooting](#17-troubleshooting)
18. [Installer history (git)](#18-installer-history-git)
19. [Safety rules](#19-safety-rules)

Also see:

- **[FRONT-IP-VALIDATION.md](FRONT-IP-VALIDATION.md)** — portal IP whitelist (`scripts/vicidial-front-ip.sh`)
- **[HETZNER-RESCUE.md](HETZNER-RESCUE.md)** — Rescue `installimage`, no ISO, RAM-full wget
- **[INTERVIEW.md](INTERVIEW.md)** — ports, firewall, commands, install issues, Q&A
- **[SCRIPTS-ROMAN-URDU.md](SCRIPTS-ROMAN-URDU.md)** — `scripts/vicidial-front-ip.sh` poori detail (Roman Urdu)
- **[VICI9-EXTRACTED-ROMAN-URDU.md](VICI9-EXTRACTED-ROMAN-URDU.md)** — purana Vici9 zip; VICI12 pe na chalao
- **[PACKAGES-ROMAN-URDU.md](PACKAGES-ROMAN-URDU.md)** — har zypper package kyun (cifs-utils, PHP, DAHDI, …)
- **[PORT-IP-CHANGE-ROMAN-URDU.md](PORT-IP-CHANGE-ROMAN-URDU.md)** — SIP/HTTP/RTP ports + server/public IP change

---

## 1. What this installer is (and is not)

**Is**

- A root-run bash installer for **stock OpenSUSE Leap**
- Builds Apache, PHP, MariaDB, DAHDI, patched Asterisk 18, then checks out VICIdial from SVN
- Detects conflicts (nginx, FreeSWITCH, etc.) before changing the box
- Creates demo admin, demo agents/phones, USA demo leads, ConfBridge sessions, portal IP sync

**Is not**

- Not the ViciBox ISO installer (`vicibox-express`, USB write, ISO mount)
- Commands `download-iso`, `write-usb`, and `--iso` are **rejected on purpose**
- Not a multi-tenant managed dialer product — you still configure carriers, DIDs, and production security yourself

---

## 2. Hardware and OS requirements

From `conf/requirements.conf`:

| Resource | Minimum (production-ish) | Lab (`--lab` / 4 GB auto) |
| --- | --- | --- |
| CPU | 4 cores | 2 cores (warn, compile with 1 job) |
| RAM | 8 GB (16 GB recommended) | 4 GB (one test call only) |
| Disk | 160 GB (500 GB recommended) | Smaller OK for lab |
| OS | Leap 15.6+ / 16.0 | Leap 15.6 / 16.0 |
| Arch | x86_64 | x86_64 |

Always run as **root**. Use `zypper up` only — **never** `zypper dup` on a dialer.

---

## 3. Repository layout

```text
VICI/
├── README.md                          # Short overview
├── docs/INSTALL.md                    # This guide
├── docs/HETZNER-RESCUE.md             # Rescue installimage, skip ViciBox ISO
├── docs/INTERVIEW.md                  # Ports, firewall, commands, interview Q&A
├── docs/SCRIPTS-ROMAN-URDU.md         # scripts/ folder — Roman Urdu, har command
├── docs/VICI9-EXTRACTED-ROMAN-URDU.md # vici9-extracted — Roman Urdu, har file
├── docs/PACKAGES-ROMAN-URDU.md        # zypper packages — kyun use (cifs-utils, …)
├── docs/PORT-IP-CHANGE-ROMAN-URDU.md  # ports + IP kaise badlein
├── docs/FRONT-IP-VALIDATION.md        # Portal IP whitelist
├── scripts/vicidial-front-ip.sh       # Admin IP whitelist tool
├── scripts/README.md                  # Short pointer to Roman Urdu docs
├── conf/requirements.conf             # Version/hardware targets (sourced by installer)
├── install-vicidial12-opensuse.sh     # Main installer (run this)
└── .gitignore
```

On a finished server you will also have:

| Path | Purpose |
| --- | --- |
| `/usr/src/astguiclient/trunk` | VICIdial SVN working copy |
| `/usr/share/astguiclient` | Keepalive / admin Perl scripts |
| `/srv/www/htdocs/vicidial` | Admin web UI |
| `/srv/www/htdocs/agc` | Agent web UI |
| `/etc/asterisk` | Asterisk configs (`sip-vicidial.conf`, `confbridge-vicidial.conf`, …) |
| `/root/vicidial-credentials.txt` | Generated DB + web credentials (mode 0600) |
| `/var/log/vicidial-installer/` | Installer logs |
| `/root/vicidial-backups/` | Migrate backups |

---

## 4. Commands and options

```bash
./install-vicidial12-opensuse.sh help
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
./install-vicidial12-opensuse.sh setup --yes
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
./install-vicidial12-opensuse.sh migrate --dump /root/old-asterisk.sql.gz --yes
```

| Command | Effect |
| --- | --- |
| `detect` | Scan OS, hardware, services, ports — **no changes** |
| `check` | Detect + requirements matrix |
| `setup` | Enable/start Apache, MariaDB, Asterisk, portal IP, admin, demo agents — **no rebuild** |
| `install` | Full scratch install for the selected `--role` |
| `migrate` | Backup + schema upgrade chain (+ optional dump import) |
| `help` | Usage text |

| Option | Meaning |
| --- | --- |
| `--role express\|database\|web\|telephony\|archive` | What to install |
| `--server-ip IP` | LAN/bind IP for VICIdial (default: auto) |
| `--public-ip IP` | Public IP for `sip.conf` `externip` |
| `--db-name` / `--db-user` / `--db-pass` | Database settings |
| `--yes` | Non-interactive confirmations |
| `--force` | Continue despite FAIL rows in the matrix |
| `--dry-run` | Print actions only |
| `--stop-conflicts` | Stop nginx / MySQL / FreeSWITCH / etc. |
| `--keep-conflicts` | Leave conflicting services running |
| `--skip-asterisk-build` | Keep existing Asterisk 18 |
| `--skip-firewall` | Do not change firewalld |
| `--legacy-passwords` | Historic `cron`/`1234` DB passwords (insecure) |
| `--lab` | Lab profile (2 CPU / 4 GB OK; one compile job) |
| `--jobs N` | Parallel Asterisk compile jobs |

---

## 5. Roles

| `--role` | Installs |
| --- | --- |
| `express` | DB + web + telephony on **one** box (≤ ~20 agents) |
| `database` | MariaDB, schema, TIMESTAMP fix |
| `web` | Apache + PHP + VICIdial web files |
| `telephony` | DAHDI + Asterisk 18 + keepalives |
| `archive` | vsftpd archive role |

Most single-server installs use **`express`**.

---

## 6. Install phases (what the script does)

Order for `install --role express`:

| Phase | What happens |
| --- | --- |
| 1 — Detect | OS, CPU/RAM/disk, Apache/nginx, MariaDB, Asterisk, DAHDI, ports 80/3306/5038/5060/4569, conflicts |
| Required services | Plan INSTALL + ENABLE + START for Apache, MariaDB, Asterisk, chronyd |
| 2 — Base packages | Build tools, libsrtp, jansson, SVN, screen, firewalld helpers, etc. |
| 3 — PHP + Apache | PHP 8.2–8.3, `apache2-mod_php8`, enable/start Apache, verify `:80` |
| 4 — MariaDB | Install/start MariaDB, create DB/users, `explicit_defaults_for_timestamp=Off`, `sql_mode=NO_ENGINE_SUBSTITUTION` |
| 5 — DAHDI | Timing source for conferences |
| 6 — Asterisk 18 | Download 18.26.4 (old-releases), apply VICIdial patches, build with `chan_sip` + ConfBridge, systemd unit |
| 7 — VICIdial SVN | `svn://svn.eflo.net:3690/agc_2-X/trunk`, load schema if empty, `install.pl`, migrations |
| Post-schema | Admin `6666`, demo agents/phones, USA leads, hopper seed, ConfBridge sessions, portal IP list |
| 8 — Keepalives | Crontab + boot hooks (`ADMIN_keepalive_ALL.pl`, screen sockets) |
| 9 — Firewall | HTTP `:80` only — **no SSL/443**; SIP/RTP/AMI |

Then: write `/root/vicidial-credentials.txt` and run soft verification.

---

## 7. Step-by-step: Hetzner dedicated (recommended)

### Step 0 — Order the server

- Prefer ≥ 4 CPU / 8 GB / 160 GB for real dialing
- Do **not** attach or boot the ViciBox ISO

### Step 1 — Rescue → installimage

1. Boot into **Rescue**
2. Run `installimage`
3. Choose **openSUSE Leap 15.6** (or newest Leap 15.x / 16.0 listed)
4. Set disk layout, hostname, SSH key
5. Reboot into the new OS

### Step 2 — First SSH as root

```bash
zypper ref
zypper up
reboot
```

### Step 3 — Fetch the installer

```bash
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh help
```

Or clone the repo:

```bash
git clone https://github.com/imranniazD360/VICI.git
cd VICI
chmod +x install-vicidial12-opensuse.sh
```

### Step 4 — Detect and check (safe)

```bash
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
```

Read the matrix. Fix FAIL items or plan to use `--force` only if you understand the risk.

### Step 5 — Install Express

```bash
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
```

Optional IPs:

```bash
./install-vicidial12-opensuse.sh install \
  --role express --yes --stop-conflicts \
  --server-ip YOUR.LAN.IP \
  --public-ip YOUR.PUBLIC.IP
```

Asterisk compile can take a long time. Watch `/var/log/vicidial-installer/`.

### Step 6 — Setup if Asterisk is not running

If detect shows Asterisk **NEED ENABLE + START**:

```bash
./install-vicidial12-opensuse.sh setup --yes
```

### Step 7 — Reboot and verify

```bash
reboot
# after reboot
screen -ls
asterisk -r
# in Asterisk CLI: sip show peers   then quit
```

Continue at [§9](#9-after-install-reboot-verify-first-login).

---

## 8. Step-by-step: Hetzner Cloud / VPS lab

1. Create a VM with **openSUSE Leap 15.6 or 16.0**
2. Do **not** attach the ViciBox ISO
3. SSH as root:

```bash
zypper ref && zypper up && reboot
```

4. Install (lab profile for 2 CPU / 4 GB):

```bash
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh install --lab --role express --yes --stop-conflicts
./install-vicidial12-opensuse.sh setup --yes
reboot
```

Lab boxes are for **one test call**, not production dialing.

---

## 9. After install: reboot, verify, first login

### Verify services

```bash
systemctl is-active apache2 mariadb asterisk chronyd
screen -ls
asterisk -rx "core show version"
asterisk -rx "sip show peers"
asterisk -rx "module show like confbridge"
```

Expect keepalive screens such as:

- `ASTupdate`, `ASTsend`, `ASTlisten`
- `ASTVDauto`, `ASTVDremote`, `ASTVDadapt`

### Open the web UI (HTTP only)

| Page | URL |
| --- | --- |
| Welcome | `http://YOUR.SERVER.IP/vicidial/welcome.php` |
| Admin | `http://YOUR.SERVER.IP/vicidial/admin.php` |
| Agent | `http://YOUR.SERVER.IP/agc/vicidial.php` |

There is **no SSL/443** by default. Use `http://`.

### Credentials file

```bash
cat /root/vicidial-credentials.txt
```

---

## 10. Default credentials and demo data

### Admin (change immediately)

| Field | Value |
| --- | --- |
| URL | `/vicidial/admin.php` |
| User | `6666` |
| Pass | `1234` |
| Group | `ADMIN` (full rights; `ignore_ip_list=1`) |

### Demo agents

| User | Pass | Phone login | Phone pass | Group |
| --- | --- | --- | --- | --- |
| `8001` | `8001` | `8001` | `8001` | `AGENTS` |
| `6001` | `6001` | `6001` | `6001` | `AGENTS` |
| `7001` | `7001` | `7001` | `7001` | `AGENTS` |

### Demo campaign / leads

| Item | Value |
| --- | --- |
| Campaign | `DEMOCAMP` (MANUAL) |
| List | `1001` — USA Demo Leads |
| Leads | 25 USA-only (`phone_code=1`, fiction `555-01xx`, e.g. `2125550101`) |
| Hopper | Seeded; `no_hopper_leads_logins=Y` |

### ConfBridge sessions

Installer sets `servers.conf_engine=CONFBRIDGE` and fills `vicidial_confbridges` for the real server IP (sample schema used `10.10.10.15`, which causes “no available sessions” if left unchanged).

---

## 11. Agent softphone (required for agent UI)

SIP peers are created as `host=dynamic`. The softphone **must register** before agent login works with audio.

Example for phone **8001**:

| Softphone setting | Value |
| --- | --- |
| SIP server / domain | Your server public IP |
| Username / Auth ID | `8001` |
| Password | `8001` (phone `conf_secret`) |
| Transport | UDP |
| Port | 5060 |

Apps: Zoiper, MicroSIP, Linphone, etc.

Then open `/agc/vicidial.php`:

1. Phone Login: `8001`
2. Phone Pass: `8001`
3. User: `8001`
4. Pass: `8001`
5. Campaign: `DEMOCAMP`

Check registration:

```bash
asterisk -rx "sip show peer 8001"
# Status should be OK / Reachable, not UNKNOWN
```

---

## 12. Portal IP lists

Installer enables **Allow IP Lists**, creates list `PORTAL_DYNAMIC` (LAN + public + `127.0.0.1`), assigns it to **ADMIN** admin web access, and installs:

- `/usr/local/sbin/vicidial-portal-ip-sync.sh`
- systemd timer `vicidial-portal-ip-sync.timer` (hourly + after boot)

User `6666` has `ignore_ip_list=1` so the default admin cannot lock itself out. Demo **AGENTS** group leaves agent IP lists empty for lab logins.

Add office IPs under **Admin → System Settings → IP Lists → PORTAL_DYNAMIC** for non-6666 admins.

---

## 13. Migrate an old VICIdial database

```bash
./install-vicidial12-opensuse.sh migrate --yes
./install-vicidial12-opensuse.sh migrate --dump /root/old-asterisk.sql.gz --yes
```

- Backups: `/root/vicidial-backups/<timestamp>/`
- Upgrade chain (no skipped majors):  
  `2.0.5 → 2.2 → 2.4 → 2.6 → 2.8 → 2.10 → 2.12 → 2.14` toward schema **1729+**

After migrate, run `setup --yes` and verify ConfBridge + server IP:

```bash
/usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
  --old-server_ip=OLD.IP --server_ip=NEW.IP
./install-vicidial12-opensuse.sh setup --yes
```

---

## 14. Important paths and files

| Path | Notes |
| --- | --- |
| `install-vicidial12-opensuse.sh` | Main entrypoint |
| `conf/requirements.conf` | Versions, SVN URL, Asterisk/DAHDI URLs |
| `/etc/my.cnf.d/vicidial.cnf` | TIMESTAMP / sql_mode fixes |
| `/etc/asterisk/sip-vicidial.conf` | Auto-generated SIP peers |
| `/etc/asterisk/confbridge-vicidial.conf` | Auto-generated ConfBridge profiles |
| `/etc/asterisk/extensions-vicidial.conf` | Auto-generated dialplan |
| `/usr/share/astguiclient/ADMIN_keepalive_ALL.pl` | Rebuilds conf + keepalives |
| `/usr/share/astguiclient/AST_VDhopper.pl` | Hopper loader |
| `/usr/share/astguiclient/ADMIN_update_server_ip.pl` | Rewrite `10.10.10.15` → real IP |

---

## 15. Firewall ports

Express role opens (HTTP **only** — no 443):

| Port | Protocol | Use |
| --- | --- | --- |
| 22 | TCP | SSH |
| 80 | TCP | Web UI |
| 5060 | TCP/UDP | SIP |
| 4569 | UDP | IAX |
| 5038 | TCP | AMI |
| 10000–20000 | UDP | RTP |

Keep **3306** closed to the internet on a single Express box.

---

## 16. Day-2 operations

### Reload / restart stack

```bash
systemctl reload apache2 || systemctl restart apache2
systemctl restart mariadb
systemctl restart asterisk
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES
asterisk -rx "sip reload"
asterisk -rx "dialplan reload"
asterisk -rx "module reload app_confbridge.so"
screen -ls
```

### Rebuild SIP / ConfBridge from DB

```bash
mysql -e "UPDATE asterisk.servers SET rebuild_conf_files='Y', generate_vicidial_conf='Y';"
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES
asterisk -rx "sip reload"
```

### Re-seed DEMOCAMP hopper

```bash
mysql asterisk -e "
UPDATE vicidial_campaigns SET no_hopper_leads_logins='Y', hopper_level=100 WHERE campaign_id='DEMOCAMP';
DELETE FROM vicidial_hopper WHERE campaign_id='DEMOCAMP';
INSERT INTO vicidial_hopper (lead_id,campaign_id,status,user,list_id,gmt_offset_now,state,alt_dial,priority,source,vendor_lead_code)
SELECT lead_id,'DEMOCAMP','READY','',list_id,gmt_offset_now,IFNULL(state,''),'NONE',0,'S',IFNULL(vendor_lead_code,'')
FROM vicidial_list
WHERE list_id IN (SELECT list_id FROM vicidial_lists WHERE campaign_id='DEMOCAMP' AND active='Y')
  AND status='NEW' LIMIT 100;
"
```

### Re-run setup (idempotent helpers)

```bash
./install-vicidial12-opensuse.sh setup --yes
```

---

## 17. Troubleshooting

### “Sorry, there are no leads in the hopper for this campaign”

- Lists exist but hopper is empty, or campaign blocks empty hopper.
- Fix: seed hopper (above) and set `no_hopper_leads_logins='Y'` on `DEMOCAMP`.
- Installer does this for `DEMOCAMP` automatically on fresh install/`setup`.

### “Sorry, there are no available sessions: \|\|IP\|8001\|SIP/8001\|”

- Conference rooms still on sample IP `10.10.10.15`, or MeetMe selected on Asterisk 18.
- Fix:

```bash
OLD=10.10.10.15
NEW=$(hostname -I | awk '{print $1}')   # or your public/LAN bind IP
/usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
  --old-server_ip="$OLD" --server_ip="$NEW"
mysql asterisk -e "
UPDATE servers SET conf_engine='CONFBRIDGE', rebuild_conf_files='Y', generate_vicidial_conf='Y' WHERE server_ip='$NEW';
DELETE FROM vicidial_confbridges WHERE server_ip='$NEW';
INSERT INTO vicidial_confbridges (conf_exten,server_ip,extension,leave_3way)
SELECT conf_exten,server_ip,'','0' FROM vicidial_conferences WHERE server_ip='$NEW';
UPDATE vicidial_confbridges SET extension='' WHERE server_ip='$NEW';
"
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES
```

### Softphone peer Status = UNKNOWN

- Softphone not registered. Register UDP SIP as above, then recheck `sip show peer 8001`.

### Blank admin page when saving agent/phone

- MariaDB 10.11+ TIMESTAMP / sql_mode issue.
- Installer writes `explicit_defaults_for_timestamp=Off` and `sql_mode=NO_ENGINE_SUBSTITUTION`. Re-run Phase 4 / `setup` if missing.

### Admin login blocked by IP list

- Use `6666` (`ignore_ip_list=1`), or add your IP to `PORTAL_DYNAMIC`, or run portal sync:

```bash
/usr/local/sbin/vicidial-portal-ip-sync.sh
```

### Asterisk not running after install

```bash
./install-vicidial12-opensuse.sh setup --yes
systemctl status asterisk
asterisk -vvvg   # only if systemd unit fails
```

### Conflicting services (nginx, FreeSWITCH)

```bash
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
```

---

## 18. Installer history (git)

Recent commits in this repo (high level):

| Commit theme | Meaning |
| --- | --- |
| Initial installer + ISO/DB migrate | First ultimate installer |
| Disable ISO path | Scratch-install only (Hetzner-friendly) |
| Leap 16 lab (2 CPU / 4 GB) | One-call test profile |
| DAHDI / MariaDB 11 / Apache fixes | Leap 16 compatibility |
| Demo agents, USA leads, hopper, ConfBridge | Ready-to-login lab defaults |

Always prefer the current `main` branch script when installing a new box.

---

## 19. Safety rules

1. Run as **root** on the target Leap host only.
2. Never `zypper dup` on a VICIdial box.
3. Change **6666 / 1234** immediately on any internet-facing host.
4. Demo agents **8001/6001/7001** are lab defaults — replace for production.
5. Keep **3306** off the public internet.
6. No HTTPS by design in this installer — put a reverse proxy / VPN in front if you need TLS.
7. Detection (`detect` / `check`) never installs; use it first on unknown hosts.
8. Production dialing needs a real carrier, DIDs, call times, DNC, and stronger passwords — demo data is fiction `555-01xx` only.

---

## Quick checklist

- [ ] Leap 15.6/16.0 installed (not ViciBox ISO)
- [ ] `zypper up` + reboot
- [ ] `detect` → `check`
- [ ] `install --role express --yes --stop-conflicts` (add `--lab` if small VM)
- [ ] `setup --yes` if Asterisk inactive
- [ ] Reboot → `screen -ls` + `asterisk -r`
- [ ] Admin login `6666` / `1234` → change password
- [ ] Register softphone `8001`
- [ ] Agent login → campaign `DEMOCAMP`
- [ ] Read `/root/vicidial-credentials.txt`

For a one-page overview, see the root [README.md](../README.md).
