# VICIdial 12 installer for OpenSUSE (no ISO)

[![CI](https://github.com/imranniazD360/VICI/actions/workflows/ci.yml/badge.svg)](https://github.com/imranniazD360/VICI/actions)

Scratch-install VICIdial 12 on **stock openSUSE Leap 15.6 / 16.0**. It does **not** download, mount, or boot the 2GB ViciBox ISO — that transfer is too slow on Hetzner and similar hosts.

**Full step-by-step guide (all phases, credentials, softphone, troubleshooting):**  
→ **[docs/INSTALL.md](docs/INSTALL.md)**

**Front / portal IP validation (Vici9-style dynamic whitelist for VICI12):**  
→ **[docs/FRONT-IP-VALIDATION.md](docs/FRONT-IP-VALIDATION.md)** · tool: `scripts/vicidial-front-ip.sh`

**Hetzner Rescue (no ViciBox ISO — Leap 16 + this installer):**  
→ **[docs/HETZNER-RESCUE.md](docs/HETZNER-RESCUE.md)**

**Interview: ports, firewall, commands, install failures:**  
→ **[docs/INTERVIEW.md](docs/INTERVIEW.md)**

**`scripts/` folder — har command Roman Urdu mein (IP whitelist tool):**  
→ **[docs/SCRIPTS-ROMAN-URDU.md](docs/SCRIPTS-ROMAN-URDU.md)** · `scripts/vicidial-front-ip.sh`

**`vici9-extracted/` — purana ViciBox 9 pack (is Leap box pe mat chalao):**  
→ **[docs/VICI9-EXTRACTED-ROMAN-URDU.md](docs/VICI9-EXTRACTED-ROMAN-URDU.md)**

| Layer | Installed |
| --- | --- |
| OS | openSUSE Leap **15.6** or **16.0** (Hetzner `installimage` or any Leap VPS) |
| Web | **Apache** (`apache2`) — checked, installed if missing, enabled, started, port 80 verified |
| PHP | **8.2–8.3** + `apache2-mod_php8` |
| Database | MariaDB **10.11+** — TIMESTAMP fix + `sql_mode=NO_ENGINE_SUBSTITUTION` |
| Telephony | Asterisk **18** + VICIdial patches + DAHDI + **ConfBridge** |
| Application | VICIdial **2.14** SVN trunk, DB schema **1729+** |

Run as **root**. Never use `zypper dup`.

```bash
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
chmod +x install-vicidial12-opensuse.sh
./install-vicidial12-opensuse.sh help
```

## Fast path (Hetzner dedicated)

```bash
# After Leap installimage + zypper up + reboot:
./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
./install-vicidial12-opensuse.sh setup --yes   # if Asterisk not running
reboot
screen -ls && asterisk -r
```

Lab VM (2 CPU / 4 GB): add `--lab`.

## Logins (change admin immediately)

| UI | URL | Login |
| --- | --- | --- |
| Admin | `http://IP/vicidial/admin.php` | `6666` / `1234` |
| Agent | `http://IP/agc/vicidial.php` | user+phone `8001` / `8001`, campaign `DEMOCAMP` |

Also demo agents **6001** and **7001**. USA demo list **1001** (25 leads). Credentials file: `/root/vicidial-credentials.txt`.

Register a SIP softphone as `8001` / `8001` before agent login (peer must not stay `UNKNOWN`).

## Commands

| Command | Purpose |
| --- | --- |
| `detect` / `check` | Scan only |
| `install --role express` | Full single-box install |
| `setup` | Enable/start services + demo admin/agents |
| `migrate --dump FILE` | Import/upgrade old DB |

Roles: `express` · `database` · `web` · `telephony` · `archive`. Logs: `/var/log/vicidial-installer/`.

Firewall: TCP **80**/22, SIP 5060, IAX 4569, AMI 5038, RTP **10000–20000**. **No SSL/443**. Keep 3306 closed.

VICIdial is AGPL software from [vicidial.org](https://www.vicidial.org/). This repository only ships the installer.

See **[docs/INSTALL.md](docs/INSTALL.md)** for the complete A→Z documentation.
