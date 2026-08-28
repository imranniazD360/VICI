# VICIdial 12 — interview, ports, firewall, commands

Study pack from Linux basics through install failures. Stack: OpenSUSE Leap 15.6/16.0, Apache, PHP 8.2–8.3, MariaDB 10.11+, Asterisk 18 + **ConfBridge**, VICIdial **2.14**, schema **1729+**.

Also: [INSTALL.md](INSTALL.md) · [HETZNER-RESCUE.md](HETZNER-RESCUE.md) · [FRONT-IP-VALIDATION.md](FRONT-IP-VALIDATION.md)

---

## Ports (memorize)


| Port            | Protocol  | Use                    | Public?                  |
| --------------- | --------- | ---------------------- | ------------------------ |
| **22**          | TCP       | SSH                    | Yes, restrict to your IP |
| **80**          | TCP       | Admin + agent HTTP     | Yes                      |
| **443**         | TCP       | HTTPS                  | **No** in this installer |
| **3306**        | TCP       | MariaDB                | **No** on Express        |
| **5038**        | TCP       | AMI (Asterisk Manager) | **No** on WAN            |
| **5060**        | UDP + TCP | SIP                    | Yes (phones + carrier)   |
| **4569**        | UDP       | IAX                    | If IAX trunk             |
| **10000–20000** | UDP       | RTP (audio)            | **Yes** or one-way audio |


One line: web **80** · SIP **5060** · RTP **10000–20000 UDP** · DB **3306 closed** · AMI **5038 closed**.

Kaise **badlein** (SIP port, `externip`, `ADMIN_update_server_ip.pl`): **[PORT-IP-CHANGE-ROMAN-URDU.md](PORT-IP-CHANGE-ROMAN-URDU.md)** · DNS: **[IP-DNS-ROMAN-URDU.md](IP-DNS-ROMAN-URDU.md)**

**Logs kahan:** [LOGS-ROMAN-URDU.md](LOGS-ROMAN-URDU.md) · Asterisk: [ASTERISK-LOGS-ROMAN-URDU.md](ASTERISK-LOGS-ROMAN-URDU.md)

Hetzner has **two** firewalls: cloud/Robot **and** `firewalld`. Both must allow SIP/RTP.

```bash
firewall-cmd --state
firewall-cmd --list-all
ss -lntup | grep -E '80|3306|5038|5060|4569'
```

Open on Leap (`firewalld`):

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-port=5060/udp
firewall-cmd --permanent --add-port=5060/tcp
firewall-cmd --permanent --add-port=10000-20000/udp
firewall-cmd --permanent --add-port=4569/udp
firewall-cmd --reload
```

Do **not** open 3306 to the internet.


| Symptom                 | Likely port            |
| ----------------------- | ---------------------- |
| Phone will not register | 5060                   |
| Registered, no audio    | RTP 10000–20000 UDP    |
| Admin page dead         | 80                     |
| DB / AMI exposed        | 3306 or 5038 left open |


---



## Daily commands

```bash
hostname; ip a; nproc; free -h; df -h; uptime
systemctl status apache2 mariadb asterisk chronyd
ss -lntup
firewall-cmd --list-all
screen -ls
asterisk -rx "core show version"
asterisk -rx "sip show peers"
asterisk -rx "sip show peer 8001"
asterisk -rx "core show channels"
curl -I http://127.0.0.1/
journalctl -u asterisk -e
```

Asterisk CLI: `core show version` · `sip show peers` · `sip show peer 8001` · `sip show registry` · `confbridge list` · `module show like confbridge` · `manager show connected` · `dialplan show`

Rebuild conf from DB:

```bash
mysql -e "UPDATE asterisk.servers SET rebuild_conf_files='Y', generate_vicidial_conf='Y';"
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES
asterisk -rx "sip reload"
asterisk -rx "dialplan reload"
```

Empty `screen -ls` with Asterisk up = keepalives dead. Run `/usr/share/astguiclient/ADMIN_keepalive_ALL.pl`.

Never `zypper dup` on a dialer — only `zypper up`.

---



## Architecture (say this)

Roles: **express** (DB+web+telephony) · **database** · **web** · **telephony** · **archive**.

Browser → Apache/PHP → MariaDB. Phone → SIP/RTP. Perl keepalives → AMI **5038** + DB. Hopper = `AST_VDhopper.pl`.


| Path                                     | What          |
| ---------------------------------------- | ------------- |
| `/usr/src/astguiclient/trunk`            | SVN           |
| `/usr/share/astguiclient`                | Perl          |
| `/srv/www/htdocs/vicidial`               | Admin         |
| `/srv/www/htdocs/agc`                    | Agent         |
| `/etc/asterisk/sip-vicidial.conf`        | Generated SIP |
| `/etc/asterisk/confbridge-vicidial.conf` | ConfBridge    |
| `/root/vicidial-credentials.txt`         | Secrets       |


SVN: `svn://svn.eflo.net:3690/agc_2-X/trunk`

Lab logins (change immediately): admin `http://IP/vicidial/admin.php` **6666** / **1234** · agent `http://IP/agc/vicidial.php` **8001** / **8001** campaign **DEMOCAMP**. Softphone must REGISTER before agent UI (`UNKNOWN` = no login).

---



## Q&A — Linux

**OS?** OpenSUSE Leap. ViciBox 12 = 15.6. Scratch also 16.0.

**Time wrong?** Hopper GMT, recordings, TLS. Use `chronyd` / `timedatectl`.

**Port in use?** `ss -lntp | grep 80` then stop nginx (`--stop-conflicts`).

---



## Q&A — install

**ISO vs scratch?** ISO = official ~2 GB image + `vicibox-express`. Scratch = Leap + this script (Hetzner-friendly).

