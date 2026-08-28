# `scripts/` folder — poori documentation (Roman Urdu)

Is folder mein **abhi 1 script** hai. Yeh file har chhoti baat batati hai: kya hai, kaise chalti hai, install kaise, kaun si file/table/timer banati hai.

| File | Kaam |
| --- | --- |
| `scripts/vicidial-front-ip.sh` | Admin website ke liye **IP whitelist** (office/home IP allow). Vici9 dynportal ka VICI12 version. |

Repo root pe alag installer hai (scripts folder ke bahar):

| File | Kaam |
| --- | --- |
| `install-vicidial12-opensuse.sh` | Poora VICIdial 12 install (Apache, MariaDB, Asterisk, SVN). **Pehle yeh chalao.** |

`vici9-extracted/` gitignore hai — **is Leap 16 box pe mat chalao** (woh ViciBox 9 / port 81 ke liye hai).

Angrezi short guide: [FRONT-IP-VALIDATION.md](FRONT-IP-VALIDATION.md)

---

## 0. Pehle samajh lo — yeh script kya karti hai (ek line)

Browser se koi `http://SERVER/vicidial/admin.php` kholta hai. Agar uska **public IP** list mein nahi, aur user `6666` nahi, to **admin band**.

Do darwaze ho sakte hain:

1. **VICIdial PHP** — database list `PORTAL_DYNAMIC` (hamesha yeh)
2. **Apache** — extra gate `/vicidial/` folder pe (`apache-on`) — optional

Agent page `/agc/` is list se **default band nahi** (demo agents login ho saken).

---

## 1. Install ka poora silsila (chhoti se chhoti step)

Yeh script **khud OS nahi lagati**. Pehle server pe Leap + VICIdial hona chahiye.

### Step A — OpenSUSE (Hetzner Rescue)

Rescue mein ViciBox ISO mat utaro. Detail: [HETZNER-RESCUE.md](HETZNER-RESCUE.md)

```bash
installimage
# Opensuse-1600-amd64-base  +  SWRAID 0  +  ek disk
reboot
```

Prompt `root@rescue` **nahi** hona chahiye.

```bash
zypper ref && zypper up && reboot
```

### Step B — VICIdial 12 installer (root)

```bash
cd /root/VICI
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
./install-vicidial12-opensuse.sh setup --yes
```

`install` / `setup` ke dauran installer khud `ensure_dynamic_portal_ip_validation` chalta hai:

- DB mein list `PORTAL_DYNAMIC` banati hai
- ADMIN group ko list se bind karti hai
- `/usr/local/sbin/vicidial-portal-ip-sync.sh` likhti hai
- systemd timer **hourly + boot** lagati hai

Matlab: **Express install ke baad yeh IP system pehle se on hota hai.** `vicidial-front-ip.sh` usko **dekhne / IP add / Apache gate** ke liye hai.

### Step C — is folder ki script ready karo

```bash
cd /root/VICI
chmod +x scripts/vicidial-front-ip.sh
```

`chmod +x` = Linux ko bolo yeh file **chalao** (execute). Bina iske `Permission denied`.

Optional shortcut (koi bhi folder se command):

```bash
ln -sf /root/VICI/scripts/vicidial-front-ip.sh /usr/local/sbin/vicidial-front-ip
vicidial-front-ip status
```

`ln -sf` = shortcut. `-s` = shortcut, `-f` = purani file overwrite.

### Step D — pehli baar chalao (hamesha root)

```bash
# 1) kya chal raha hai
./scripts/vicidial-front-ip.sh status

# 2) server ke LAN + public IP + 127.0.0.1 list mein daalo
./scripts/vicidial-front-ip.sh sync

# 3) apna ghar/office public IP (jo internet dekhta hai)
./scripts/vicidial-front-ip.sh add 1.2.3.4

# 4) ADMIN group list use kare (installer aksar pehle hi kar chuka)
./scripts/vicidial-front-ip.sh enable-admin

# 5) optional: Apache bhi unhi IPs ko allow kare
./scripts/vicidial-front-ip.sh apache-on
```

Apna public IP nikalne ke liye **office PC** pe browser: https://ifconfig.me  
Server ka IP mat daal dena ghalati se — **wo IP jahan se aap admin kholte ho**.

Timer toot gaya ho to:

```bash
./scripts/vicidial-front-ip.sh install-timer
```

**Root zaroori hai.** `EUID` 0 na ho to: `ERROR: Run as root`

MariaDB chalni chahiye (`systemctl is-active mariadb`). Database naam default: **`asterisk`**.

---

## 2. Script ke andar constants (hard-coded naam)

