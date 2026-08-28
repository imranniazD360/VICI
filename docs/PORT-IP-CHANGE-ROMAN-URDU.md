# Port aur IP kaise badlein (Roman Urdu)

VICI12 default: web **80**, SIP **5060**, Listed **RTP 10000–20000 UDP**, AMI **5038**, IAX **4569**, DB **3306 band**. HTTPS **443 nahi**.

Teen jagah almost hamesha sath badlo:

1. **Config file** (Apache / Asterisk / MariaDB)
2. **firewalld** (is server pe)
3. **Hetzner Cloud / Robot firewall** (panel) — yahan band ho to andar change bekar

Check abhi kya sun raha hai:

```bash
ss -lntup | grep -E '80|443|3306|5038|5060|4569'
ip -4 a
hostname -I
firewall-cmd --list-all
```

---

## A. IP change (sab se zaroori)

Do IP hote hain:

| Naam | Kya hai | Kahan likha |
| --- | --- | --- |
| **Server IP** (`server_ip`) | VICIdial DB mein is box ki ID — aksar LAN/private | `servers`, `phones`, conferences |
| **Public IP** (`externip`) | Internet / carrier jo SIP pe dekhe | `/etc/asterisk/sip.conf` |

Hetzner Cloud: andar `10.x` / `172.x`, bahar `62.x` — **dono** set karo warna one-way audio.

### A1. Pehli install pe

```bash
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts \
  --server-ip 10.0.0.2 \
  --public-ip 62.238.112.80
```

`--server-ip` = Asterisk/VICIdial bind (jo `ip a` pe NIC hai).  
`--public-ip` = `sip.conf` `externip`.

### A2. Baad mein server IP badal gayi (naya VPS IP, 10.10.10.15 sample)

```bash
OLD=10.10.10.15
NEW=$(hostname -I | awk '{print $1}')   # ya asli LAN IP

/usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
  --old-server_ip="$OLD" --server_ip="$NEW"

mysql asterisk -e "
UPDATE servers SET conf_engine='CONFBRIDGE', rebuild_conf_files='Y', generate_vicidial_conf='Y'
WHERE server_ip='$NEW';
"

/usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES
asterisk -rx "sip reload"
cd /root/VICI && ./install-vicidial12-opensuse.sh setup --yes
./scripts/vicidial-front-ip.sh sync
./scripts/vicidial-front-ip.sh add AAPKA.OFFICE.PUBLIC.IP
```

Bina iske: **no available sessions**, phones galat IP pe.

Purani IP dekho:

```bash
mysql asterisk -e "SELECT server_ip,server_id FROM servers;"
mysql asterisk -e "SELECT DISTINCT server_ip FROM phones;"
mysql asterisk -e "SELECT DISTINCT server_ip FROM vicidial_confbridges LIMIT 10;"
```

Hourly helper kabhi khud `ADMIN_update_server_ip.pl` chalaata hai jab LAN IP change ho.

### A3. Sirf public IP / NAT (`externip`)

Carrier / ghar ka phone internet se aata hai:

```bash
# dekho
grep -nE 'externip|localnet|bindaddr' /etc/asterisk/sip.conf

# example
# [general]
# bindaddr=0.0.0.0
# externip=62.238.112.80
# localnet=10.0.0.0/8
# localnet=172.16.0.0/12
# localnet=192.168.0.0/16
```

`externip` = public. `localnet` = private range taake Asterisk NAT samjhe.

```bash
asterisk -rx "sip reload"
```

Phones **re-register**. Test: `asterisk -rx "sip show peers"`

### A4. Admin whitelist IP (office)

Yeh **server IP nahi** — **aapke laptop/office ka public IP**:

```bash
./scripts/vicidial-front-ip.sh add 203.0.113.50
./scripts/vicidial-front-ip.sh enable-admin
./scripts/vicidial-front-ip.sh status
```

Detail: [SCRIPTS-ROMAN-URDU.md](SCRIPTS-ROMAN-URDU.md)

### A5. Hostname

```bash
hostnamectl set-hostname vici12
hostnamectl
```

VICIdial `server_ip` hostname se **auto nahi** badalta — alag `ADMIN_update_server_ip.pl`.

**DNS + A record + resolv.conf + externhost:** [IP-DNS-ROMAN-URDU.md](IP-DNS-ROMAN-URDU.md)

---

## B. Port kaise badlein

Har port: **Asterisk/Apache file + firewalld + cloud panel + jo client connect kare** (softphone, carrier).

### B1. SIP 5060 → naya (example **7788** jaise Vici9)

VICI12 default **5060**. 7788 tab jab carrier/firewall wahi maange.

1. `/etc/asterisk/sip.conf` `[general]`:

```ini
bindport=7788
bindaddr=0.0.0.0
```

2. Firewall — purana band, naya kholo:

```bash
firewall-cmd --permanent --remove-port=5060/udp
firewall-cmd --permanent --remove-port=5060/tcp
firewall-cmd --permanent --add-port=7788/udp
firewall-cmd --permanent --add-port=7788/tcp
firewall-cmd --reload
firewall-cmd --list-ports
```

Cloud panel mein bhi **7788 UDP/TCP**.

3. Softphone / trunk: SIP port **7788**.  
4. `asterisk -rx "sip reload"` phir `ss -lnup | grep 7788`

VICIdial keepalive `sip-vicidial.conf` **peers** regenerate karta hai; **bindport** `sip.conf` `[general]` mein rehta hai — har keepalive ke baad check karo overwrite to nahi.

Admin UI: **Admin → Servers** pe SIP port field ho to wahan bhi match.

### B2. RTP Listed range (default 10000–20000)

`/etc/asterisk/rtp.conf`:

```ini
[general]
rtpstart=10000
rtpend=20000
```

Example chhota range (cloud limit):

```ini
rtpstart=10000
rtpend=10100
```

Phir firewall:

```bash
firewall-cmd --permanent --remove-port=10000-20000/udp
firewall-cmd --permanent --add-port=10000-10100/udp
firewall-cmd --reload
systemctl restart asterisk
```

Range chhoti = kam simultaneous calls. Cloud + OS **dono** same range.

### B3. Web HTTP 80 → 8080 (mushkil)

VICIdial links aksar **:80** maante hain. Badalna ho to:

`/etc/apache2/listen.conf` ya `Listen 8080`  
`firewall-cmd --permanent --add-port=8080/tcp`  
URL: `http://IP:8080/vicidial/admin.php`

Production pe **reverse proxy** behtar, yeh installer **443 nahi** kholta.

### B4. AMI 5038 (mat kholo WAN pe)

`/etc/asterisk/manager.conf`:

```ini
[general]
enabled = yes
port = 5038
bindaddr = 127.0.0.1
```

Port badlo to **VICIdial** `servers` table / `astguiclient.conf` AMI port bhi. Galat = keepalive mar. **5038 internet pe mat kholo.**

### B5. IAX 4569

IAX trunk use ho to `/etc/asterisk/iax.conf` `bindport`. Default 4569 UDP. Nahi use to firewall se hata sakte ho.

### B6. MySQL 3306

Express pe **localhost**. Public mat kholo. Cluster ho to `mysql_IP_allow` jaisa sirf attach IPs — [VICI9-EXTRACTED-ROMAN-URDU.md](VICI9-EXTRACTED-ROMAN-URDU.md).

### B7. SSH 22

`/etc/ssh/sshd_config` → `Port 2222` phir:

```bash
firewall-cmd --permanent --add-port=2222/tcp
firewall-cmd --reload
systemctl restart sshd
```

**Pehle nayi window se test**, purani session mat kaato. Cloud firewall 2222.

---

## C. Firewall cheatsheet (port add/remove)

```bash
# list
firewall-cmd --list-all

# ek port
firewall-cmd --permanent --add-port=5060/udp
firewall-cmd --permanent --remove-port=5060/udp

# range
firewall-cmd --permanent --add-port=10000-20000/udp

firewall-cmd --reload
```

Hetzner Cloud: Security group / Firewall **same ports**. Robot dedicated: Rescue nahi, production OS + panel.

---

## D. Badalne ke baad checklist

```bash
ss -lntup
asterisk -rx "sip show settings"     # bindport / NAT
asterisk -rx "sip show peers"
curl -I http://127.0.0.1/vicidial/admin.php
mysql asterisk -e "SELECT server_ip FROM servers;"
./scripts/vicidial-front-ip.sh status
```

Softphone: nayi SIP port + server IP/domain. Carrier: unke panel pe **naya IP/port** allow.

---

## E. Ghalatiyan

| Ghalati | Natija |
| --- | --- |
| Sirf `sip.conf`, firewall purana | Phone register nahi |
| Sirf firewall, `bindport` 5060 | Port khali, Asterisk purani jagah |
| `externip` galat | One-way audio |
| DB `server_ip` purani | no available sessions |
| Cloud firewall nahi | OS open, bahar se band |
| AMI 5038 WAN | hack |
| `sync` ke baad office IP ud | dobara `add` |

---

## F. Related docs

- Ports list: [INTERVIEW.md](INTERVIEW.md)  
- Install: [INSTALL.md](INSTALL.md)  
- Front IP: [SCRIPTS-ROMAN-URDU.md](SCRIPTS-ROMAN-URDU.md)