**Why compile Asterisk?** VICIdial needs **chan_sip**, patches, DAHDI, ConfBridge. Distro Asterisk is often unpatched / PJSIP-only.

**Why DAHDI with no card?** Timing for conferences.

**MeetMe vs ConfBridge?** Asterisk 18 has no MeetMe. This stack = ConfBridge. Old dumps with MeetMe fail until migrated.

**Schema walk?** `2.0.5 → 2.2 → 2.4 → 2.6 → 2.8 → 2.10 → 2.12 → 2.14` → **1729+**. Then `ADMIN_update_server_ip.pl`.

**Public SIP IP?** `externip` / `--public-ip`. Wrong NAT = one-way audio.

**Leap 16 gotchas:** package renames (`libjansson-devel`), `httpd` alias of `apache2`, MariaDB 11 `[mysqld]`, PHP may be 8.4, systemd timer instead of `cronie`.

---



## Install / first-boot problems

**Rescue:** `No space left` **on ISO wget** — Rescue `/` is tmpfs. Delete partial ISO. Use `installimage` Leap. See [HETZNER-RESCUE.md](HETZNER-RESCUE.md).

**Still** `root@rescue` **after reboot** — `installimage` did not finish; EFI vs BIOS; `SWRAID 0` on one disk.

**Installer: not OpenSUSE** — you installed Ubuntu/Debian/Rocky.

**Apache / :80 busy** — nginx/lighttpd. Stop them.

**PHP / white page** — need 8.2–8.3 + `apache2-mod_php8`.

**TIMESTAMP / schema load fail** — `/etc/my.cnf.d/vicidial.cnf`: `explicit_defaults_for_timestamp=Off`, `sql_mode=NO_ENGINE_SUBSTITUTION`.

**Asterisk compile fail** — missing devel libs or 4 GB RAM without `--lab` / `-j1`.

**SVN hang** — TCP **3690** or `svn.eflo.net`.

`screen -ls` **empty** — crontab/timer not running `ADMIN_keepalive_ALL.pl`.

**Admin 404** — files not in `/srv/www/htdocs/vicidial`; DocumentRoot.

**IP list lockout** — `6666` has `ignore_ip_list=1`. Others need **PORTAL_DYNAMIC**. Tool: `scripts/vicidial-front-ip.sh`.

`no available sessions: ||IP|8001|SIP/8001|` — conferences still on sample `10.10.10.15`, or MeetMe on Asterisk 18. Fix:

```bash
/usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
  --old-server_ip=10.10.10.15 --server_ip=REAL.IP
```

Set `servers.conf_engine=CONFBRIDGE`, rebuild conf, `module reload app_confbridge.so`.

`no leads in the hopper` — list inactive, hopper empty, `no_hopper_leads_logins`. Seed hopper; `AST_VDhopper.pl`.

**Peer UNKNOWN** — `asterisk -rx "sip show peer 8001"`: secret, 5060, NAT, firewall.

**One-way audio** — RTP ports + `externip` + `localnet`.

**Drop at ~30s** — SIP ACK/NAT or session timers.

**CHANUNAVAIL** — dial prefix, CID, trunk, campaign timeout.

**After move, still 10.10.10.15** — `servers`, phones, conferences, ConfBridge tables + `ADMIN_update_server_ip.pl`.

---



## Campaign / DB (expert)

Hopper = short queue in `vicidial_hopper` from `vicidial_list` (GMT, DNC, status `NEW`).

Tables to name: `servers`, `phones`, `vicidial_users`, `vicidial_campaigns`, `vicidial_lists`, `vicidial_list`, `vicidial_hopper`, `vicidial_auto_calls`, `vicidial_log`, `vicidial_carrier_log`, `vicidial_confbridges`.

AUTO vs MANUAL vs INBOUND. Dial level vs drop %. List vs campaign.

AMI **5038** = Asterisk control plane; lock to localhost/LAN.

---



## Security

Change **6666/1234** before the box is public. No 3306/5038 on WAN. Admin IP lists. SSH keys. VICIdial is **AGPL**.

---



## 60-second Hetzner answer

Rescue RAM cannot hold the 2 GB ViciBox ISO. Use `installimage` **Opensuse-1600-amd64-base**, `SWRAID 0`, reboot into Leap, `zypper up`, then this installer: Apache, PHP, MariaDB TIMESTAMP fix, DAHDI, patched Asterisk 18, ConfBridge, VICIdial 2.14 from SVN. Set `--server-ip` and `--public-ip`. Open 80/5060/RTP. Keep 3306 closed. Register softphone until `sip show peers` is OK. Change default admin password.

---



## Asaan Roman Urdu (interview bolo)

Firewall = darwaza. Port band = traffic nahi.

**Yaad:** `80` website · `5060` SIP · `10000-20000 UDP` awaaz · `3306` DB band · `5038` AMI band · `22` SSH.

Hetzner pe **do** firewall: panel + `firewalld`. Ek khol doosri band = call nahi.

ISO Rescue pe mat utaro — RAM bhar jati hai (`No space left`). `installimage` se **Opensuse-1600-amd64-base**, reboot, phir yeh script. Wohi ViciBox 12 stack hai.

Agent login se pehle phone **REGISTER**. `sip show peer 8001` UNKNOWN nahi.

**no available sessions** = conference IP `10.10.10.15` · **no leads in hopper** = hopper khali · one-way audio = RTP band ya `externip` galat.

`zypper dup` mat chalao. `screen -ls` khali = dialer keepalive nahi chal raha.

---



## Questions to ask *them*

Express or split roles? chan_sip or PJSIP? Carrier IP-auth or register? NAT? Inbound DIDs? DNC / recording consent / drop %? Agents and CPS peak? Who owns firewall (OS vs cloud)?