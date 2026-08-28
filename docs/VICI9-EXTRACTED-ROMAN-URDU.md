# `vici9-extracted/` — poori documentation (Roman Urdu)

Yeh folder **`vici9install.zip`** se nikaala gaya **purana ViciBox 9** install pack hai (Dialer360 / Avatar / BOT style).

**Is Leap 15.6 / 16.0 VICIdial 12 box pe `autoinstall.sh` ya `*step.sh` MAT chalao.**  
Woh maante hain: ViciBox 9, `vicibox-express`, dynportal **port 81**, PHP7, Asterisk **11**, Hetzner Storage Box `/mnt`, `zypper dup`.

VICI12 replacement:

| Vici9 | VICI12 |
| --- | --- |
| `autoinstall.sh` + steps | `install-vicidial12-opensuse.sh` |
| dynportal `:81` random URL | `scripts/vicidial-front-ip.sh` + `PORTAL_DYNAMIC` |
| `mysql_IP_allow.sh` cluster | Express all-in-one = skip; multi-server pe soch ke |

Folder **gitignore** hai (secrets / site files). Docs repo mein hain; zip disk pe: `/root/VICI/vici9install.zip`.

---

## Bara khatra (pehle padho)

In scripts mein **hardcoded passwords**, Storage Box user, AMI secret, HTTP se SSL key download hain. Yeh documentation unko **dobara copy nahi** karti. Agar zip leak ho chuka ho to Storage Box + AMI + certs **rotate** karo.

`4thstep.sh` `zypper dup` chalta hai — VICI12 pe **mana** hai (`zypper up` only).

`1ststep.sh` `/mnt` pe CIFS mount karta hai — Rescue/Leap pe galat credentials = fail; galat mount = disk overwrite khatra.

---

## Folder mein kya hai

`6thstep.sh` **nahi** hai. Number 1–5, 7–10.

| File | Role |
| --- | --- |
| `autoinstall.sh` | Menu: PD vs BOT, Database vs Attach — phir steps chalao |
| `1ststep.sh` | Storage Box `/mnt` mount (CIFS) |
| `2ndstep.sh` | chrony hatao, NTP lagao |
| `3rdstep.sh` | DNS, hostname, SVN tmp, mysql_install_db, **`vicibox-express`** (DB server) |
| `4thstep.sh` | DB server ki bari config (PHP TZ, AGI, SIP 7788, cron, dynportal, Ast 11, SSL, 6666→88888, mysql grants) |
| `5thstep.sh` | Zabbix, SSH keys, lagged-pause patch, firewall (viciportal, 7788) |
| `7thstep.sh` | Attach server: DNS/hostname + **`vicibox-install`** (express nahi) |
| `8thstep.sh` | Attach ki 4thstep jaisi config (kam SQL) |
| `9thstep.sh` | BOT extras DB server pe (logs band, bot360 AGI, realtime PHP) |
| `10thstep.sh` | BOT extras attach pe + https redirect hatao |
| `post-install.sh` | SSH harden, dynportal link, PAM `access.conf`, log services |
| `mysql_IP_allow.sh` | Cluster: dusre servers ko MySQL `cron`/`custom` grant + firewall |
| `change-dyn-portal-access-link.sh` | dynportal ko random folder, URL `:81` |
| `access.conf` | PAM: kaun SSH se aa sakta (wheel IPs) |
| `sshd` | PAM sshd — `pam_access.so` |
| `sshd-log.service` | journalctl sshd → `/var/log/sshd.log` |
| `amd-log.service` | Asterisk messages se AMD errors → `/var/log/amd.log` |
| `README.md` | English: is box pe mat chalao |

---

## `autoinstall.sh` — kaise “install” sochti hai

Pehle poochti hai:

1. **PD / Avatar / Press1** ya **BOT** ya exit  
2. Phir: **Database server** ya **Attach server**

Phir numbered scripts **isi folder se** `./1ststep.sh` … sequential.

