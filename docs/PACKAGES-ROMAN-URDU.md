# Packages — kaun sa kyun install hota hai (Roman Urdu)

`zypper` se jo package lagta hai, uska **kaam** yahan hai. Example: **`cifs-utils`**.

Do alag duniya:

| Kaun | Kab |
| --- | --- |
| **VICI12** `install-vicidial12-opensuse.sh` | Is Leap 15.6/16 box pe **yahi** chalao |
| **Vici9** `vici9-extracted/*step.sh` | Purana pack — is box pe **mat** chalao, sirf samajhne ke liye |

Check installed: `rpm -q PACKAGE` · search: `zypper se PACKAGE`

---

## Example: `cifs-utils` kya hai?

**CIFS** = Windows/Samba share protocol (SMB). Hetzner **Storage Box** bhi SMB/CIFS deta hai.

Vici9 `1ststep.sh` / `5thstep.sh`:

```bash
zypper install -y cifs-utils
mount.cifs -o user=...,pass=...  //BOX.your-storagebox.de/backup /mnt
```

| Piece | Matlab |
| --- | --- |
| Package `cifs-utils` | Command `mount.cifs` + kernel helper |
| `mount.cifs` | Door ke folder ko `/mnt` pe chipkao |
| Kyun Vici9 | `/mnt/server_script/` se AGI, Apache, Zabbix, keys **copy** |
| VICI12 pe? | **Nahi lagta.** Installer packages + SVN net se. Storage Box zaroori nahi |

Bina `cifs-utils` ke `mount.cifs: command not found`. Galat password = mount fail, agle steps tootenge.

Is Leap VICI12 pe `cifs-utils` tabhi chahiye jab **khud** Storage Box mount karo. Default installer **nahi** chalta.

---

## Vici9 scripts — jo packages lagte hain

| Package | Script | Kyun |
| --- | --- | --- |
| **cifs-utils** | `1ststep`, `5thstep` | Storage Box → `/mnt` |
| **ntp** (+ chrony **remove**) | `2ndstep` | Purana time daemon `ntpd`. VICI12 **chrony** rakhta hai — yeh swap **mat** karo |
| **fail2ban** | `post-install` (comment) | SSH brute-force band. Ab commented |

Baqi Vici9 **source/copy** karta hai (`vicibox-express`, tar.gz), `zypper dup` (poora OS upgrade — VICI12 pe **mana**).

---

## VICI12 installer — har package kyun

`zypper in` Phase 2–5. Kuch Leap 16 pe naam badle (`libjansson-devel`); jo na mile skip.

### A. Base (har role)

| Package | Kyun use |
| --- | --- |
| **bash** coreutils util-linux procps | Shell, `ps`, `kill`, basic Linux |
| **iproute2** **iputils** | `ip a`, `ping` — server IP, network |
| **wget** **curl** | Asterisk/DAHDI tarball, public IP (`ifconfig.me`) |
| **tar gzip bzip2 unzip xz patch** | Source kholna, VICIdial patches |
| **git** **subversion** | VICIdial `svn checkout` trunk |
| **gcc gcc-c++ make autoconf automake libtool** | Asterisk 18 **compile** (bina gcc ke dialer nahi banta) |
| **screen** | Keepalives: `ASTupdate`, `ASTVDauto` … `screen -ls` |
| **sox** | Audio convert (recordings / sounds) |
| **bind-utils** | `dig` / `host` — DNS check |
| **lsof** **psmisc** | Port/process debug (`lsof`, `killall`) |
| **chrony** | Time (`chronyd`) — hopper GMT, logs. Vici9 NTP se replace **mat** karo |
| **python3** | Kuch helper / Leap tools |
| **perl** | Poora VICIdial backend (`ADMIN_keepalive_ALL.pl`, hopper, AMI) |

### B. Devel (Asterisk + DAHDI compile)

| Package | Kyun |
| --- | --- |
| **ncurses-devel** | Asterisk `menuselect` / CLI |
| **libxml2-devel** | XML config parse |
| **openssl-devel** / **libopenssl-devel** | TLS/SRTP (SIP crypto libs) |
| **libuuid-devel** | Unique IDs |
| **speex-devel** **speexdsp-devel** | Speex codec |
| **libcurl-devel** | HTTP in Asterisk |
| **libedit-devel** | Asterisk CLI line edit |
| **sqlite3-devel** | Asterisk **astdb** (internal). VICIdial data **MariaDB** mein hai |
| **unixODBC-devel** | ODBC (optional DB) |
| **kernel-devel** **kernel-default-devel** **kernel-source** **kernel-syms** | DAHDI **kernel module** banane ke liye headers |
| **libsrtp-devel** | Secure RTP |
| **jansson-devel** / **libjansson-devel** | JSON (ARI / ConfBridge related) |
| **newt-devel** | Dialog/UI libs compile |

