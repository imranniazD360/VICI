# Front / portal IP validation (VICI12)

How front IP validation works on this **OpenSUSE VICIdial 12** dialer, how it maps from your **Vici9** scripts, and how to use the management tool.

---

## Quick start

```bash
cd /root/VICI
chmod +x scripts/vicidial-front-ip.sh

# See current whitelist
./scripts/vicidial-front-ip.sh status

# Refresh server LAN + public IP + 127.0.0.1
./scripts/vicidial-front-ip.sh sync

# Allow your office / home public IP (required for non-6666 admins)
./scripts/vicidial-front-ip.sh add YOUR.OFFICE.IP

# Make sure ADMIN group uses the list
./scripts/vicidial-front-ip.sh enable-admin

# Optional: also lock Apache /vicidial/ to the same IPs
./scripts/vicidial-front-ip.sh apache-on
```

Symlink (optional):

```bash
ln -sf /root/VICI/scripts/vicidial-front-ip.sh /usr/local/sbin/vicidial-front-ip
vicidial-front-ip status
```

---

## What Vici9 did vs what VICI12 does

You uploaded `vici9install.zip`. Those scripts target **ViciBox 9-style** layouts (`/srv/www/vhosts/dynportal`, port **81**, firewall service `viciportal`).

| Vici9 piece | Purpose | VICI12 equivalent |
| --- | --- | --- |
| `change-dyn-portal-access-link.sh` | Hide dynportal under a random path on `:81` | Not used — admin is `/vicidial/` on **:80**. Use IP lists (+ optional Apache gate) instead |
| `mysql_IP_allow.sh` | Grant MySQL to cluster attach servers | Only needed for multi-server; Express all-in-one skips this |
| `post-install.sh` | SSH lockdown + dynportal + PAM `access.conf` | Separate hardening; IP validation for **web** is PORTAL_DYNAMIC |
| `access.conf` / PAM sshd | SSH login by IP for `wheel` | Optional OS hardening (not VICIdial portal) |
| Firewall rich rules / `dynamiclist` | Edge allow-list | firewalld ports from installer + optional rich rules |

**VICI12 front IP validation (native):**

1. `system_settings.allow_ip_lists = 1`
2. IP list **`PORTAL_DYNAMIC`** in `vicidial_ip_lists` / `vicidial_ip_list_entries`
3. **ADMIN** group `admin_ip_list = PORTAL_DYNAMIC`
4. User **6666** has `ignore_ip_list=1` so you cannot lock yourself out of admin
5. Hourly sync: `/usr/local/sbin/vicidial-portal-ip-sync.sh` + `vicidial-portal-ip-sync.timer`
6. Optional Apache `Require ip` for `/srv/www/htdocs/vicidial/` via `apache-on`

Agent UI (`/agc/`) is intentionally **not** bound to the list by default on the demo **AGENTS** group (empty `agent_ip_list`), so lab agents can log in. Tighten later if needed.

---

## How it protects the dialer

```text
Browser → http://SERVER/vicidial/admin.php
              │
              ├─ (optional) Apache Require-ip  ← apache-on
              │
              └─ VICIdial PHP checks ADMIN.admin_ip_list
                    → PORTAL_DYNAMIC entries
                    → allow or reject
```

If your public IP is **not** in the list (and you are not user `6666`), admin login is blocked.

---

## Commands reference

| Command | What it does |
| --- | --- |
| `status` | Show allow flag, IPs, group bindings, timer, Apache gate |
| `sync` | Re-detect LAN/public/`127.0.0.1`, rewrite list entries |
| `add <IP>` | Add office/home IP to whitelist |
| `remove <IP>` | Remove an IP |
| `enable-admin` | Bind ADMIN → PORTAL_DYNAMIC; keep 6666 ignore |
| `disable-admin` | Clear ADMIN IP list (open admin to world — lab only) |
| `apache-on` | Write `/etc/apache2/conf.d/vicidial-front-ip.conf` and reload |
| `apache-off` | Remove Apache gate |
| `install-timer` | Install/repair sync helper + hourly systemd timer |