```text
PD + Database:   1 → 2 → 3 → 4 → 5 → post-install
PD + Attach:     1 → 2 → 7 → 8 → 5 → post-install
BOT + Database:  1 → 2 → 3 → 4 → 9 → 5 → post-install
BOT + Attach:    1 → 2 → 7 → 8 → 10 → 5 → post-install
```

Database = `vicibox-express` (3rdstep) — ek box pe poora stack.  
Attach = `vicibox-install` (7thstep) — telephony/web jo pehle se DB se judta hai.

VICI12 mein yahi roles: `--role express` vs `database` / `web` / `telephony`.

---

## Har file — kya karti hai (chhoti detail)

### `1ststep.sh` — Storage Box

- `mkdir /mnt`, `zypper install cifs-utils`
- `mount.cifs` Hetzner Storage Box `backup` share → `/mnt`
- Comment: naye credentials (date script mein)
- Baqi steps `/mnt/server_script/...` se files **copy** karti hain — mount fail = agla sab tootega

VICI12: Storage Box zaroori nahi. SVN + packages net se aate hain.

### `2ndstep.sh` — time

- `chronyd` stop/kill, package **hatao**, **ntp** + `ntpd` lagao
- `ntp.conf` mein OpenSUSE pool + local fudge clock

VICI12: **chronyd rakho**, ntp pe mat jao.

### `3rdstep.sh` — DB server pe ViciBox Express

- `/etc/resolv.conf` **delete** karke Hetzner DNS (`213.133.98.98` …) — NetworkManager overwrite kar sakta
- Hostname poochho (~10 digits), `hostnamectl`
- `sed` `/etc/hosts` mein `custom` → hostname (agar `custom` na ho to kuch nahi)
- SVN tmp dir
- `mysql_install_db` + mysql chown (purana MariaDB flow)
- IP `ifconfig` se (naya `ip a` nahi)
- **`vicibox-express`** — official ViciBox installer (is Leap scratch pe command **nahi** hoti)

### `7thstep.sh` — Attach pe ViciBox

3rdstep jaisa DNS/hostname/SVN, lekin **`vicibox-install`** (express nahi). Kehta hai: pehle DB server pe IPs allow karo.

### `4thstep.sh` — DB box ki lambi recipe

- Timezone **America/New_York**, **PHP7** ini (`/etc/php7/...`) — VICI12 PHP **8** hai, yeh paths galat
- `/mnt/.../fixed.tar.gz` → AGI bin
- SIP **bindport 7788** (5060 nahi) — VICI12 default **5060**
- Crons: **roz 6:30 reboot**, ntpdate, flush DBqueue, archive logs 1 din, VB-firewall whitelist, carrier truncate, clean-script
- Agent cleanup cron ko `* * * * *` (har minute)
- Apache + **dynportal** `/srv/www/vhosts/` — VICI12 yeh path **nahi**
- `agc/options.php` webphone auto-connect
- Asterisk **13 → 11** (`vicibox-ast11.sh`)
- MySQL event_scheduler, `zypper dup` (**khatarnak** VICI12 pe)
- keepalive debug, **killall perl**
- `install.pl`, user **6666** saare permissions ON, phir user ko **`88888`** rename
- SSL files HTTP se `i5.tel` (plain HTTP — insecure)
- max_connections 400, phones delete gs102/callin, AMD campaign options off
- Akhir: `/root/mysql_IP_allow.sh` (copy yahan `mysql_IP_allow.sh` hai)

### `8thstep.sh` — Attach ki 4thstep

Kam o zyada 4thstep: TZ, AGI, 7788, cron (attach pe flush/archive kam), dynportal, Ast 11, `zypper dup`, SSL. **6666 SQL / mysql_IP_allow nahi**. `install.pl` ko `n` pipe.

### `5thstep.sh` — monitoring + firewall (dono roles ke baad)

- Storage dobara mount
- `smart_truncate_carrier_log.sh`, `clean-script.sh`, **Zabbix agent** copy/run
- `/root/.ssh/authorized_keys` **overwrite** storage se (apni key ud sakti)
- Lagged pause: `AST_VDauto_dial.pl` 30s → 3600s
- firewalld: kuch IPs accept, apache2/asterisk services **hatao**, **viciportal** + rtp, SIP **7788** sirf ipset `dynamiclist`
- Default zone public