File ke start pe yeh values hain. Badalna ho to file edit + samajh ke.

| Variable | Value | Matlab |
| --- | --- | --- |
| `DB_NAME` | `asterisk` (env se badal sakte ho) | VICIdial DB |
| `LIST_ID` | `PORTAL_DYNAMIC` | Whitelist ka naam DB mein |
| `HELPER` | `/usr/local/sbin/vicidial-portal-ip-sync.sh` | Har hour chalne wala chhota sync program |
| `APACHE_CONF` | `/etc/apache2/conf.d/vicidial-front-ip.conf` | Apache extra gate file |
| `WWW_VICIDIAL` | `/srv/www/htdocs/vicidial` | Admin files ka folder |

Env example (agar DB ka naam alag ho):

```bash
DB_NAME=asterisk ./scripts/vicidial-front-ip.sh status
```

`set -euo pipefail` = koi command fail ho to script **ruk jaye**; undefined variable error.

---

## 3. Chhoti helper functions (andar ka engine)

### `die`

Error print karke **exit 1**. Galat IP, root nahi, list khali, wagaira.

### `need_root`

Agar user root nahi → `die`. `main` har command se pehle yeh chalta hai.

### `mysql_cli` — DB se baat

Order:

1. Agar `/root/.my.cnf` hai → `mysql --defaults-file=/root/.my.cnf` (password file se)
2. Warna `mariadb` command ho to woh
3. Warna `mysql -u root`

Flags: `-N` = column names nahi, `-B` = batch (table borders nahi). Output saaf rahe.

### `db "...SQL..."`

Usi se `asterisk` database pe query. Poori script isi se list padhti/likhti hai.

### `valid_ip`

IP `1.2.3.4` jaisi honi chahiye. Har hissa **0–255**. `abc` ya `1.2.3` reject.

### `ensure_list`

Har add/sync/apache se pehle:

1. `system_settings.allow_ip_lists = 1` — VICIdial ko bolo lists **on**
2. Agar `PORTAL_DYNAMIC` list nahi → **INSERT**
3. List `active='Y'`

Bina iske PHP IP check nahi karegi.

---

## 4. Har command — kya karti hai, kaise chalti hai

Chalane ka format:

```bash
./scripts/vicidial-front-ip.sh COMMAND
./scripts/vicidial-front-ip.sh add 203.0.113.50
```

`main`: pehla word command, baqi arguments. Default command agar kuch na do: **`status`**.

| Command | Alias | Kya hota hai |
| --- | --- | --- |
| `status` | (default) | Screen pe list, groups, timer, Apache |
| `sync` | | LAN + public + 127.0.0.1 dubara likho + enable-admin |
| `add IP` | | Office IP insert |
| `remove IP` | `rm` `del` | IP delete |
| `enable-admin` | | ADMIN group → PORTAL_DYNAMIC; user 6666 ignore |
| `disable-admin` | | ADMIN list khali = **duniya se admin khul gaya** (sirf lab) |
| `apache-on` | | `/vicidial/` pe Apache Require ip |
| `apache-off` | | Woh Apache file hatao |
| `install-timer` | | Helper + systemd timer lagao, ek dafa sync |
| `help` | `-h` `--help` | Usage text |

Galat command: `Unknown command: ...`

---

### 4.1 `status` — sirf dekho, kuch mat badlo

Print karta hai:

- `allow_ip_lists` 0 ya 1
- list id `PORTAL_DYNAMIC`
- har allowed IP (`vicidial_ip_list_entries`)
- kaun se user groups is list ko use karte hain (admin / agent / api)
- user `6666` ka `ignore_ip_list` (1 = lockout nahi)
- helper file hai ya MISSING
- systemd timer enabled hai ya nahi, agla run time
- Apache conf file hai to ON, warna off
- Admin + Agent URLs (server ka pehla IP)

DB down ho to kuch jagah `?` ya `(none / DB error)`.

---

### 4.2 `sync` — IPs refresh

1. `ensure_list`
2. Agar helper **executable** hai → wahi chalao (`/usr/local/sbin/vicidial-portal-ip-sync.sh`)
3. Agar helper nahi:
   - LAN IP: `ip -4 route get 1.1.1.1` se `src`
   - backup: `hostname -I` pehla IP
   - public: `curl` https://ifconfig.me/ip (3 second timeout)
   - **DELETE** saari purani entries is list ki
   - INSERT: `127.0.0.1`, LAN, public (agar mila)
4. Phir `enable-admin`
5. `Sync done.`