Bina matching **kernel-*-devel** ke DAHDI source build skip — Cloud pe ConfBridge **timerfd** se chal sakta.

### C. Perl modules (VICIdial scripts)

| Package | Kyun |
| --- | --- |
| **perl-DBI** **perl-DBD-mysql** / **perl-DBD-MariaDB** | Perl → MariaDB (hopper, keepalive) |
| **perl-Net-Telnet** | AMI / telnet style |
| **perl-Time-HiRes** | Fine timers |
| **perl-IO-Socket-SSL** **perl-libwww-perl** | HTTPS Perl |
| **perl-Digest-MD5** **perl-YAML** **perl-JSON** **perl-Try-Tiny** | Hash, config, JSON |
| **perl-Mail-Sendmail** | Email reports |
| **hostname** | Host name util |
| **lame** **mpg123** | MP3 encode/play recordings |
| **pv** | Progress (copy/pipe) |
| **nmap** **sipsak** | SIP/network test (kabhi repo mein nahi) |

### D. Web (PHP + Apache)

| Package | Kyun |
| --- | --- |
| **apache2** | Website port **80** — `/vicidial/` admin, `/agc/` agent |
| **apache2-mod_php8** | PHP Apache ke andar (mod_php) |
| **apache2-utils** | `htpasswd`, `ab`, tools |
| **php8** | VICIdial PHP pages |
| **php8-mysql** **php8-mysqli** | PHP → MariaDB |
| **php8-gd** | Images / reports |
| **php8-mbstring** | Unicode names |
| **php8-xmlwriter** **php8-dom** **php8-xmlreader** | XML |
| **php8-zip** **php8-zlib** | Zip/compress |
| **php8-curl** | HTTP out |
| **php8-bcmath** | Numbers |
| **php8-opcache** | PHP tez |
| **php8-gettext** **php8-iconv** | Language / charset |
| **php8-tokenizer** **php8-ctype** **php8-fileinfo** | PHP internals |
| **php8-session** | Login session |
| **php8-posix** **php8-sockets** | Process / TCP sockets |

Bina **apache2-mod_php8** ke `.php` download ho jati / white page.

### E. Database

| Package | Kyun |
| --- | --- |
| **mariadb** | VICIdial DB (`asterisk` schema, hopper, users) |
| **mariadb-client** | `mysql` / `mariadb` CLI |
| **mariadb-tools** | dump/check tools |

Port **3306** localhost. Internet pe mat kholo.

### F. Telephony

| Package / source | Kyun |
| --- | --- |
| **dahdi-linux** **dahdi-tools** (OBS `home:vicidial`) | Timing / analog cards. Conference clock. Na ho to Asterisk 18 **ConfBridge + timerfd** |
| DAHDI **source** tarball | Jab RPM na mile aur kernel headers hon |
| **libpri1** **libpri-devel** | ISDN PRI (E1/T1). Cloud SIP-only pe optional |
| Asterisk **18.26.4 source** (zypper nahi) | `chan_sip`, patches, ConfBridge — distro Asterisk use nahi |

### G. Firewall / extra

| Package | Kyun |
| --- | --- |
| **firewalld** | Aksar Leap pe pehle se. Installer **ports kholta** hai (80, 5060, RTP…). Package alag `in` nahi, service use |
| **vsftpd** | Sirf `--role archive` — recordings FTP |

---

## VICI12 pe `cifs-utils` kab lagao (optional)

Agar recordings/backup Storage Box pe rakhni hon:

```bash
zypper in -y cifs-utils
mkdir -p /mnt/storagebox
mount.cifs //uXXXXX.your-storagebox.de/backup /mnt/storagebox -o user=uXXXXX,pass=SECRET,vers=3.0
```

Yeh **VICIdial install ka hissa nahi**. Credentials scripts/docs mein paste mat karo. `fstab` se permanent mount alag topic.

---

## Quick yaad

| Package | Ek line |
| --- | --- |
| **cifs-utils** | Door ka Windows/Samba/Storage Box folder mount (`mount.cifs`) — Vici9 `/mnt` |
| **chrony** | Clock theek — hopper |
| **apache2** + **php8** | Admin/agent website |
| **mariadb** | Leads, users, hopper |
| **gcc** + **kernel-devel** | Asterisk/DAHDI compile |
| **subversion** | VICIdial source |
| **perl** + **perl-DBD-*** | Dialer scripts |
| **screen** | Background keepalive |
| **sox** **lame** | Call recording audio |
| **dahdi-*** | Timing/card; VM pe skip OK |

Installer list: `install-vicidial12-opensuse.sh` functions `install_base_packages`, `install_php`, `configure_mariadb`, `install_dahdi`.