VICI12 firewall: 80, 5060, RTP 10000–20000 — **viciportal/7788 nahi**.

### `9thstep.sh` — BOT (database)

- servers: perf logs N, carrier log Y, agi NONE
- AMD_LOG 0, Perl lines comment, logger quiet, MySQL binlog/slow log band
- `bot360-agi.php` + firewall IP 168.119.167.210
- realtime report PHP copy `/srv/www/htdocs/vicidial/`

### `10thstep.sh` — BOT (attach)

9thstep jaisa (bina servers SQL) + Apache `1111-default.conf` (https redirect hatao).

### `post-install.sh` — SSH + portal + PAM

- sshd: pubkey, **password login band**
- recordings directory listing band
- `change-dyn-portal-access-link.sh`
- `access.conf` + PAM `sshd` copy → **sirf listed IPs se wheel SSH**
- `sshd-log.service` + `amd-log.service` enable
- fail2ban commented

### `change-dyn-portal-access-link.sh`

- `/srv/www/vhosts/` chahiye
- dynportal backup zip
- random 6-letter folder, content andar move
- print `http://IP:81/RANDOM/index.php`

VICI12 admin = `http://IP/vicidial/admin.php` **port 80**. Yeh script **fail** hogi (path nahi).

### `mysql_IP_allow.sh` — cluster grants (yeh akeli kabhi kaam aa sakti)

1. All-in-One? **Y** → exit (Express pe yehi sahi)
2. **N** → kitne attach servers, har IP
3. SQL: user `cron`@IP password historic **`1234`**, `custom`@IP **`custom1234`**, ALL on `asterisk`
4. firewalld rich rule har IP accept
5. FLUSH PRIVILEGES

**Express ek box:** mat chalao (Y dabao / skip).  
**Alag telephony/web → is DB:** IPs do, lekin **1234 production pe mat chhodo**.

### `access.conf`

- `root` kahin se
- `wheel` sirf 3 IPs (script mein hardcoded office IPs)
- baqi deny

VICI12 pe copy karoge to **apna SSH IP na ho to lockout**.

### `sshd` (PAM)

`account required pam_access.so` — `access.conf` apply.

### `sshd-log.service`

`journalctl -u sshd -f` tee `/var/log/sshd.log`.

### `amd-log.service`

200s wait, `asterisk/messages` se AMD/dialog errors grep → `/var/log/amd.log`.

---

## VICI12 pe kaun si idea rakhni hai (copy-paste nahi)

| Idea | VICI12 kaise |
| --- | --- |
| Admin ko IP se band | `./scripts/vicidial-front-ip.sh` — [SCRIPTS-ROMAN-URDU.md](SCRIPTS-ROMAN-URDU.md) |
| Cluster MySQL | soch ke `mysql_IP_allow.sh` **sirf** alag boxes; passwords badlo |
| Time sync | `chronyd`, `zypper dup` nahi |
| SIP | 5060 + RTP 10000–20000, 7788/viciportal nahi |
| Asterisk | 18 + ConfBridge, Ast 11 downgrade nahi |
| PHP | 8.2–8.3, php7 ini nahi |
| Daily reboot cron | optional; VICI12 default nahi |

---

## Agar ghalati se chala diya

1. SSH session **mat todna**
2. `vicibox-express` / `zypper dup` rukwao (Ctrl+C)
3. Snapshot/backup
4. VICI12: `./install-vicidial12-opensuse.sh detect` phir guide [INSTALL.md](INSTALL.md)
5. PAM/sshd badla ho to console/Rescue se `access.conf` revert

---

## Files disk pe

```text
/root/VICI/vici9-extracted/     # yeh folder (git ignore)
/root/VICI/vici9install.zip     # original zip (gitignore)
```

GitHub pe scripts nahi jaate (secrets). Yeh wala markdown **docs/** mein commit hota hai.
