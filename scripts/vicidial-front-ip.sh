#!/usr/bin/env bash
# vicidial-front-ip.sh — Front / portal IP validation for VICIdial 12 (OpenSUSE)
#
# Native VICI12 equivalent of Vici9 "dynamic portal" IP control:
#   - VICIdial Allow IP Lists + list PORTAL_DYNAMIC
#   - Bound to ADMIN (admin web UI)
#   - Optional Apache Require-ip layer for /vicidial/
#   - Sync helper + systemd timer (same as installer)
#
# Usage:
#   ./vicidial-front-ip.sh status
#   ./vicidial-front-ip.sh sync
#   ./vicidial-front-ip.sh add 1.2.3.4
#   ./vicidial-front-ip.sh remove 1.2.3.4
#   ./vicidial-front-ip.sh enable-admin
#   ./vicidial-front-ip.sh disable-admin
#   ./vicidial-front-ip.sh apache-on
#   ./vicidial-front-ip.sh apache-off
#   ./vicidial-front-ip.sh install-timer
#
# Run as root on the dialer.

set -euo pipefail

DB_NAME="${DB_NAME:-asterisk}"
LIST_ID="PORTAL_DYNAMIC"
HELPER="/usr/local/sbin/vicidial-portal-ip-sync.sh"
APACHE_CONF="/etc/apache2/conf.d/vicidial-front-ip.conf"
WWW_VICIDIAL="/srv/www/htdocs/vicidial"

