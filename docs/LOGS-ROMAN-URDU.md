# Server ke saare logs (Roman Urdu)

Dialer tootey to **pehle logs**. Live dekhna: command ke aage `-f` (follow). Band: `Ctrl+C`.

```bash
# systemd (Apache, MariaDB, Asterisk, SSH) — sab se pehle yeh
journalctl -xe
journalctl -u apache2 -u mariadb -u asterisk -n 80 --no-pager
```

---

## 1 minute — sab scan

```bash
ls -lh /var/log/vicidial-installer/ /var/log/asterisk/ /var/log/apache2/ /var/log/astguiclient/ 2>/dev/null
journalctl -u apache2 -n 20 --no-pager
journalctl -u mariadb -n 20 --no-pager
journalctl -u asterisk -n 20 --no-pager
tail -n 30 /var/log/asterisk/full 2>/dev/null || tail -n 30 /var/log/asterisk/messages
screen -ls
df -h
```

---

## Kaun si file kis ki hai

| Path / command | Kya dikhati hai |
| --- | --- |
| `journalctl -u apache2` | Website start/fail, port 80 |
| `/var/log/apache2/error_log` ya `error_log` | PHP / 403 / 404 |
| `/var/log/apache2/access_log` | Kaun sa URL hit |
| `journalctl -u mariadb` | DB start, TIMESTAMP, crash |
| `/var/log/mysql/` ya `/var/log/mariadb/` | MariaDB extra |
| `journalctl -u asterisk` | Asterisk service (systemd) |
| `/var/log/asterisk/full` | SIP, dial, errors (agar logger on) |
| `/var/log/asterisk/messages` | Messages |
| `/var/log/asterisk/queue_log` | Queue (kam use) |
| `/var/log/vicidial-installer/` | **Is installer** ka har run |
| `/var/log/astguiclient/` | Perl keepalive, portal IP sync |
| `journalctl -u vicidial-portal-ip-sync.service` | Hourly IP list |
| `journalctl -u sshd` | SSH login fail |
| `/var/log/messages` ya `journalctl -k` | Kernel, DAHDI, net |
| `screen -ls` | Dialer processes zinda ya nahi (log nahi, status) |

Leap pe Apache kabhi `/var/log/apache2/error_log` (underscore). List: `ls /var/log/apache2/`

---

## A. Installer logs (VICI12 script)

```bash
ls -lt /var/log/vicidial-installer/
tail -f /var/log/vicidial-installer/install-*.log
```

Naam mein time hota hai: `install-YYYYMMDD-HHMMSS.log`  
Root nahi to kabhi: `~/.vicidial-installer-logs/`

Yahan: zypper fail, Asterisk compile, SVN, PHP.

---

## B. systemd — `journalctl`

```bash
journalctl -u apache2 -e          # end
journalctl -u apache2 -f          # live
journalctl -u mariadb -n 100 --no-pager
journalctl -u asterisk -n 100 --no-pager
journalctl -u chronyd -n 20 --no-pager
journalctl -u firewalld -n 20 --no-pager
journalctl --since "1 hour ago" -u asterisk
journalctl -p err -n 50           # sirf errors
```

Leap 16 pe Apache unit: `apache2` (`httpd` alias). Confirm:

```bash
systemctl status apache2 mariadb asterisk
```

---

## C. Apache (website)

```bash
tail -f /var/log/apache2/error_log
tail -f /var/log/apache2/access_log
# kabhi:
tail -f /var/log/apache2/error.log
apachectl -S          # vhosts
curl -I http://127.0.0.1/vicidial/admin.php
```

| Log line | Matlab |
| --- | --- |
| `AH00072` bind fail | Port 80 busy (nginx?) |
| `403` | IP list / Apache `Require ip` |
| `404` | files `/srv/www/htdocs/vicidial` nahi |
| PHP fatal | `php8` module / `php.ini` |

---

## D. MariaDB

```bash
journalctl -u mariadb -f
ls /var/log/mysql /var/log/mariadb 2>/dev/null
mysqladmin ping
```

TIMESTAMP / `sql_mode`: `/etc/my.cnf.d/vicidial.cnf`

---

## E. Asterisk (calls / SIP)

```bash
ls -lh /var/log/asterisk/
tail -f /var/log/asterisk/full
tail -f /var/log/asterisk/messages

asterisk -r
# CLI:
# sip set debug on
# rtp set debug on     (phir OFF)
# core set verbose 3
# quit
```

Verbose hamesha on mat chhodo — disk bhar jati hai.

Logger: `/etc/asterisk/logger.conf` (`full` => `notice,warning,error,verbose,dtmf,fax`)

**Asterisk-only poori guide (SIP debug, rtp debug, logger.conf):** [ASTERISK-LOGS-ROMAN-URDU.md](ASTERISK-LOGS-ROMAN-URDU.md)

---

## F. VICIdial Perl / keepalive

```bash
ls -lh /var/log/astguiclient/
tail -f /var/log/astguiclient/*.log
screen -ls
# screen attach (example):
# screen -r ASTupdate
# nikalna: Ctrl+A phir D
```

Empty `screen -ls` = dialer scripts nahi chal rahe, Asterisk chalu ho to bhi.

```bash
/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --debug
```

`--debug9` bahut zyada likhta hai (Vici9 `4thstep` jaisa) — lab only.

---

## G. Portal IP sync

```bash
journalctl -u vicidial-portal-ip-sync.service -n 50
journalctl -u vicidial-portal-ip-sync.timer
tail -f /var/log/astguiclient/portal-ip-sync.log
systemctl list-timers | grep vicidial-portal
```

---

## H. SSH / security

```bash
journalctl -u sshd -n 50 --no-pager
grep -i fail /var/log/messages | tail
```

Vici9 extra (agar un services lagayi hon — VICI12 default nahi):

- `/var/log/sshd.log`
- `/var/log/amd.log`

---

## I. Disk / rotate

Logs bhar jayein to server hang.

```bash
du -sh /var/log/* | sort -h
df -h
```

Purani installer logs hatao (chaho to):

```bash
ls /var/log/vicidial-installer/
# rm /var/log/vicidial-installer/install-PURANA.log
```

`logrotate` Leap pe `/etc/logrotate.d/` — Apache/MariaDB aksar auto.

---

## J. Masla → kaun sa log

| Masla | Kahan dekho |
| --- | --- |
| Install atka | `/var/log/vicidial-installer/` |
| Page nahi khulti | `journalctl -u apache2` + Apache error_log |
| IP not allowed | `vicidial-front-ip.sh status` + Apache error 403 |
| DB error | `journalctl -u mariadb` |
| Phone UNKNOWN | `asterisk -rx "sip show peer 8001"` + `/var/log/asterisk/full` |
| No audio | RTP firewall + `sip show settings` (externip) |
| No hopper / sessions | mysql + `ADMIN_update_server_ip.pl` — [PORT-IP-CHANGE-ROMAN-URDU.md](PORT-IP-CHANGE-ROMAN-URDU.md) |
| screen khali | keepalive + `journalctl -u asterisk` |
| Time galat | `journalctl -u chronyd` + `timedatectl` |

---

## K. Ek line copy-paste (support ko bhejna)

```bash
echo '=== units ===' && systemctl is-active apache2 mariadb asterisk chronyd
echo '=== screen ===' && screen -ls
echo '=== ports ===' && ss -lntup | grep -E '80|3306|5038|5060'
echo '=== journal ===' && journalctl -u apache2 -u mariadb -u asterisk -n 15 --no-pager
```
