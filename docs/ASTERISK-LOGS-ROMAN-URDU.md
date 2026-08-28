# Asterisk logs (Roman Urdu)

Call / SIP / Listed ka masla ho to **Asterisk logs**. Do jagah:

1. **systemd** — service start/crash: `journalctl -u asterisk`
2. **Files** — call detail: `/var/log/asterisk/`

```bash
systemctl is-active asterisk
ls -lh /var/log/asterisk/
journalctl -u asterisk -n 50 --no-pager
tail -n 50 /var/log/asterisk/full
```

Live (band `Ctrl+C`):

```bash
tail -f /var/log/asterisk/full
# ya
journalctl -u asterisk -f
```

---

## Folder mein kya hota hai

Path: **`/var/log/asterisk/`** (installer yeh directory banata hai).

| File | Kab use |
| --- | --- |
| **`full`** | Sab se useful — notice, warning, error, verbose (agar `logger.conf` mein on) |
| **`messages`** | Chhota message log |
| **`queue_log`** | Queue events (inbound queue) |
| **`cdr-csv/`** | Call records CSV (agar CDR csv on) |
| **`debug`** | Sirf jab debug logger on ho — **bohot bada** |
| **`security`** | AMI / auth (kabhi) |

Agar `full` nahi:

```bash
ls -la /var/log/asterisk/
grep -v '^;' /etc/asterisk/logger.conf | grep -v '^$'
```

Phir neeche **logger.conf** theek karo.

---

## `logger.conf` — kaun si file kya likhe

File: `/etc/asterisk/logger.conf`

Typical:

```ini
[logfiles]
console => notice,warning,error
messages => notice,warning,error
full => notice,warning,error,debug,verbose,dtmf,fax
```

`console` = `asterisk -r` screen.  
`full` = disk file.

Badalne ke baad:

```bash
asterisk -rx "logger reload"
# ya
asterisk -rx "core reload"
```

Vici9 `9thstep` kabhi `messages` comment / `verbose = 0` karta hai — logs **kam** ho jati. VICI12 pe `full` rakho jab debug karo.

---

## CLI se dekhna (`asterisk -r`)

```bash
asterisk -r
```

Andar:

```text
core show version
core show channels
sip show peers
sip show peer 8001
core set verbose 3
core set debug 0
quit
```

Bahar se ek line (script / SSH):

```bash
asterisk -rx "sip show peers"
asterisk -rx "core show channels"
asterisk -rx "logger show channels"
```

`logger show channels` = abhi kaun se log files khuli hain.

---

## SIP debug (register / 401 / trunk)

**Poora SIP dump** (zyada text):

```text
sip set debug on
```

Sirf ek peer:

```text
sip set debug peer 8001
sip set debug peer TRUNKNAME
```

**Turant band:**

```text
sip set debug off
```

PJSIP ho to (agar yeh build PJSIP use kare — classic VICI12 **chan_sip**):

```text
pjsip set logger on
pjsip set logger off
```

Log file mein INVITE, 401, 200 OK, ACK dikhega. 30 second call drop = ACK/NAT.

---

## RTP / Listed debug

```text
rtp set debug on
```

Packets aa rahe hain? Band:

```text
rtp set debug off
```

Hamesha on mat chhodo — CPU + disk.

One-way audio: pehle firewall RTP 10000–20000, `externip` — [PORT-IP-CHANGE-ROMAN-URDU.md](PORT-IP-CHANGE-ROMAN-URDU.md)

---

## Verbose vs debug

| Command | Matlab |
| --- | --- |
| `core set verbose 3` | Dialplan lines (console + `full` agar verbose log on) |
| `core set verbose 0` | Kam shor |
| `core set debug 3` | Andaruni Asterisk debug |
| `core set debug 0` | Band |

Production pe verbose/debug **0** rakho jab masla solve ho jaye.

---

## systemd vs file — kab kaun

| Masla | Command |
| --- | --- |
| Asterisk start nahi / crash loop | `journalctl -u asterisk -e` · `systemctl status asterisk` |
| SIP peer UNKNOWN | `sip show peer` + `tail -f full` + `sip set debug peer` |
| Call fail CHANUNAVAIL | `full` + `core show channels` |
| AMI / keepalive | `manager show connected` + `journalctl -u asterisk` |
| Module load fail (confbridge) | `asterisk -rx "module show like confbridge"` + journal |

Unit file installer likhta hai; `ExecStartPre` log dir banata hai. Permission:

```bash
ls -ld /var/log/asterisk
# asterisk user likh sake
```

---

## Common lines — matlab

| Log / CLI | Matlab |
| --- | --- |
| `Registration from ... failed` | galat secret / IP |
| `401 Unauthorized` | password / from-user |
| `403 Forbidden` | carrier ACL / IP allow nahi |
| `ChanUnavail` / `CONGESTION` | trunk down, prefix, CID |
| `No such channel` | call pehle hi cut |
| `No RTP` / timeout | RTP ports / NAT |
| `Ignoring SIP message` | NAT / bindaddr |
| `Failed to authenticate` | AMI 5038 |

---

## Disk bharna

`full` + `sip set debug on` = GB. Check:

```bash
du -sh /var/log/asterisk/*
df -h /
```

Purani `full` rotate / truncate (Asterisk band kiye baghair carefully):

```bash
asterisk -rx "logger rotate"
# ya logger.conf + logrotate
```

`logger rotate` nayi `full` kholta, purani rename.

---

## VICIdial ke sath

Asterisk file logs **calls**. Dialer hopper/agent **Perl** alag:

```bash
ls /var/log/astguiclient/
screen -ls
```

Dono chahiye: Asterisk = phone; `astguiclient` = VICIdial scripts.

Poora server log map: [LOGS-ROMAN-URDU.md](LOGS-ROMAN-URDU.md)
