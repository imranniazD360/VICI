# IP change + DNS (Roman Urdu)

VICIdial **database mein IP number** rakhta hai (`10.x` / `62.x`), aksar **hostname nahi**. DNS alag kaam: naam → IP (`A` record), aur server khud internet naam resolve kare (`/etc/resolv.conf`).

IP badalne ki files/commands: [PORT-IP-CHANGE-ROMAN-URDU.md](PORT-IP-CHANGE-ROMAN-URDU.md)  
Yeh file: **DNS ke sath** IP kaise jodte ho.

---

## Teen alag cheezein — mix mat karo

| Cheez | Example | VICIdial pe asar |
| --- | --- | --- |
| **LAN / server IP** | `10.0.0.2` | `servers.server_ip`, phones, ConfBridge |
| **Public IP** | `62.238.112.80` | `sip.conf` `externip`, carrier ACL, website |
| **DNS naam** | `vici.example.com` | Browser URL, email, kabhi SIP `fromdomain` — **DB `server_ip` khud nahi badalta** |

Hostname `vici12` badalne se `ADMIN_update_server_ip.pl` **auto nahi** chalta.

---

## A. Server ka DNS resolver (naam kaise IP banta hai)

File: **`/etc/resolv.conf`**

```bash
cat /etc/resolv.conf
# nameserver 185.12.64.1     (example)
# nameserver 8.8.8.8
```

Test:

```bash
ping -c 1 download.vicidial.com
host svn.eflo.net
dig +short google.com
```

`host` / `dig` package: **bind-utils** ([PACKAGES-ROMAN-URDU.md](PACKAGES-ROMAN-URDU.md)).

### Leap pe theek tarika

OpenSUSE **netconfig / NetworkManager** `resolv.conf` overwrite karta hai. Vici9 `3rdstep` **`rm -rf /etc/resolv.conf`** karta hai — **mat chalao**; reboot pe toot sakta / NM dubara likhe.

Hetzner DNS (Germany), example:

```text
nameserver 185.12.64.2
nameserver 185.12.64.1
```

Purani Robot list kabhi `213.133.98.98` … — pehle Hetzner docs / `cat /etc/resolv.conf` dekho jo **installimage** ne di.

Static rakhna ho (samajh ke):

```bash
# NetworkManager connection DNS, ya
# /etc/sysconfig/network/config  NETCONFIG_DNS_STATIC_SERVERS=
netconfig update -f
```

Galat DNS = `svn checkout` hang, `zypper ref` fail, `curl ifconfig.me` fail, portal public IP na mile.

---

## B. Hostname + `/etc/hosts`

```bash
hostnamectl
hostnamectl set-hostname vici12.example.com
# ya short:
hostnamectl set-hostname vici12
```

`/etc/hosts` — local naam bina DNS ke:

```text
127.0.0.1       localhost
10.0.0.2        vici12 vici12.example.com
```

Public IP yahan **tab** likho jab naam isi box pe resolve ho (kam zaroori). Galat hosts entry = khud ko galat IP.

Vici9 `sed 's/custom/$hostname/'` — agar `custom` word hosts mein nahi to **kuch nahi** hota.

---

## C. Public IP badli — DNS provider pe kya karo

Agar log `http://vici.example.com/vicidial/` se aate hain:

1. Domain panel (Cloudflare / registrar) **A record**  
   `vici.example.com` → **naya public IP**
2. **TTL** (300 = 5 min, 86400 = 1 din). Purana TTL khatam hone tak kuch log purani IP pe jayenge.
3. Check bahar se:

```bash
dig +short vici.example.com A
# yahi naya IP hona chahiye
```

4. **Hetzner / cloud** pe naya IP assign.  
5. Is box pe:

```bash
# LAN same ho to sirf public:
# sip.conf externip=NAYA.PUBLIC.IP
# localnet=...
asterisk -rx "sip reload"

./scripts/vicidial-front-ip.sh sync
./scripts/vicidial-front-ip.sh add OFFICE.PUBLIC.IP
```

6. Agar **server_ip** (LAN) bhi badla:

```bash
/usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
  --old-server_ip=PURANI --server_ip=NAYI
```

7. Carrier panel: **SIP IP whitelist** aksar **A record nahi**, seedha IP — naya IP add karo.

8. Reverse DNS (**PTR**): Hetzner Robot/Cloud pe `80.112.238.62.in-addr.arpa` → `vici.example.com`  
   Outbound CID / kuch carriers PTR dekhte hain. A record ke **sath match** rakho.

---

## D. SIP aur DNS

`/etc/asterisk/sip.conf` `[general]`:

```ini
externip=62.238.112.80
; kabhi:
; externhost=vici.example.com
; externrefresh=120
fromdomain=vici.example.com
```

| Setting | Matlab |
| --- | --- |
| `externip` | Public **number** — simple, recommended |
| `externhost` | Public **DNS naam** — Asterisk khud resolve karta, IP change pe refresh |
| `fromdomain` | SIP From header domain (carrier match) |

Dynamic Hetzner IP + DNS naam ho to `externhost` + `externrefresh` soch sakte ho. Static IP ho to **`externip` kaafi**.

Phones: domain `vici.example.com` **ya** IP. Domain use karo to **A record** theek hona zaroori. Register fail = DNS galat / TTL.

---

## E. Website URL

Installer **HTTP IP** dikhata hai: `http://62.x.x.x/vicidial/admin.php`

DNS ke baad: `http://vici.example.com/vicidial/admin.php` — Apache **ServerName** optional:

`/etc/apache2/httpd.conf` ya vhost `ServerName vici.example.com`

Is installer mein **SSL 443 default nahi**. HTTPS alag (proxy). DNS `A` phir bhi IP pe jaati hai.

Admin IP list: user ka **client public IP**, domain nahi. `add` mein hostname nahi — **number**.

---

## F. Checklist — IP + DNS ek sath

```text
[ ] dig A record = naya public IP
[ ] PTR (optional) match
[ ] Hetzner NIC / floating IP
[ ] sip.conf externip ya externhost
[ ] localnet private range
[ ] firewalld + cloud SG
[ ] ADMIN_update_server_ip agar LAN/server_ip badla
[ ] vicidial-front-ip sync + office add
[ ] carrier ACL naya IP
[ ] softphone: naya host/IP, sip reload
[ ] resolv.conf: zypper/svn abhi resolve ho
```

```bash
ip -4 a
hostnamectl
cat /etc/resolv.conf
dig +short vici.example.com A
grep -E 'externip|externhost|fromdomain|localnet' /etc/asterisk/sip.conf
mysql asterisk -e "SELECT server_ip FROM servers;"
```

---

## G. Vici9 vs VICI12

Vici9 `3rdstep`/`7thstep`: resolv.conf wipe + Hetzner nameserver + hostname prompt.  
VICI12: **installimage** pehle se DNS; `zypper`/`svn` usi resolver se. Extra wipe **mat** karo.

---

## H. Masle

| Masla | Check |
| --- | --- |
| `Temporary failure in name resolution` | `resolv.conf`, ping `8.8.8.8` (IP chale naam na chale = DNS) |
| Site purani IP | A record + TTL cache |
| Phone domain se register nahi | `dig` phone DNS vs server; SRV rarely |
| One-way audio after IP change | `externip` purani; RTP ports |
| svn://svn.eflo.net hang | DNS ya port 3690 firewall |
| `add vici.example.com` fail | sirf IPv4 number, FQDN nahi |