Examples:

```bash
./scripts/vicidial-front-ip.sh add 203.0.113.50
./scripts/vicidial-front-ip.sh remove 203.0.113.50
./scripts/vicidial-front-ip.sh sync
./scripts/vicidial-front-ip.sh status
```

---

## Typical office setup

1. From the server, sync local IPs:
   ```bash
   ./scripts/vicidial-front-ip.sh sync
   ```
2. Find your **home/office public IP** (what the internet sees), e.g. visit https://ifconfig.me from that network.
3. Add it:
   ```bash
   ./scripts/vicidial-front-ip.sh add 203.0.113.50
   ```
4. Enable admin binding (usually already on after installer/`setup`):
   ```bash
   ./scripts/vicidial-front-ip.sh enable-admin
   ```
5. (Recommended) Turn on Apache front gate:
   ```bash
   ./scripts/vicidial-front-ip.sh apache-on
   ```
6. Test admin from that IP: `http://SERVER_IP/vicidial/admin.php`  
   Login `6666` / `1234` always works even if your IP drifts (ignore list). Change that password ASAP.

---

## Installer integration

`install-vicidial12-opensuse.sh` already calls `ensure_dynamic_portal_ip_validation` during:

- `install --role express|database|web`
- `setup --yes`

That creates `PORTAL_DYNAMIC`, binds ADMIN, installs the sync helper + timer.

Re-run anytime:

```bash
./install-vicidial12-opensuse.sh setup --yes
# or
./scripts/vicidial-front-ip.sh install-timer
./scripts/vicidial-front-ip.sh sync
```

---

## Cluster MySQL grants (from Vici9 `mysql_IP_allow.sh`)

Only if you have **separate** telephony/web boxes connecting to this DB:

```bash
# Reference copy from your upload:
less /root/VICI/vici9-extracted/mysql_IP_allow.sh
bash /root/VICI/vici9-extracted/mysql_IP_allow.sh
```

Answer **N** for all-in-one, then enter attach-server IPs.  
For a single Express box you do **not** need this.

---

## Vici9 dynportal random URL (reference only)

```bash
# From your zip — ViciBox paths, port 81:
/root/VICI/vici9-extracted/change-dyn-portal-access-link.sh
```

This dialer does **not** ship `/srv/www/vhosts/dynportal`. Do not run that script as-is on VICI12. Use `vicidial-front-ip.sh` instead.

Extracted Vici9 files (reference): `/root/VICI/vici9-extracted/`  
Original zip: `/root/VICI/vici9install.zip`

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Admin says IP not allowed | `add` your public IP, then `sync`; or login as `6666` |
| Locked out completely | SSH in and run `disable-admin` or `add` your IP |
| List empty after reboot | `install-timer` + `sync` |
| Apache 403 on /vicidial/ | Your IP missing → `add` + `apache-on`, or `apache-off` |
| Agents blocked | Clear agent IP list: ensure AGENTS `agent_ip_list` is empty |

Check DB directly:

```bash
mysql asterisk -e "
SELECT allow_ip_lists FROM system_settings;
SELECT * FROM vicidial_ip_list_entries WHERE ip_list_id='PORTAL_DYNAMIC';
SELECT user_group,admin_ip_list,agent_ip_list FROM vicidial_user_groups;
"
```

Timer:

```bash
systemctl status vicidial-portal-ip-sync.timer
journalctl -u vicidial-portal-ip-sync.service -n 50
```

---

## Security notes

- Front IP validation is **not** a substitute for strong passwords or VPN.
- Change default admin **6666 / 1234** immediately.
- Prefer VPN or SSH tunnel for admin on production.
- Demo agents stay open for lab; bind `agent_ip_list` only when you know agent office IPs.
- This stack uses **HTTP :80 only** (no SSL in the installer). Put TLS in front if needed.