die()  { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root"; }

mysql_cli() {
  if [[ -f /root/.my.cnf ]]; then
    mysql --defaults-file=/root/.my.cnf -N -B "$@"
  elif command -v mariadb >/dev/null 2>&1; then
    mariadb -N -B -u root "$@"
  else
    mysql -N -B -u root "$@"
  fi
}

db() { mysql_cli "$DB_NAME" -e "$1"; }

valid_ip() {
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

ensure_list() {
  db "UPDATE system_settings SET allow_ip_lists='1';" || true
  db "INSERT INTO vicidial_ip_lists (ip_list_id,ip_list_name,active,user_group)
      SELECT '${LIST_ID}','Dynamic portal whitelist (auto)','Y','---ALL---'
      FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_ip_lists WHERE ip_list_id='${LIST_ID}');" || true
  db "UPDATE vicidial_ip_lists SET active='Y' WHERE ip_list_id='${LIST_ID}';" || true
}

cmd_status() {
  echo "=== Front / portal IP validation status ==="
  echo
  local allow
  allow="$(db "SELECT allow_ip_lists FROM system_settings LIMIT 1;" 2>/dev/null || echo '?')"
  echo "system_settings.allow_ip_lists : ${allow}"
  echo "list id                        : ${LIST_ID}"
  echo
  echo "Whitelisted IPs:"
  db "SELECT CONCAT('  - ', ip_address) FROM vicidial_ip_list_entries WHERE ip_list_id='${LIST_ID}' ORDER BY ip_address;" 2>/dev/null \
    || echo "  (none / DB error)"
  echo
  echo "User groups using this list:"
  db "SELECT CONCAT('  ', user_group, '  admin=', IFNULL(admin_ip_list,''), '  agent=', IFNULL(agent_ip_list,''))
      FROM vicidial_user_groups
      WHERE admin_ip_list='${LIST_ID}' OR agent_ip_list='${LIST_ID}' OR api_ip_list='${LIST_ID}';" 2>/dev/null \
    || echo "  (none)"
  echo
  echo "Admin 6666 ignore_ip_list:"
  db "SELECT CONCAT('  ', IFNULL(ignore_ip_list,'0')) FROM vicidial_users WHERE user='6666';" 2>/dev/null || true
  echo
  if [[ -x "$HELPER" ]]; then
    echo "Sync helper : $HELPER (present)"
  else
    echo "Sync helper : MISSING — run: $0 install-timer"
  fi
  if systemctl is-enabled vicidial-portal-ip-sync.timer >/dev/null 2>&1; then
    echo "Timer       : enabled ($(systemctl show -p NextElapseUSec --value vicidial-portal-ip-sync.timer 2>/dev/null || true))"
  else
    echo "Timer       : not enabled"
  fi
  if [[ -f "$APACHE_CONF" ]]; then
    echo "Apache front: ON ($APACHE_CONF)"
  else
    echo "Apache front: off (optional Require-ip layer)"
  fi
  echo
  echo "Admin URL : http://$(hostname -I 2>/dev/null | awk '{print $1}')/vicidial/admin.php"
  echo "Agent URL : http://$(hostname -I 2>/dev/null | awk '{print $1}')/agc/vicidial.php"
}

cmd_sync() {
  ensure_list
  if [[ -x "$HELPER" ]]; then
    "$HELPER"
  else
    # Inline minimal sync
    local new_ip pub_ip
    new_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [[ -z "$new_ip" ]] && new_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    pub_ip="$(curl -4 -fsS -m 3 https://ifconfig.me/ip 2>/dev/null || true)"
    [[ "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || pub_ip=""
    db "DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='${LIST_ID}';"
    for ip in 127.0.0.1 "$new_ip" $pub_ip; do
      [[ -n "$ip" ]] || continue
      db "INSERT INTO vicidial_ip_list_entries (ip_list_id,ip_address) VALUES ('${LIST_ID}','${ip}');"
    done
    echo "Synced: 127.0.0.1 ${new_ip} ${pub_ip}"
  fi
  cmd_enable_admin
  echo "Sync done."
}

cmd_add() {
  local ip="${1:-}"
  [[ -n "$ip" ]] || die "Usage: $0 add <IP>"
  valid_ip "$ip" || die "Invalid IP: $ip"
  ensure_list
  db "DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='${LIST_ID}' AND ip_address='${ip}';"
  db "INSERT INTO vicidial_ip_list_entries (ip_list_id,ip_address) VALUES ('${LIST_ID}','${ip}');"
  echo "Added ${ip} to ${LIST_ID}"
  # Refresh optional Apache layer if present
  [[ -f "$APACHE_CONF" ]] && cmd_apache_on >/dev/null
}

cmd_remove() {
  local ip="${1:-}"
  [[ -n "$ip" ]] || die "Usage: $0 remove <IP>"
  valid_ip "$ip" || die "Invalid IP: $ip"
  db "DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='${LIST_ID}' AND ip_address='${ip}';"
  echo "Removed ${ip} from ${LIST_ID}"
  [[ -f "$APACHE_CONF" ]] && cmd_apache_on >/dev/null
}

cmd_enable_admin() {
  ensure_list
  db "UPDATE vicidial_user_groups SET admin_ip_list='${LIST_ID}' WHERE user_group='ADMIN';"
  db "UPDATE vicidial_users SET modify_ip_lists='1', ignore_ip_list='1' WHERE user='6666';"
  echo "ADMIN group admin_ip_list=${LIST_ID} (6666 can ignore list)"
}

cmd_disable_admin() {
  db "UPDATE vicidial_user_groups SET admin_ip_list='' WHERE user_group='ADMIN';"
  echo "ADMIN group admin_ip_list cleared (admin UI open from any IP)"
}

# Optional Apache Require-ip in front of /vicidial/ (extra layer vs VICIdial lists)
cmd_apache_on() {
  ensure_list
  local ips
  ips="$(db "SELECT ip_address FROM vicidial_ip_list_entries WHERE ip_list_id='${LIST_ID}';" 2>/dev/null || true)"
  [[ -n "$ips" ]] || die "No IPs in ${LIST_ID}. Add some first: $0 add x.x.x.x && $0 sync"

  mkdir -p "$(dirname "$APACHE_CONF")"
  {
    echo "# Auto-generated by vicidial-front-ip.sh — do not edit by hand"
    echo "# Extra front gate for admin UI. Agents (/agc) are not restricted here."
    echo "<Directory \"${WWW_VICIDIAL}\">"
    echo "  Require all denied"
    while read -r ip; do
      [[ -n "$ip" ]] || continue
      echo "  Require ip ${ip}"
    done <<<"$ips"
    echo "</Directory>"
  } > "$APACHE_CONF"

  if command -v apachectl >/dev/null 2>&1; then
    apachectl configtest && systemctl reload apache2
  else
    systemctl reload apache2
  fi
  echo "Apache front IP gate ON for ${WWW_VICIDIAL}"
  echo "Allowed:"
  echo "$ips" | sed 's/^/  /'
}

cmd_apache_off() {
  rm -f "$APACHE_CONF"
  systemctl reload apache2 2>/dev/null || true
  echo "Apache front IP gate OFF"
}

cmd_install_timer() {
  need_root
  # Prefer installer helper if present; otherwise write a minimal one
  if [[ ! -x "$HELPER" ]]; then
    mkdir -p /usr/local/sbin /var/log/astguiclient
    cat > "$HELPER" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
LOG="${VICI_IP_SYNC_LOG:-/var/log/astguiclient/portal-ip-sync.log}"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >/dev/null; }
new_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -z "$new_ip" ]] && new_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
pub_ip="$(curl -4 -fsS -m 3 https://ifconfig.me/ip 2>/dev/null || true)"
[[ "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || pub_ip=""
[[ -n "$new_ip" ]] || { log "ERROR: no local IP"; exit 1; }
cli=(mysql -N -B -u root)
[[ -f /root/.my.cnf ]] && cli=(mysql --defaults-file=/root/.my.cnf -N -B)
command -v mariadb >/dev/null 2>&1 && [[ ! -f /root/.my.cnf ]] && cli=(mariadb -N -B -u root)
ex() { "${cli[@]}" asterisk -e "$1" 2>/dev/null || true; }
ex "UPDATE system_settings SET allow_ip_lists='1';"
ex "INSERT IGNORE INTO vicidial_ip_lists (ip_list_id,ip_list_name,active,user_group) VALUES ('PORTAL_DYNAMIC','Dynamic portal whitelist (auto)','Y','---ALL---');"
ex "UPDATE vicidial_ip_lists SET active='Y' WHERE ip_list_id='PORTAL_DYNAMIC';"
ex "DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='PORTAL_DYNAMIC';"
for ip in 127.0.0.1 "$new_ip" $pub_ip; do
  [[ -n "$ip" ]] || continue
  ex "INSERT INTO vicidial_ip_list_entries (ip_list_id,ip_address) VALUES ('PORTAL_DYNAMIC','${ip}');"
done
ex "UPDATE vicidial_user_groups SET admin_ip_list='PORTAL_DYNAMIC' WHERE user_group='ADMIN';"
log "Portal IP synced local=${new_ip} public=${pub_ip:-none}"
HELPER
    chmod 755 "$HELPER"
  fi

  cat > /etc/systemd/system/vicidial-portal-ip-sync.service <<EOF
[Unit]
Description=VICIdial dynamic portal IP list sync
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${HELPER}
EOF

  cat > /etc/systemd/system/vicidial-portal-ip-sync.timer <<'EOF'
[Unit]
Description=Hourly VICIdial portal IP validation sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vicidial-portal-ip-sync.timer
  systemctl start vicidial-portal-ip-sync.service || true
  echo "Installed and started vicidial-portal-ip-sync.timer"
  cmd_sync
}

usage() {
  cat <<EOF
VICIdial 12 — Front / portal IP validation

  $0 status              Show whitelist + group bindings
  $0 sync                Refresh LAN/public/127.0.0.1 into PORTAL_DYNAMIC
  $0 add <IP>            Allow an office / home IP
  $0 remove <IP>         Remove an IP
  $0 enable-admin        Bind ADMIN web UI to PORTAL_DYNAMIC
  $0 disable-admin       Open ADMIN web UI to any IP
  $0 apache-on           Extra Apache Require-ip gate for /vicidial/
  $0 apache-off          Remove Apache Require-ip gate
  $0 install-timer       Install hourly sync helper + systemd timer

Docs: /root/VICI/docs/FRONT-IP-VALIDATION.md
EOF
}

main() {
  need_root
  local cmd="${1:-status}"
  shift || true
  case "$cmd" in
    status)         cmd_status ;;
    sync)           cmd_sync ;;
    add)            cmd_add "${1:-}" ;;
    remove|rm|del)  cmd_remove "${1:-}" ;;
    enable-admin)   cmd_enable_admin ;;
    disable-admin)  cmd_disable_admin ;;
    apache-on)      cmd_apache_on ;;
    apache-off)     cmd_apache_off ;;
    install-timer)  cmd_install_timer ;;
    -h|--help|help) usage ;;
    *) die "Unknown command: $cmd (try: $0 help)" ;;
  esac
}

main "$@"