**Khatra:** `sync` list **wipe** karke sirf in teen tarah ki IPs likhta hai. Office IP jo `add` se daali thi, helper/sync ke baad **ud sakti hai** agar helper bhi DELETE+INSERT kare. Is liye **sync ke baad office IP dobara `add` karo**.

Installer wala helper bhi `DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='PORTAL_DYNAMIC'` karta hai, phir localhost/LAN/public insert. Hourly timer yahi karta hai — **office IP timer ke baad dobara add** ya khud helper mein extra IPs rakhna (advanced).

Practical: office IP `add` karo; agar 1 ghante baad gayab ho jaye to `add` dubara, ya timer ke baad turant `add`.

---

### 4.3 `add <IP>`

1. IP khali → usage error
2. `valid_ip` fail → `Invalid IP`
3. `ensure_list`
4. Purani same IP row DELETE (duplicate nahi)
5. INSERT
6. Agar Apache conf pehle se hai → `apache-on` chhupke dubara (Apache list match kare)

---

### 4.4 `remove` / `rm` / `del`

List se woh IP DELETE. Apache on ho to conf rewrite.

---

### 4.5 `enable-admin`

```sql
UPDATE vicidial_user_groups SET admin_ip_list='PORTAL_DYNAMIC' WHERE user_group='ADMIN';
UPDATE vicidial_users SET modify_ip_lists='1', ignore_ip_list='1' WHERE user='6666';
```

- ADMIN web UI ab list check karegi
- **6666** list ignore — galat IP pe bhi admin (is liye password turant badlo)

---

### 4.6 `disable-admin`

ADMIN ki `admin_ip_list` khali. Koi bhi IP se admin (lab). Production pe mat chhodo.

---

### 4.7 `apache-on` — doosra darwaza

VICIdial PHP se **alag**. Apache folder `/srv/www/htdocs/vicidial` pe:

- pehle `Require all denied` (sab band)
- phir har whitelist IP `Require ip x.x.x.x`

List khali ho to script **ruk jati hai**: pehle `add` + `sync`.

Phir:

- file likho ` /etc/apache2/conf.d/vicidial-front-ip.conf `
- `apachectl configtest` (agar command ho)
- `systemctl reload apache2`

**Sirf `/vicidial/`** — `/agc/` (agent) is file se band nahi.

Galat IP se admin: browser **403 Forbidden** (Apache), ya VICIdial ka “IP not allowed” (PHP). Dono alag layers hain.

---

### 4.8 `apache-off`

Conf file `rm`. Apache reload. PHP wali list **chalti rehti hai**.

---

### 4.9 `install-timer` — hourly auto sync

Root. Agar helper nahi:

- `/usr/local/sbin/vicidial-portal-ip-sync.sh` likhta hai (andar wahi DELETE+INSERT)
- log: `/var/log/astguiclient/portal-ip-sync.log`
- `chmod 755`

Phir do systemd files:

**`/etc/systemd/system/vicidial-portal-ip-sync.service`**

- Type `oneshot` — ek dafa chalo khatam
- `ExecStart=` helper
- `After=` network + mariadb/mysql

**`/etc/systemd/system/vicidial-portal-ip-sync.timer`**

- `OnBootSec=2min` — boot ke 2 minute baad
- `OnUnitActiveSec=1h` — phir har ~1 hour
- `Persistent=true` — miss ho to baad mein chalao
- `WantedBy=timers.target`

Phir:

```bash
systemctl daemon-reload
systemctl enable --now vicidial-portal-ip-sync.timer
systemctl start vicidial-portal-ip-sync.service
```

Akhiri line `cmd_sync` bhi.

Check:

```bash
systemctl status vicidial-portal-ip-sync.timer
systemctl list-timers | grep vicidial-portal
journalctl -u vicidial-portal-ip-sync.service -n 50
tail -20 /var/log/astguiclient/portal-ip-sync.log
```

Leap 16 pe installer **systemd timer prefer** karta hai (`cronie` aksar nahi). Purane box pe `/etc/cron.d/vicidial-portal-ip` bhi ho sakta hai (`@reboot` + `15 * * * *`). Dono ek saath confusing — ek rakho.

---

## 5. Database tables (yaad rakho)

Database: **`asterisk`**

| Table | Column / kaam |
| --- | --- |
| `system_settings` | `allow_ip_lists` = `1` warna lists off |
| `vicidial_ip_lists` | list `PORTAL_DYNAMIC`, `active=Y` |
| `vicidial_ip_list_entries` | har allowed `ip_address` |
| `vicidial_user_groups` | `admin_ip_list` / `agent_ip_list` / `api_ip_list` |
| `vicidial_users` | user `6666` → `ignore_ip_list=1` |

Khud dekho:

```bash
mysql asterisk -e "
SELECT allow_ip_lists FROM system_settings;
SELECT * FROM vicidial_ip_lists WHERE ip_list_id='PORTAL_DYNAMIC';
SELECT * FROM vicidial_ip_list_entries WHERE ip_list_id='PORTAL_DYNAMIC';
SELECT user_group,admin_ip_list,agent_ip_list,api_ip_list FROM vicidial_user_groups;
SELECT user,ignore_ip_list FROM vicidial_users WHERE user='6666';
"
```

---

## 6. Kaun si files disk pe banti hain

| Path | Kaun likhta hai |
| --- | --- |
| `/usr/local/sbin/vicidial-portal-ip-sync.sh` | installer **ya** `install-timer` |
| `/etc/systemd/system/vicidial-portal-ip-sync.service` | installer / `install-timer` |
| `/etc/systemd/system/vicidial-portal-ip-sync.timer` | installer / `install-timer` |
| `/etc/apache2/conf.d/vicidial-front-ip.conf` | **sirf** `apache-on` |
| `/var/log/astguiclient/portal-ip-sync.log` | helper har run |
| `/etc/cron.d/vicidial-portal-ip` | kabhi installer (agar cronie ho) |
| `/root/VICI/scripts/vicidial-front-ip.sh` | git repo — yeh management tool |

Apache conf ke upar likha: **do not edit by hand** — `apache-on` se dubara generate.

---

## 7. Traffic ka rasta (kaise “chal raha hai”)

```text
Aap browser
    → port 80 Apache
        → (agar apache-on) IP match? nahi = 403
        → /vicidial/admin.php  PHP
            → allow_ip_lists=1?
            → user 6666 + ignore? = allow
            → warna ADMIN.admin_ip_list = PORTAL_DYNAMIC
            → IP entries mein ho? nahi = VICIdial block
    → /agc/vicidial.php
        → default AGENTS.agent_ip_list khali = agents open
```

Hourly timer sirf **DB list** refresh karta hai (LAN/public/127.0.0.1). Apache file tab tak purani rehti hai jab tak dubara `apache-on` / `add` (jo apache-on trigger kare).

---

## 8. Main installer se rishta

`install-vicidial12-opensuse.sh` function `ensure_dynamic_portal_ip_validation`:

- tab chalti hai: `install --role express|database|web` aur `setup`
- tables na hon to skip
- IPs: `--server-ip`, `--public-ip`, `127.0.0.1`, curl ifconfig.me / ipify
- wahi PORTAL_DYNAMIC + ADMIN bind + helper + timer

Is liye **pehli install ke baad** `vicidial-front-ip.sh status` pehle se IPs dikha sakta hai.

Dobara:

```bash
./install-vicidial12-opensuse.sh setup --yes
```

---

## 9. Masle aur ilaaj (chhota)

| Problem | Kya karo |
| --- | --- |
| `Run as root` | `sudo -i` ya `su -` |
| `Invalid IP` | sirf `a.b.c.d` 0–255 |
| Admin: IP not allowed | `add` apna **public** IP; `6666` se andar jao |
| Poora lock | SSH: `disable-admin` ya `add` |
| Reboot ke baad list khali | `install-timer` + `sync` + office `add` |
| Apache 403 | IP missing: `add` + `apache-on`, ya `apache-off` |
| Agents block | AGENTS `agent_ip_list` khali rakho |
| `sync` ke baad office IP gayab | wapas `add` (timer DELETE karta hai) |
| Timer nahi | `systemctl enable --now vicidial-portal-ip-sync.timer` |
| mysql access denied | `/root/.my.cnf` ya root socket; mariadb running |

---

## 10. Security (zaroor)

- `6666` / `1234` **turant badlo**
- `disable-admin` production pe nahi
- IP list = extra layer, VPN/password ki jagah nahi
- Is installer mein **HTTPS 443 nahi** — HTTP 80
- Script ko internet pe mat chhodo world-writable

---

## 11. Help text khud script se

```bash
./scripts/vicidial-front-ip.sh help
```

Docs path script ke andar: `/root/VICI/docs/FRONT-IP-VALIDATION.md` (Angrezi). Yeh file Roman Urdu poori detail.

---

## 12. Repo root installer (scripts folder nahi, lekin “install”)

Poora dialer:

```bash
cd /root/VICI
./install-vicidial12-opensuse.sh help
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
./install-vicidial12-opensuse.sh setup --yes
```

Roles: `express` · `database` · `web` · `telephony` · `archive`.  
Guide: [INSTALL.md](INSTALL.md) · Interview/ports: [INTERVIEW.md](INTERVIEW.md)
