#!/usr/bin/env bash
# install-vicidial12-opensuse.sh
#
# Ultimate OpenSUSE installer for VICIdial 12 (no ViciBox ISO).
# Detects existing services first, checks the full stack against the
# ViciBox 12 target (OpenSUSE Leap 15.6, PHP 8.2, MariaDB 10.11,
# Asterisk 18), then builds from zypper packages + source. Designed
# for Hetzner and other VPS/dedicated hosts where the 2GB ISO is too slow.
#
# Official stack (ViciBox 12.0.2 equivalent):
#   OpenSUSE Leap 15.6 · Kernel 6.4 · PHP 8.2 · MariaDB 10.11.9 · Asterisk 18
#   VICIdial 2.14 trunk · DB schema 1729+
#
# Usage:
#   ./install-vicidial12-opensuse.sh detect
#   ./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
#   ./install-vicidial12-opensuse.sh migrate --dump /path/asterisk.sql.gz
#
# Run as root on the target OpenSUSE server. Never use `zypper dup`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="1.2.1"
STARTED_AT="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${LOG_DIR:-/var/log/vicidial-installer}"
LOG_FILE="${LOG_DIR}/install-${STARTED_AT}.log"
REPORT_FILE="${LOG_DIR}/detect-${STARTED_AT}.txt"
CRED_FILE="${CRED_FILE:-/root/vicidial-credentials.txt}"
BACKUP_DIR="${BACKUP_DIR:-/root/vicidial-backups/${STARTED_AT}}"
ISO_MOUNT="${ISO_MOUNT:-/mnt/vicibox-iso}"
SRC_DIR="${SRC_DIR:-/usr/src}"
WWW_ROOT="${WWW_ROOT:-/srv/www/htdocs}"
ASTERISK_ETC="${ASTERISK_ETC:-/etc/asterisk}"
VICI_HOME="${VICI_HOME:-/usr/share/astguiclient}"
SVN_DIR="${SVN_DIR:-/usr/src/astguiclient/trunk}"

# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/conf/requirements.conf" ]]; then
  # shellcheck source=conf/requirements.conf
  source "${SCRIPT_DIR}/conf/requirements.conf"
fi

REQ_OS_ID="${REQ_OS_ID:-opensuse-leap}"
REQ_OS_VERSION_MIN="${REQ_OS_VERSION_MIN:-15.6}"
REQ_CPU_CORES_MIN="${REQ_CPU_CORES_MIN:-4}"
REQ_RAM_MB_MIN="${REQ_RAM_MB_MIN:-8192}"
REQ_RAM_MB_RECOMMENDED="${REQ_RAM_MB_RECOMMENDED:-16384}"
REQ_DISK_GB_MIN="${REQ_DISK_GB_MIN:-160}"
REQ_PHP_MIN="${REQ_PHP_MIN:-8.2}"
REQ_PHP_MAX="${REQ_PHP_MAX:-8.3}"
REQ_ASTERISK_MAJOR="${REQ_ASTERISK_MAJOR:-18}"
REQ_MARIADB_MIN="${REQ_MARIADB_MIN:-10.11}"
REQ_VICIBOX="${REQ_VICIBOX:-12.0.2}"
REQ_VICIDIAL_VERSION="${REQ_VICIDIAL_VERSION:-2.14}"
REQ_DB_SCHEMA_TARGET="${REQ_DB_SCHEMA_TARGET:-1729}"
REQ_SVN_URL="${REQ_SVN_URL:-svn://svn.eflo.net:3690/agc_2-X/trunk}"
REQ_ISO_NAME="${REQ_ISO_NAME:-ViciBox_V12.x86_64-12.0.2.iso}"
REQ_ISO_MD_NAME="${REQ_ISO_MD_NAME:-ViciBox_V12.x86_64-12.0.2-md.iso}"
REQ_ISO_BASE_URL="${REQ_ISO_BASE_URL:-https://download.vicidial.com/iso/vicibox/server}"
PATCH_BASE_URL="${PATCH_BASE_URL:-https://download.vicidial.com/asterisk-patches/Asterisk-18}"
ASTERISK_SRC_URL="${ASTERISK_SRC_URL:-https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-18-current.tar.gz}"
DAHDI_SRC_URL="${DAHDI_SRC_URL:-https://downloads.asterisk.org/pub/telephony/dahdi-linux-complete/dahdi-linux-complete-current.tar.gz}"
LIBPRI_SRC_URL="${LIBPRI_SRC_URL:-https://downloads.asterisk.org/pub/telephony/libpri/libpri-current.tar.gz}"

COMMAND=""
ISO_PATH=""
ISO_DEVICE=""
ROLE="express"
DUMP_PATH=""
FROM_HOST=""
DB_NAME="asterisk"
DB_USER="cron"
DB_PASS=""
DB_CUSTOM_USER="custom"
DB_CUSTOM_PASS=""
DB_ROOT_PASS=""
SERVER_IP=""
PUBLIC_IP=""
YES=0
FORCE=0
DRY_RUN=0
SKIP_ASTERISK_BUILD=0
SKIP_FIREWALL=0
LEGACY_PASSWORDS=0
STOP_CONFLICTS=0
KEEP_CONFLICTS=0
LAB=0
COMPILE_JOBS="$(nproc 2>/dev/null || echo 2)"

FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0
CONFLICT_COUNT=0
ISO_MOUNTED=0

declare -a REQ_ROWS=()
declare -a SERVICE_ROWS=()
declare -a CONFLICT_ROWS=()
declare -a ACTION_ROWS=()

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BOLD=""; C_RST=""
fi

log() {
  local msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%F %T')" "$msg" | tee -a "$LOG_FILE" >/dev/null 2>/dev/null || true
  printf '%s\n' "$msg"
}

header() {
  echo
  echo "${C_BOLD}${C_CYN}════════════════════════════════════════════════════════════${C_RST}"
  echo "${C_BOLD}${C_CYN} $*${C_RST}"
  echo "${C_BOLD}${C_CYN}════════════════════════════════════════════════════════════${C_RST}"
  log "=== $* ==="
}

ok()   { PASS_COUNT=$((PASS_COUNT + 1)); log "${C_GRN}[PASS]${C_RST} $*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); log "${C_YEL}[WARN]${C_RST} $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); log "${C_RED}[FAIL]${C_RST} $*"; }
info() { log "${C_BLU}[INFO]${C_RST} $*"; }
die()  { log "${C_RED}[FATAL]${C_RST} $*"; exit 1; }

run() {
  log "+ $*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "(dry-run) skipped"
    return 0
  fi
  "$@"
}

confirm() {
  local prompt="${1:-Continue?}"
  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "Refusing interactive prompt with no TTY. Re-run with --yes."
  fi
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

usage() {
  cat <<EOF
${C_BOLD}VICIdial 12 Ultimate Installer for OpenSUSE${C_RST}  v${VERSION}

Detects every relevant service and version first, then installs the
ViciBox 12 stack from packages + source (no 2GB ISO): OpenSUSE Leap 15.6,
PHP 8.2, MariaDB 10.11, Asterisk 18 (VICIdial patches), Apache, DAHDI,
and VICIdial 2.14. Intended for Hetzner and other VPS/dedicated servers.

${C_BOLD}USAGE${C_RST}
  $SCRIPT_NAME <command> [options]

${C_BOLD}COMMANDS${C_RST}
  detect         Scan OS, hardware, services, PHP, Asterisk, and database
  check          Detect + print the requirements matrix (no changes)
  install        Scratch install: box → PHP → MariaDB → DAHDI → Asterisk → VICIdial
  migrate        Backup and upgrade/import an existing VICIdial database
  help           Show this help

${C_BOLD}OPTIONS${C_RST}
  --role ROLE             express | database | web | telephony | archive
  --dump FILE             SQL dump (.sql or .sql.gz) for migrate
  --from-host HOST        Remote MariaDB host to dump during migrate
  --server-ip IP          LAN IP to bind VICIdial to (default: auto)
  --public-ip IP          Public IP for sip.conf externip
  --db-name NAME          Database name (default: asterisk)
  --db-user USER          App DB user (default: cron)
  --db-pass PASS          App DB password (generated if omitted)
  --yes                   Non-interactive yes to safe prompts
  --force                 Continue even if requirements FAIL
  --dry-run               Print actions without changing the system
  --stop-conflicts        Stop/disable conflicting services (nginx, etc.)
  --keep-conflicts        Leave conflicting services running (not recommended)
  --skip-asterisk-build   Do not compile Asterisk (use existing 18.x)
  --skip-firewall         Do not touch firewalld / iptables
  --legacy-passwords      Use historic VICIdial defaults (cron/1234) — insecure
  --lab                   One-call test box (2 CPU / 4 GB Leap 16 OK)
  --jobs N                Parallel compile jobs (default: nproc; lab uses 1)
  --help                  Show this help

${C_BOLD}EXAMPLES${C_RST}
  # Always start here. Detection never installs anything.
  $SCRIPT_NAME detect
  $SCRIPT_NAME check

  # Hetzner / stock OpenSUSE Leap 15.6 or 16.0 (no ISO download)
  $SCRIPT_NAME install --role express --yes --stop-conflicts

  # Small test VM (2 CPU, 4 GB, Leap 16) — one call, not production
  $SCRIPT_NAME install --lab --role express --yes --stop-conflicts

  # Import an old VICIdial dump and walk schema upgrades to 2.14 / ${REQ_DB_SCHEMA_TARGET}
  $SCRIPT_NAME migrate --dump /root/old-asterisk.sql.gz --yes

${C_BOLD}NOTES${C_RST}
  * No ViciBox ISO is downloaded, mounted, or required.
  * Leap 15.6 or 16.0. A 2-core / 4 GB box is a lab profile (one test call), not production.
  * Detection always runs before install or migrate.
  * Use 'zypper up' only. Never 'zypper dup' on a ViciDial box.
  * After a new MariaDB 10.11 database, explicit_defaults_for_timestamp=Off is required.
  * Default web login after a fresh install is 6666 / 1234 — change it immediately.

EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This command must run as root."
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

first_existing() {
  local p
  for p in "$@"; do
    if [[ -e "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

version_ge() {
  # true if $1 >= $2 (dotted numeric)
  printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1 | grep -qx "$2"
}

major_of() {
  printf '%s\n' "${1%%.*}"
}

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

file_contains() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] && grep -qF "$needle" "$file"
}

ensure_line() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -qxF "$line" "$file" 2>/dev/null; then
    printf '%s\n' "$line" >> "$file"
  fi
}

rand_pass() {
  if have_cmd openssl; then
    openssl rand -base64 18 | tr -d '/+=' | cut -c1-20
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
  fi
}

unit_state() {
  local unit="$1" s=""
  if have_cmd systemctl; then
    s="$(systemctl is-active "$unit" 2>/dev/null || true)"
    s="$(printf '%s' "$s" | tr -d '\r' | awk 'NF{print; exit}')"
  fi
  printf '%s' "${s:-unknown}"
}

unit_enabled() {
  local unit="$1"
  if have_cmd systemctl; then
    systemctl is-enabled "$unit" 2>/dev/null || echo "disabled"
  else
    echo "unknown"
  fi
}

pkg_installed() {
  local name="$1"
  if have_cmd rpm; then
    rpm -q "$name" >/dev/null 2>&1
  else
    return 1
  fi
}

listening_on() {
  local port="$1" proto="${2:-tcp}"
  if have_cmd ss; then
    ss -lntuH 2>/dev/null | awk -v p=":${port}" -v proto="$proto" '
      index($0, p) && (proto == "any" || tolower($1) ~ proto) { found=1 }
      END { exit found ? 0 : 1 }'
  elif have_cmd netstat; then
    netstat -lntu 2>/dev/null | grep -q ":${port}"
  else
    return 1
  fi
}

mysql_cli() {
  if have_cmd mariadb; then
    printf '%s' mariadb
  else
    printf '%s' mysql
  fi
}

mysql_exec() {
  local extra=()
  if [[ -n "${DB_ROOT_PASS}" ]]; then
    extra+=(-p"${DB_ROOT_PASS}")
  elif [[ -f /root/.my.cnf ]]; then
    :
  fi
  "$(mysql_cli)" -N -B -u root "${extra[@]}" "$@"
}

mysql_file() {
  local extra=()
  if [[ -n "${DB_ROOT_PASS}" ]]; then
    extra+=(-p"${DB_ROOT_PASS}")
  fi
  "$(mysql_cli)" -u root "${extra[@]}" "$@"
}

write_timestamp_cnf() {
  mkdir -p /etc/my.cnf.d
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  # Leap 16 / MariaDB 11 requires a [mysqld] group.
  cat > /etc/my.cnf.d/general.cnf <<'CNF'
[mysqld]
explicit_defaults_for_timestamp = Off
CNF
}

host_name() {
  local n=""
  if have_cmd hostname; then
    n="$(hostname 2>/dev/null || true)"
  fi
  if [[ -z "$n" ]] && have_cmd hostnamectl; then
    n="$(hostnamectl --static 2>/dev/null || true)"
  fi
  if [[ -z "$n" && -r /etc/hostname ]]; then
    n="$(tr -d ' \t\r\n' </etc/hostname)"
  fi
  if [[ -z "$n" ]]; then
    n="$(uname -n 2>/dev/null || echo unknown-host)"
  fi
  printf '%s' "$n"
}

detect_primary_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  if [[ -z "$ip" && -n "$(ip -4 addr show 2>/dev/null)" ]]; then
    ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
  fi
  printf '%s' "$ip"
}

os_pretty() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-unknown}"
  else
    printf 'unknown'
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi
  COMMAND="$1"
  shift
  case "$COMMAND" in
    -h|--help|help) COMMAND="help" ;;
    iso-verify|download-iso|write-usb)
      die "ISO install is disabled. This script never downloads the 2GB ViciBox ISO. On Hetzner install OpenSUSE Leap 15.6 with installimage, then run: $SCRIPT_NAME install --role express --yes --stop-conflicts"
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso|--iso=*|--device|--device=*)
        die "ISO options are disabled (Hetzner-friendly scratch install). Do not pass --iso. Run: $SCRIPT_NAME install --role express --yes --stop-conflicts"
        ;;
      --role) ROLE="${2:-}"; shift 2 ;;
      --role=*) ROLE="${1#*=}"; shift ;;
      --dump) DUMP_PATH="${2:-}"; shift 2 ;;
      --dump=*) DUMP_PATH="${1#*=}"; shift ;;
      --from-host) FROM_HOST="${2:-}"; shift 2 ;;
      --from-host=*) FROM_HOST="${1#*=}"; shift ;;
      --server-ip) SERVER_IP="${2:-}"; shift 2 ;;
      --server-ip=*) SERVER_IP="${1#*=}"; shift ;;
      --public-ip) PUBLIC_IP="${2:-}"; shift 2 ;;
      --public-ip=*) PUBLIC_IP="${1#*=}"; shift ;;
      --db-name) DB_NAME="${2:-}"; shift 2 ;;
      --db-user) DB_USER="${2:-}"; shift 2 ;;
      --db-pass) DB_PASS="${2:-}"; shift 2 ;;
      --yes|-y) YES=1; shift ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --stop-conflicts) STOP_CONFLICTS=1; shift ;;
      --keep-conflicts) KEEP_CONFLICTS=1; shift ;;
      --skip-asterisk-build) SKIP_ASTERISK_BUILD=1; shift ;;
      --skip-firewall) SKIP_FIREWALL=1; shift ;;
      --legacy-passwords) LEGACY_PASSWORDS=1; shift ;;
      --lab) LAB=1; shift ;;
      --jobs) COMPILE_JOBS="${2:-}"; shift 2 ;;
      -h|--help) COMMAND="help"; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  case "$ROLE" in
    express|database|web|telephony|archive|all) ;;
    *) die "Invalid --role '$ROLE' (express|database|web|telephony|archive)" ;;
  esac
}

# ---------------------------------------------------------------------------
# PHASE 1 — Detection
# ---------------------------------------------------------------------------

OS_ID=""; OS_VERSION=""; OS_NAME=""; KERNEL=""; ARCH=""
CPU_CORES=0; RAM_MB=0; DISK_GB=0; DISK_ROTTING="unknown"
PHP_VERSION=""; PHP_SAPI=""
ASTERISK_VERSION=""; MARIADB_VERSION=""
VICIBOX_PRESENT=0; VICIDIAL_PRESENT=0
DB_SCHEMA=""; DB_CODE_VERSION=""
APPARMOR="unknown"; SELINUX="unknown"
IS_VICIBOX=0

detect_os() {
  ARCH="$(uname -m)"
  KERNEL="$(uname -r)"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-unknown}"
  fi
  if [[ -f /etc/vicibox-release ]] || have_cmd vicibox-express || have_cmd vicibox-install; then
    IS_VICIBOX=1
    VICIBOX_PRESENT=1
  fi
  if [[ -f /etc/astguiclient.conf ]] || [[ -d /usr/share/astguiclient ]] || [[ -d /var/www/html/vicidial ]] || [[ -d ${WWW_ROOT}/vicidial ]]; then
    VICIDIAL_PRESENT=1
  fi
}

detect_hardware() {
  CPU_CORES="$(nproc 2>/dev/null || echo 1)"
  if [[ -r /proc/meminfo ]]; then
    RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  fi
  DISK_GB="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}')"
  local rota
  rota="$(lsblk -d -o ROTA,TYPE 2>/dev/null | awk '$2=="disk"{s+=$1; n++} END{if(n) print s}')"
  if [[ -n "$rota" && "$rota" -eq 0 ]]; then
    DISK_ROTTING="ssd"
  elif [[ -n "$rota" && "$rota" -gt 0 ]]; then
    DISK_ROTTING="hdd"
  fi
}

detect_php() {
  if have_cmd php; then
    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION.".".PHP_RELEASE_VERSION;' 2>/dev/null || php -v | awk 'NR==1{print $2}')"
    PHP_SAPI="$(php -r 'echo PHP_SAPI;' 2>/dev/null || echo unknown)"
  elif have_cmd php8; then
    PHP_VERSION="$(php8 -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION.".".PHP_RELEASE_VERSION;' 2>/dev/null || true)"
    PHP_SAPI="$(php8 -r 'echo PHP_SAPI;' 2>/dev/null || echo unknown)"
  fi
}

detect_asterisk() {
  if have_cmd asterisk; then
    ASTERISK_VERSION="$(asterisk -V 2>/dev/null | awk '{print $2}' | head -n1)"
  fi
}

detect_mariadb() {
  if have_cmd mysql; then
    MARIADB_VERSION="$(mysql -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  elif have_cmd mariadb; then
    MARIADB_VERSION="$(mariadb -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  fi
  if have_cmd mysql && mysqladmin ping >/dev/null 2>&1; then
    DB_SCHEMA="$(mysql_exec -e "SELECT db_schema_version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || true)"
    DB_CODE_VERSION="$(mysql_exec -e "SELECT version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || true)"
  fi
}

detect_security() {
  if have_cmd aa-status; then
    if aa-status --enabled >/dev/null 2>&1; then
      APPARMOR="enabled"
    else
      APPARMOR="disabled"
    fi
  elif [[ -d /sys/kernel/security/apparmor ]]; then
    APPARMOR="present"
  else
    APPARMOR="absent"
  fi
  if have_cmd getenforce; then
    SELINUX="$(getenforce 2>/dev/null || echo unknown)"
  elif [[ -f /etc/selinux/config ]]; then
    SELINUX="$(awk -F= '/^SELINUX=/{print $2}' /etc/selinux/config)"
  else
    SELINUX="absent"
  fi
}

# name|package_hint|ports|conflict_level|notes
SERVICE_CATALOG=(
  "apache2|apache2|80,443|required-web|VICIdial web UI"
  "httpd|apache2|80,443|required-web|Apache alias"
  "nginx|nginx|80,443|conflict-web|Conflicts with Apache on :80/:443"
  "lighttpd|lighttpd|80,443|conflict-web|Conflicts with Apache"
  "php-fpm|php-fpm|9000|info|Not required; Apache mod_php is used"
  "mariadb|mariadb|3306|required-db|VICIdial database"
  "mysql|mariadb|3306|conflict-db|Oracle MySQL collides with MariaDB"
  "mysqld|mysql|3306|conflict-db|Oracle MySQL service"
  "postgresql|postgresql|5432|unused|Not used by VICIdial"
  "asterisk|asterisk|5060,5038|required-tel|Telephony engine"
  "dahdi|dahdi| |required-tel|Timing source for MeetMe"
  "freeswitch|freeswitch|5060|conflict-tel|Conflicts with Asterisk SIP"
  "kamailio|kamailio|5060|conflict-tel|SIP proxy on 5060"
  "opensips|opensips|5060|conflict-tel|SIP proxy on 5060"
  "postfix|postfix|25|info|Mail; optional for reports"
  "sendmail|sendmail|25|info|Mail alternative"
  "exim|exim|25|info|Mail alternative"
  "firewalld|firewalld| |info|Must allow SIP/RTP/HTTP"
  "fail2ban|fail2ban| |info|Recommended after install"
  "named|bind|53|info|Local DNS"
  "dnsmasq|dnsmasq|53|info|Local DNS"
  "docker|docker| |warn-runtime|Containers can steal ports"
  "podman|podman| |warn-runtime|Containers can steal ports"
  "ntpd|ntp|123|info|Time sync (chronyd preferred)"
  "chronyd|chrony|123|required-time|Time sync is mandatory"
  "vsftpd|vsftpd|21|optional-archive|Archive server role"
  "tomcat|tomcat|8080|unused|Not used"
  "httpd2-prefork|apache2|80|info|Apache MPM"
)

detect_services() {
  SERVICE_ROWS=()
  CONFLICT_ROWS=()
  local entry name pkg ports level notes unit active enabled listening
  for entry in "${SERVICE_CATALOG[@]}"; do
    IFS='|' read -r name pkg ports level notes <<<"$entry"
    unit="$name"
    active="$(unit_state "$unit")"
    enabled="$(unit_enabled "$unit")"
    listening="no"
    if [[ -n "$ports" && "$ports" != " " ]]; then
      local p
      IFS=',' read -ra plist <<<"$ports"
      for p in "${plist[@]}"; do
        p="$(trim "$p")"
        [[ -z "$p" ]] && continue
        if listening_on "$p" any; then
          listening="yes"
        fi
      done
    fi
    if [[ "$active" == "active" || "$enabled" == "enabled" ]] || pkg_installed "$pkg" || have_cmd "$name"; then
      SERVICE_ROWS+=("$name|$active|$enabled|$listening|$level|$notes")
      case "$level" in
        conflict-web|conflict-db|conflict-tel)
          if [[ "$active" == "active" || "$listening" == "yes" ]]; then
            CONFLICT_ROWS+=("$name|$level|$notes")
            CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
          fi
          ;;
      esac
    fi
  done

  # Catch anything else bound to VICIdial ports.
  local port
  for port in 80 443 3306 5038 5060 4569; do
    if listening_on "$port" any; then
      info "Port ${port} is in use."
    fi
  done
}

add_req() {
  # status|component|found|required|detail
  REQ_ROWS+=("$1|$2|$3|$4|$5")
  case "$1" in
    PASS) ok "$2: $3  (need $4) — $5" ;;
    WARN) warn "$2: $3  (need $4) — $5" ;;
    FAIL) fail "$2: $3  (need $4) — $5" ;;
  esac
}

evaluate_requirements() {
  REQ_ROWS=()
  FAIL_COUNT=0; WARN_COUNT=0; PASS_COUNT=0

  header "Requirements matrix (ViciBox ${REQ_VICIBOX} target)"

  local os_ok="FAIL"
  if [[ "$OS_ID" == "opensuse-leap" || "$OS_ID" == "opensuse" ]]; then
    if version_ge "$OS_VERSION" "$REQ_OS_VERSION_MIN"; then
      os_ok="PASS"
    elif [[ "$OS_VERSION" == "15.5" ]]; then
      os_ok="WARN"
    fi
  elif [[ "$IS_VICIBOX" -eq 1 ]]; then
    os_ok="PASS"
  fi
  add_req "$os_ok" "Operating system" "$OS_NAME" "openSUSE Leap 15.6 or 16.0" "ViciBox 12 was 15.6; Leap 16.0 is OK for a lab/test call"

  local arch_ok="FAIL"
  [[ "$ARCH" == "x86_64" ]] && arch_ok="PASS"
  add_req "$arch_ok" "Architecture" "$ARCH" "x86_64" "32-bit is not supported"

  local cpu_ok="FAIL"
  if [[ "$CPU_CORES" -ge "$REQ_CPU_CORES_MIN" ]]; then cpu_ok="PASS"
  elif [[ "$CPU_CORES" -ge 1 ]]; then cpu_ok="WARN"; fi
  add_req "$cpu_ok" "CPU cores" "$CPU_CORES" "${REQ_CPU_CORES_MIN}+ production / 1+ lab" "2 cores is enough for one test call"

  local ram_ok="FAIL"
  if [[ "$RAM_MB" -ge 15360 ]]; then ram_ok="PASS"
  elif [[ "$RAM_MB" -ge "$REQ_RAM_MB_MIN" ]]; then ram_ok="WARN"
  elif [[ "$RAM_MB" -ge 1536 ]]; then ram_ok="WARN"; fi
  add_req "$ram_ok" "RAM" "${RAM_MB} MB" "1536 MB lab / ${REQ_RAM_MB_MIN} MB production" "4 GB is a one-call lab box; 16 GB ECC for production"

  local disk_ok="FAIL"
  if [[ -n "$DISK_GB" && "$DISK_GB" -ge 500 ]]; then disk_ok="PASS"
  elif [[ -n "$DISK_GB" && "$DISK_GB" -ge "$REQ_DISK_GB_MIN" ]]; then disk_ok="WARN"
  elif [[ -n "$DISK_GB" && "$DISK_GB" -ge 40 ]]; then disk_ok="WARN"; fi
  add_req "$disk_ok" "Root disk" "${DISK_GB} GB (${DISK_ROTTING})" "${REQ_DISK_GB_MIN} GB SSD" "Lab VMs can be smaller; production needs SSD ≥160 GB"

  if [[ "$DISK_ROTTING" == "hdd" ]]; then
    add_req "WARN" "Storage type" "rotational HDD" "SSD / NVMe" "ViciBox 12 docs require SATA SSD minimum"
  fi

  # PHP — missing is installable; too-old installed versions are FAIL.
  local php_ok="WARN" php_mm=""
  if [[ -n "$PHP_VERSION" ]]; then
    php_mm="$(printf '%s' "$PHP_VERSION" | awk -F. '{print $1"."$2}')"
    if version_ge "$php_mm" "$REQ_PHP_MIN" && ! version_ge "$php_mm" "8.5"; then
      php_ok="PASS"
    elif version_ge "$php_mm" "8.0"; then
      php_ok="WARN"
    else
      php_ok="FAIL"
    fi
  else
    PHP_VERSION="not installed"
    php_ok="WARN"
    PHP_SAPI="-"
  fi
  add_req "$php_ok" "PHP" "${PHP_VERSION}${PHP_SAPI:+ ($PHP_SAPI)}" "${REQ_PHP_MIN}+ (8.2–8.4)" "Leap 16 may ship PHP 8.4; missing packages are installed automatically."

  # Asterisk — missing is installable; 11/13 need a rebuild (FAIL unless --force).
  local ast_ok="WARN" ast_major=""
  if [[ -n "$ASTERISK_VERSION" ]]; then
    ast_major="$(major_of "$ASTERISK_VERSION")"
    if [[ "$ast_major" == "$REQ_ASTERISK_MAJOR" ]]; then ast_ok="PASS"
    elif [[ "$ast_major" == "16" || "$ast_major" == "20" ]]; then ast_ok="WARN"
    else ast_ok="FAIL"
    fi
  else
    ASTERISK_VERSION="not installed"
    ast_ok="WARN"
  fi
  add_req "$ast_ok" "Asterisk" "$ASTERISK_VERSION" "${REQ_ASTERISK_MAJOR}.x-vici" "Must be compiled with VICIdial Asterisk-18 patches. Missing Asterisk is built from source."

  # MariaDB — missing is installable.
  local db_ok="WARN" db_mm=""
  if [[ -n "$MARIADB_VERSION" ]]; then
    db_mm="$(printf '%s' "$MARIADB_VERSION" | awk -F. '{print $1"."$2}')"
    if version_ge "$db_mm" "$REQ_MARIADB_MIN"; then db_ok="PASS"
    elif version_ge "$db_mm" "10.5"; then db_ok="WARN"
    else db_ok="FAIL"; fi
  else
    MARIADB_VERSION="not installed"
    db_ok="WARN"
  fi
  add_req "$db_ok" "MariaDB" "$MARIADB_VERSION" "${REQ_MARIADB_MIN}+" "TIMESTAMP implicit ON UPDATE broke in 10.11. Missing MariaDB is installed automatically."

  if [[ -n "$DB_SCHEMA" ]]; then
    local schema_ok="WARN"
    if [[ "$DB_SCHEMA" -ge "$REQ_DB_SCHEMA_TARGET" ]]; then schema_ok="PASS"
    elif [[ "$DB_SCHEMA" -ge 1478 ]]; then schema_ok="WARN"; fi
    add_req "$schema_ok" "DB schema" "${DB_SCHEMA} (${DB_CODE_VERSION:-unknown})" "${REQ_DB_SCHEMA_TARGET}+ / ${REQ_VICIDIAL_VERSION}" "Cannot skip major upgrade SQL files"
  else
    add_req "WARN" "DB schema" "no asterisk DB" "will create ${REQ_VICIDIAL_VERSION} schema" "Fresh install path"
  fi

  local time_ok="WARN"
  if [[ "$(unit_state chronyd)" == "active" || "$(unit_state ntpd)" == "active" ]]; then
    time_ok="PASS"
  fi
  add_req "$time_ok" "Time sync" "chronyd=$(unit_state chronyd) ntpd=$(unit_state ntpd)" "chronyd active" "Dialer/DB/PHP clocks must match"

  local sec_ok="PASS"
  if [[ "$SELINUX" =~ [Ee]nforcing ]]; then sec_ok="FAIL"; fi
  if [[ "$APPARMOR" == "enabled" ]]; then
    [[ "$sec_ok" == "PASS" ]] && sec_ok="WARN"
  fi
  add_req "$sec_ok" "MAC / LSM" "SELinux=${SELINUX} AppArmor=${APPARMOR}" "SELinux off; AppArmor permissive" "VICIdial assumes SELinux is disabled"

  add_req "PASS" "Install method" "scratch (packages + source)" "no ViciBox ISO" "Leap 15.6 or 16.0 lab/Hetzner path"
}

print_service_table() {
  header "Detected services"
  printf '  %-16s %-10s %-12s %-10s %-16s %s\n' "SERVICE" "ACTIVE" "ENABLED" "PORTS" "CLASS" "NOTES"
  printf '  %-16s %-10s %-12s %-10s %-16s %s\n' "--------" "------" "-------" "-----" "-----" "-----"
  local row name active enabled listening level notes
  if [[ ${#SERVICE_ROWS[@]} -eq 0 ]]; then
    info "No catalogued telephony/web/database services found."
    return
  fi
  for row in "${SERVICE_ROWS[@]}"; do
    IFS='|' read -r name active enabled listening level notes <<<"$row"
    printf '  %-16s %-10s %-12s %-10s %-16s %s\n' "$name" "$active" "$enabled" "$listening" "$level" "$notes"
  done
  echo
  if [[ ${#CONFLICT_ROWS[@]} -gt 0 ]]; then
    warn "Conflicting services that must be resolved before install:"
    for row in "${CONFLICT_ROWS[@]}"; do
      IFS='|' read -r name level notes <<<"$row"
      echo "    - ${name}  [${level}]  ${notes}"
    done
  else
    ok "No conflicting web/DB/telephony services are active."
  fi
}

print_detect_summary() {
  header "Host inventory"
  cat <<EOF
  Hostname        : $(host_name)
  OS              : ${OS_NAME} (${OS_ID} ${OS_VERSION})
  Kernel          : ${KERNEL}
  Arch            : ${ARCH}
  CPU cores       : ${CPU_CORES}
  RAM             : ${RAM_MB} MB
  Root disk       : ${DISK_GB} GB (${DISK_ROTTING})
  Primary IPv4    : $(detect_primary_ip)
  ViciBox image   : $([[ $IS_VICIBOX -eq 1 ]] && echo yes || echo no)
  VICIdial files  : $([[ $VICIDIAL_PRESENT -eq 1 ]] && echo yes || echo no)
  PHP             : ${PHP_VERSION:-none}
  Asterisk        : ${ASTERISK_VERSION:-none}
  MariaDB         : ${MARIADB_VERSION:-none}
  DB schema       : ${DB_SCHEMA:-none}
  AppArmor        : ${APPARMOR}
  SELinux         : ${SELINUX}
  Lab profile     : $([[ ${LAB:-0} -eq 1 ]] && echo "yes (one test call)" || echo no)
  Log             : ${LOG_FILE}
EOF
}

write_detect_report() {
  mkdir -p "$(dirname "$REPORT_FILE")"
  {
    echo "VICIdial 12 detection report — $(date -Is)"
    echo "Host: $(host_name)  OS: ${OS_NAME}"
    echo
    echo "PASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT} CONFLICTS=${CONFLICT_COUNT}"
  } > "$REPORT_FILE"
  info "Wrote detection report: ${REPORT_FILE}"
}

maybe_enable_lab() {
  if [[ "$LAB" -eq 0 ]]; then
    if [[ "${RAM_MB:-0}" -lt 6144 || "${CPU_CORES:-0}" -lt 4 ]]; then
      LAB=1
    fi
  fi
  if [[ "$LAB" -eq 1 ]]; then
    warn "Lab/test profile enabled (${CPU_CORES} cores, ${RAM_MB} MB RAM) — sized for one test call, not production"
    if [[ "${COMPILE_JOBS}" -gt 1 ]]; then
      COMPILE_JOBS=1
      info "Asterisk compile jobs set to 1 to avoid OOM on a small box"
    fi
  fi
}

phase_detect() {
  header "Phase 1 — Detect everything"
  detect_os
  detect_hardware
  maybe_enable_lab
  detect_php
  detect_asterisk
  detect_mariadb
  detect_security
  detect_services
  print_detect_summary
  print_service_table
  evaluate_requirements
  write_detect_report
  echo
  info "Summary: ${PASS_COUNT} pass, ${WARN_COUNT} warn, ${FAIL_COUNT} fail, ${CONFLICT_COUNT} conflicts"
}

# ---------------------------------------------------------------------------
# Conflicts
# ---------------------------------------------------------------------------

stop_conflict_service() {
  local name="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "(dry-run) would stop $name"
    return
  fi
  if have_cmd systemctl; then
    systemctl stop "$name" 2>/dev/null || true
    systemctl disable "$name" 2>/dev/null || true
  fi
}

resolve_conflicts() {
  if [[ ${#CONFLICT_ROWS[@]} -eq 0 ]]; then
    return 0
  fi
  header "Conflicting services"
  if [[ "$KEEP_CONFLICTS" -eq 1 ]]; then
    warn "Leaving conflicts running because --keep-conflicts was set"
    return 0
  fi
  if [[ "$STOP_CONFLICTS" -eq 1 || "$YES" -eq 1 ]]; then
    local row name level notes
    for row in "${CONFLICT_ROWS[@]}"; do
      IFS='|' read -r name level notes <<<"$row"
      warn "Stopping $name ($level)"
      stop_conflict_service "$name"
    done
    return 0
  fi
  fail "Active conflicts must be resolved. Re-run with --stop-conflicts or --keep-conflicts --force"
  [[ "$FORCE" -eq 1 ]] || die "Refusing to install over conflicting services"
}

# ---------------------------------------------------------------------------
# Packages / PHP / DB / Asterisk / VICIdial
# ---------------------------------------------------------------------------

zypper_n() {
  run zypper --non-interactive --no-confirm --gpg-auto-import-keys "$@"
}

zypper_try_in() {
  local p rc=0
  for p in "$@"; do
    if zypper --non-interactive --no-confirm --gpg-auto-import-keys in -y "$p" >/dev/null 2>&1; then
      info "Installed $p"
    else
      warn "Package not available (Leap ${OS_VERSION}): $p"
      rc=1
    fi
  done
  return "$rc"
}

ensure_opensuse_repos() {
  have_cmd zypper || die "zypper not found — this installer is for OpenSUSE"
  info "Refreshing zypper metadata (never using 'zypper dup')"
  zypper_n ref || warn "zypper ref had warnings"
}

install_base_packages() {
  header "Phase 2 — Base OpenSUSE packages (box)"
  local critical=(
    bash coreutils util-linux procps iproute2 iputils
    wget curl tar gzip bzip2 unzip xz patch
    git subversion gcc gcc-c++ make autoconf automake libtool
    screen sox bind-utils lsof psmisc chrony python3 perl
  )
  zypper_n in -y "${critical[@]}" || {
    warn "Batch install had missing names; retrying one by one"
    zypper_try_in "${critical[@]}" || true
  }
  have_cmd gcc || die "gcc is required to compile Asterisk 18"
  have_cmd make || die "make is required to compile Asterisk 18"
  have_cmd svn || have_cmd git || die "subversion or git is required to fetch VICIdial"

  local devel=(
    ncurses-devel libxml2-devel openssl-devel libopenssl-devel
    sqlite3-devel sqlite-devel libuuid-devel speex-devel libcurl-devel
    unixODBC-devel kernel-devel kernel-default-devel
    libsrtp-devel jansson-devel newt-devel speexdsp-devel
  )
  zypper_try_in "${devel[@]}" || true

  local perlmods=(
    perl-DBI perl-DBD-mysql perl-DBD-MariaDB perl-Net-Telnet perl-Time-HiRes
    perl-IO-Socket-SSL perl-libwww-perl perl-Digest-MD5
    perl-YAML perl-JSON perl-Try-Tiny perl-Mail-Sendmail hostname
    lame mpg123 pv nmap sipsak
  )
  zypper_try_in "${perlmods[@]}" || true

  if have_cmd systemctl; then
    run systemctl enable --now chronyd || warn "Could not enable chronyd"
  fi
}

install_php() {
  header "Phase 3 — PHP ${REQ_PHP_MIN} (web)"
  local php_pkgs=(
    php8 php8-mysql php8-mysqli php8-gd php8-mbstring php8-xmlwriter
    php8-zip php8-curl php8-bcmath php8-opcache php8-gettext php8-iconv
    php8-tokenizer php8-ctype php8-fileinfo php8-dom php8-xmlreader
    php8-zlib php8-session php8-posix php8-sockets
    apache2 apache2-mod_php8 apache2-utils
  )
  zypper_n in -y "${php_pkgs[@]}" || {
    warn "Some PHP modules missing on Leap ${OS_VERSION}; installing what exists"
    zypper_try_in "${php_pkgs[@]}" || true
  }
  zypper_try_in apache2 apache2-mod_php8 apache2-utils || true
  have_cmd php || have_cmd php8 || die "PHP did not install. On Leap 16 try: zypper se php8"

  # Leap 15.6 php8 is 8.2. Re-detect.
  detect_php
  local php_mm
  php_mm="$(printf '%s' "$PHP_VERSION" | awk -F. '{print $1"."$2}')"
  if [[ -z "$php_mm" ]] || ! version_ge "$php_mm" "$REQ_PHP_MIN"; then
    fail "PHP is ${PHP_VERSION:-missing}; need ${REQ_PHP_MIN}+"
    [[ "$FORCE" -eq 1 ]] || die "PHP version does not meet ViciBox 12 requirements"
  else
    ok "PHP ${PHP_VERSION} meets ${REQ_PHP_MIN}"
  fi

  local php_ini
  php_ini="$(first_existing /etc/php8/apache2/php.ini /etc/php8/cli/php.ini /etc/php.ini || true)"
  if [[ -n "$php_ini" ]]; then
    info "Tuning ${php_ini}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      sed -i \
        -e 's/^short_open_tag = .*/short_open_tag = On/' \
        -e 's/^max_execution_time = .*/max_execution_time = 330/' \
        -e 's/^max_input_time = .*/max_input_time = 360/' \
        -e 's/^memory_limit = .*/memory_limit = 128M/' \
        -e 's/^post_max_size = .*/post_max_size = 64M/' \
        -e 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' \
        -e 's/^default_socket_timeout = .*/default_socket_timeout = 360/' \
        "$php_ini"
    fi
  fi

  if have_cmd a2enmod; then
    run a2enmod php8 || true
    run a2enmod rewrite || true
  fi
  # OpenSUSE Apache default document root is /srv/www/htdocs
  mkdir -p "$WWW_ROOT"
  if have_cmd systemctl; then
    run systemctl enable apache2
    run systemctl restart apache2
  fi
}

configure_mariadb() {
  header "Phase 4 — MariaDB ${REQ_MARIADB_MIN} + TIMESTAMP fix"
  zypper_n in -y mariadb mariadb-client mariadb-tools || zypper_try_in mariadb mariadb-client || die "MariaDB install failed"
  mkdir -p /etc/my.cnf.d
  local innodb_pool="256M" key_buf="64M" max_conn="80" tmp_tbl="64M"
  if [[ "${RAM_MB:-0}" -ge 12000 ]]; then
    innodb_pool="1G"; key_buf="512M"; max_conn="500"; tmp_tbl="128M"
  elif [[ "${RAM_MB:-0}" -ge 7000 ]]; then
    innodb_pool="512M"; key_buf="128M"; max_conn="200"; tmp_tbl="96M"
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    cat > /etc/my.cnf.d/vicidial.cnf <<CNF
[mysqld]
max_connections = ${max_conn}
open_files_limit = 65535
table_open_cache = 1024
key_buffer_size = ${key_buf}
max_allowed_packet = 64M
query_cache_size = 0
query_cache_type = 0
innodb_buffer_pool_size = ${innodb_pool}
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
tmp_table_size = ${tmp_tbl}
max_heap_table_size = ${tmp_tbl}
skip-name-resolve
bind-address = 127.0.0.1
explicit_defaults_for_timestamp = Off
character-set-server = utf8
collation-server = utf8_unicode_ci
CNF
    info "MariaDB innodb_buffer_pool_size=${innodb_pool} (RAM ${RAM_MB} MB)"
  fi
  write_timestamp_cnf
  if have_cmd systemctl; then
    run systemctl enable mariadb
    run systemctl restart mariadb
  fi
  detect_mariadb
  ok "MariaDB ${MARIADB_VERSION:-installed}; TIMESTAMP implicit ON UPDATE restored"

  if [[ "$LEGACY_PASSWORDS" -eq 1 ]]; then
    DB_PASS="${DB_PASS:-1234}"
    DB_CUSTOM_PASS="${DB_CUSTOM_PASS:-custom1234}"
  else
    DB_PASS="${DB_PASS:-$(rand_pass)}"
    DB_CUSTOM_PASS="${DB_CUSTOM_PASS:-$(rand_pass)}"
  fi
  if [[ -z "$DB_ROOT_PASS" && "$LEGACY_PASSWORDS" -eq 0 ]]; then
    DB_ROOT_PASS="$(rand_pass)"
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    mysql_file <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_CUSTOM_USER}'@'localhost' IDENTIFIED BY '${DB_CUSTOM_PASS}';
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_CUSTOM_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    if [[ -n "$DB_ROOT_PASS" ]]; then
      mysql_file -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;" || \
        mysql_file -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_ROOT_PASS}'); FLUSH PRIVILEGES;" || \
        warn "Could not set MariaDB root password automatically"
      umask 077
      cat > /root/.my.cnf <<EOF
[client]
user=root
password=${DB_ROOT_PASS}
EOF
    fi
  fi
}

write_credentials() {
  umask 077
  mkdir -p "$(dirname "$CRED_FILE")"
  cat > "$CRED_FILE" <<EOF
# Generated by ${SCRIPT_NAME} on $(date -Is)
# Mode 0600. Change the web admin password immediately.

SERVER_IP=${SERVER_IP}
PUBLIC_IP=${PUBLIC_IP}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_CUSTOM_USER=${DB_CUSTOM_USER}
DB_CUSTOM_PASS=${DB_CUSTOM_PASS}
WEB_USER=6666
WEB_PASS=1234
EOF
  chmod 600 "$CRED_FILE"
  ok "Credentials written to ${CRED_FILE}"
}

ensure_kernel_build_dir() {
  local kver="${1:-$(uname -r)}"
  local build="/lib/modules/${kver}/build"
  if [[ -f "${build}/Makefile" ]]; then
    ok "Kernel headers present for ${kver}"
    return 0
  fi
  info "Installing kernel headers for ${kver}"
  zypper_try_in kernel-default-devel kernel-devel kernel-source kernel-syms || true
  local ver="${kver%-default}"
  zypper --non-interactive --no-confirm --gpg-auto-import-keys in -y "kernel-default-devel-${ver}" >/dev/null 2>&1 || true
  if [[ -f "${build}/Makefile" ]]; then
    ok "Kernel headers installed for ${kver}"
    return 0
  fi
  local obj=""
  obj="$(ls -d /usr/src/linux-*-obj/*/default /usr/src/linux-obj/*/default 2>/dev/null | head -n1 || true)"
  mkdir -p "/lib/modules/${kver}"
  if [[ -n "$obj" ]]; then
    ln -sfn "$obj" "$build"
  elif [[ -d /usr/src/linux ]]; then
    ln -sfn /usr/src/linux "$build"
  fi
  if [[ -f "${build}/Makefile" ]]; then
    ok "Linked kernel build dir ${build}"
    return 0
  fi
  warn "No matching kernel headers for ${kver} (DAHDI skip is OK on a Cloud VM)."
  return 1
}

install_dahdi() {
  header "Phase 5 — DAHDI timing (Asterisk MeetMe)"
  if zypper se -s dahdi-linux >/dev/null 2>&1; then
    local leap_repo="15.6"
    [[ "${OS_VERSION}" == 16* ]] && leap_repo="16.0"
    zypper_n ar -f "https://download.opensuse.org/repositories/home:vicidial/${leap_repo}/home:vicidial.repo" home-vicidial 2>/dev/null || \
      zypper_n ar -f https://download.opensuse.org/repositories/home:vicidial/15.6/home:vicidial.repo home-vicidial 2>/dev/null || true
    zypper_n ref home-vicidial || true
    zypper_n in -y dahdi-linux dahdi-tools || warn "OBS DAHDI packages not available"
  fi
  if have_cmd dahdi_cfg || [[ -d /etc/dahdi ]]; then
    run modprobe dahdi || warn "dahdi module not loaded (OK on VMs without telephony cards)"
    have_cmd dahdi_genconf && run dahdi_genconf || true
    have_cmd dahdi_cfg && run dahdi_cfg || true
    ok "DAHDI present"
    return
  fi
  if ! ensure_kernel_build_dir "$(uname -r)"; then
    warn "Skipping DAHDI source build. Asterisk 18 will use timerfd (ConfBridge) on this lab VM."
    return 0
  fi
  info "Building DAHDI from source"
  mkdir -p "$SRC_DIR"
  local d=""
  (
    cd "$SRC_DIR"
    wget -O dahdi-linux-complete-current.tar.gz "$DAHDI_SRC_URL"
    tar xf dahdi-linux-complete-current.tar.gz
  )
  d="$(find "$SRC_DIR" -maxdepth 1 -type d -name 'dahdi-linux-complete-*' | sort | tail -n1)"
  if [[ -z "$d" ]]; then
    warn "DAHDI source tree not found; continuing without DAHDI"
    return 0
  fi
  if ! make -C "$d" all; then
    warn "DAHDI kernel compile failed for $(uname -r). Lab VMs can run without DAHDI (timerfd)."
    return 0
  fi
  make -C "$d" install || warn "DAHDI make install failed"
  make -C "$d" config || true
  modprobe dahdi || warn "dahdi module not loaded (OK on VMs without telephony cards)"
}

install_libpri() {
  if pkg_installed libpri1 || pkg_installed libpri; then
    return
  fi
  zypper_n in -y libpri1 libpri-devel || true
}

asterisk_already_ok() {
  detect_asterisk
  local major
  major="$(major_of "${ASTERISK_VERSION:-0}")"
  [[ "$major" == "$REQ_ASTERISK_MAJOR" ]]
}

install_asterisk() {
  header "Phase 6 — Asterisk ${REQ_ASTERISK_MAJOR} with VICIdial patches"
  if [[ "$SKIP_ASTERISK_BUILD" -eq 1 ]]; then
    warn "Skipping Asterisk build (--skip-asterisk-build)"
    return
  fi
  if asterisk_already_ok && [[ "$FORCE" -eq 0 ]]; then
    ok "Asterisk ${ASTERISK_VERSION} already matches major ${REQ_ASTERISK_MAJOR}"
    info "Re-run with --force to rebuild and re-patch"
    return
  fi
  install_libpri
  mkdir -p "$SRC_DIR/asterisk-build"
  (
    cd "$SRC_DIR/asterisk-build"
    run wget -O asterisk-18-current.tar.gz "$ASTERISK_SRC_URL"
    run tar xf asterisk-18-current.tar.gz
    local tree
    tree="$(find "$SRC_DIR/asterisk-build" -maxdepth 1 -type d -name 'asterisk-18*' | sort | tail -n1)"
    [[ -n "$tree" ]] || die "Asterisk 18 source tree not found"
    cd "$tree"
    info "Downloading VICIdial Asterisk 18 patches"
    local p
    for p in amd_stats-18.patch iax_peer_status-18.patch sip_peer_status-18.patch \
             timeout_reset_dial_app-18.patch timeout_reset_dial_core-18.patch; do
      run wget -O "$p" "${PATCH_BASE_URL}/${p}"
    done
    patch -p0 < amd_stats-18.patch --forward -d . >/dev/null 2>&1 || \
      patch < amd_stats-18.patch apps/app_amd.c || warn "amd_stats patch may already be applied"
    patch < iax_peer_status-18.patch channels/chan_iax2.c || warn "iax patch skipped"
    patch < sip_peer_status-18.patch channels/chan_sip.c || warn "sip patch skipped"
    patch < timeout_reset_dial_app-18.patch apps/app_dial.c || warn "dial app patch skipped"
    patch < timeout_reset_dial_core-18.patch main/dial.c || warn "dial core patch skipped"

    contrib/scripts/install_prereq install || warn "Asterisk install_prereq reported issues"
    run ./configure --libdir=/usr/lib64 --with-gsm=internal --with-ssl --enable-asteriskssl \
      --with-pjproject-bundled --with-jansson-bundled
    run make menuselect.makeopts
    local enable
    for enable in app_meetme app_confbridge res_http_websocket res_srtp res_timing_dahdi \
                  res_timing_timerfd res_timing_pthread codec_opus chan_sip; do
      menuselect/menuselect --enable "$enable" menuselect.makeopts || warn "menuselect enable $enable failed"
    done
    run make -j "${COMPILE_JOBS}" all
    run make install
    run make samples
    run make config || true
    run ldconfig
  )
  mkdir -p /var/lib/asterisk /var/spool/asterisk/monitorDONE /var/spool/asterisk/monitor \
    /var/log/asterisk /usr/share/asterisk/agi-bin
  if [[ -f /etc/asterisk/modules.conf ]]; then
    sed -i 's/^noload *= *chan_sip.so/;noload = chan_sip.so/' /etc/asterisk/modules.conf || true
  fi
  detect_asterisk
  ok "Asterisk installed: ${ASTERISK_VERSION:-unknown}"
}

checkout_vicidial() {
  header "Phase 7 — VICIdial ${REQ_VICIDIAL_VERSION} from SVN"
  mkdir -p /usr/src/astguiclient
  if [[ -d "${SVN_DIR}/.svn" ]]; then
    info "Updating existing SVN working copy"
    run svn up "$SVN_DIR"
  else
    run svn checkout "$REQ_SVN_URL" "$SVN_DIR"
  fi
  [[ -f "${SVN_DIR}/install.pl" ]] || die "install.pl missing after SVN checkout"
}

load_schema_if_empty() {
  local tables
  tables="$(mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo 0)"
  if [[ "${tables:-0}" -gt 0 ]]; then
    info "Database ${DB_NAME} already has ${tables} tables — leaving it (use migrate to upgrade)"
    return
  fi
  local schema
  schema="$(first_existing \
    "${SVN_DIR}/extras/MySQL_AST_CREATE_tables.sql" \
    "${SVN_DIR}/extras/MySQL_AST_CREATE_tables-utf8.sql" || true)"
  [[ -n "$schema" ]] || die "Could not find MySQL_AST_CREATE_tables.sql in SVN extras"
  info "Loading fresh schema from $(basename "$schema")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mysql_file --database="$DB_NAME" -f < "$schema"
    local first
    first="$(first_existing "${SVN_DIR}/extras/first_server_install.sql" || true)"
    if [[ -n "$first" ]]; then
      mysql_file --database="$DB_NAME" -f < "$first" || warn "first_server_install.sql reported errors"
    fi
  fi
}

run_install_pl() {
  SERVER_IP="${SERVER_IP:-$(detect_primary_ip)}"
  [[ -n "$SERVER_IP" ]] || die "Could not detect server IP; pass --server-ip"
  PUBLIC_IP="${PUBLIC_IP:-$SERVER_IP}"
  (
    cd "$SVN_DIR"
    run perl install.pl \
      --no-prompt \
      --copy_sample_conf_files \
      --asterisk_version="${REQ_ASTERISK_MAJOR}.0" \
      --web="${WWW_ROOT}" \
      --DB_server=localhost \
      --DB_database="${DB_NAME}" \
      --DB_user="${DB_USER}" \
      --DB_pass="${DB_PASS}" \
      --DB_custom_user="${DB_CUSTOM_USER}" \
      --DB_custom_pass="${DB_CUSTOM_PASS}" \
      --DB_port=3306 \
      --server_ip="${SERVER_IP}" || warn "install.pl returned non-zero (review log)"
  )
  if [[ -f /etc/asterisk/sip.conf && -n "$PUBLIC_IP" && "$DRY_RUN" -eq 0 ]]; then
    if grep -q '^;externip' /etc/asterisk/sip.conf; then
      sed -i "s/^;externip=.*/externip=${PUBLIC_IP}/" /etc/asterisk/sip.conf || true
    elif ! grep -q '^externip' /etc/asterisk/sip.conf; then
      sed -i "/^\[general\]/a externip=${PUBLIC_IP}" /etc/asterisk/sip.conf || true
    fi
  fi
}

install_crontab_and_boot() {
  header "Phase 8 — Keepalives, crontab, boot"
  mkdir -p /var/log/astguiclient
  local cronf="/var/spool/cron/tabs/root"
  [[ -d /var/spool/cron/tabs ]] || cronf="/var/spool/cron/root"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    touch "$cronf"
    if ! grep -q 'ADMIN_keepalive_ALL.pl' "$cronf"; then
      cat >> "$cronf" <<'CRON'

### VICIdial keepalives and maintenance (installed by install-vicidial12-opensuse.sh)
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl
* * * * * /usr/share/astguiclient/AST_send_action_list.pl
* * * * * /usr/share/astguiclient/AST_VDhopper.pl --debug
1 1 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_LEADS.pl --debug --postal-code-gmt
2 1 * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl --quiet
4 0 * * 0 /usr/share/astguiclient/ADMIN_keep_unused_recordings.pl --debug
CRON
    fi
    chmod 600 "$cronf"
  fi
  local rc="/etc/rc.d/rc.local"
  [[ -f /etc/rc.local ]] && rc="/etc/rc.local"
  mkdir -p "$(dirname "$rc")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    touch "$rc"
    chmod +x "$rc"
    ensure_line "$rc" "#!/bin/bash"
    ensure_line "$rc" "/usr/share/astguiclient/start_asterisk_boot.pl"
  fi
  if have_cmd systemctl; then
    run systemctl enable cron || run systemctl enable cronie || true
    run systemctl restart cron || run systemctl restart cronie || true
  fi
}

configure_firewall() {
  [[ "$SKIP_FIREWALL" -eq 0 ]] || { info "Skipping firewall"; return; }
  header "Phase 9 — Firewall ports"
  if have_cmd firewall-cmd && [[ "$(unit_state firewalld)" == "active" ]]; then
    local p
    for p in 80/tcp 443/tcp 22/tcp 5060/tcp 5060/udp 4569/udp 5038/tcp; do
      run firewall-cmd --permanent --add-port="$p" || true
    done
    run firewall-cmd --permanent --add-port=10000-20000/udp || true
    run firewall-cmd --reload || true
    ok "firewalld ports opened (HTTP/S, SIP, IAX, AMI, RTP 10000-20000)"
    info "Leave 3306 closed to the internet on a single Express box"
  else
    warn "firewalld not active; configure SIP 5060 and RTP 10000-20000 UDP yourself"
  fi
}

configure_mariadb_timestamp_only() {
  write_timestamp_cnf
  if have_cmd systemctl; then
    run systemctl restart mariadb || true
  fi
  ok "Applied MariaDB TIMESTAMP bugfix ([mysqld] explicit_defaults_for_timestamp=Off)"
}

# ---------------------------------------------------------------------------
# Database migration
# ---------------------------------------------------------------------------

SCHEMA_CHAIN=(
  "2.0.5:upgrade_2.0.5.sql:0"
  "2.2:upgrade_2.2.sql:200"
  "2.4:upgrade_2.4.sql:400"
  "2.6:upgrade_2.6.sql:1316"
  "2.8:upgrade_2.8.sql:1381"
  "2.10:upgrade_2.10.sql:1500"
  "2.12:upgrade_2.12.sql:1600"
  "2.14:upgrade_2.14.sql:1478"
)

backup_database() {
  header "Database backup"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  if ! have_cmd mysqldump; then
    die "mysqldump not found"
  fi
  local dump="${BACKUP_DIR}/${DB_NAME}-${STARTED_AT}.sql.gz"
  info "Dumping ${DB_NAME} -> ${dump}"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mysqldump --single-transaction --routines --triggers --events \
      --databases "$DB_NAME" | gzip > "$dump"
    gunzip -t "$dump"
    ok "Backup verified: $dump"
  fi
}

current_schema_version() {
  mysql_exec -e "SELECT db_schema_version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || echo 0
}

apply_upgrade_sql() {
  local file="$1"
  [[ -f "$file" ]] || { warn "Missing $file"; return 1; }
  info "Applying $(basename "$file")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mysql_file -f --database="$DB_NAME" < "$file"
  fi
}

migrate_schema_chain() {
  checkout_vicidial
  local current
  current="$(current_schema_version)"
  current="${current:-0}"
  info "Current db_schema_version=${current}  target>=${REQ_DB_SCHEMA_TARGET}"
  local entry ver file min
  for entry in "${SCHEMA_CHAIN[@]}"; do
    IFS=':' read -r ver file min <<<"$entry"
    local path="${SVN_DIR}/extras/${file}"
    if [[ "$current" -lt "$REQ_DB_SCHEMA_TARGET" ]]; then
      if [[ "$current" -lt "$min" || "$ver" == "2.14" ]]; then
        if [[ -f "$path" ]]; then
          apply_upgrade_sql "$path"
          current="$(current_schema_version)"
          current="${current:-0}"
          info "Schema now ${current} after ${file}"
        else
          warn "Upgrade file not in this SVN tree: ${file}"
        fi
      fi
    fi
  done
  # Always re-run 2.14 extras for incremental schema on already-2.14 systems.
  if [[ -f "${SVN_DIR}/extras/upgrade_2.14.sql" ]]; then
    apply_upgrade_sql "${SVN_DIR}/extras/upgrade_2.14.sql"
  fi
  current="$(current_schema_version)"
  if [[ "${current:-0}" -ge "$REQ_DB_SCHEMA_TARGET" ]]; then
    ok "Database schema ${current} meets target ${REQ_DB_SCHEMA_TARGET}"
  else
    warn "Database schema is ${current:-unknown}; target is ${REQ_DB_SCHEMA_TARGET}. Review extras/*.sql"
  fi
}

import_dump() {
  local dump="$1"
  [[ -f "$dump" ]] || die "Dump not found: $dump"
  header "Import dump ${dump}"
  mysql_file -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;"
  if [[ "$dump" == *.gz ]]; then
    gzip -dc "$dump" | mysql_file --database="$DB_NAME"
  else
    mysql_file --database="$DB_NAME" < "$dump"
  fi
  ok "Dump imported into ${DB_NAME}"
}

cmd_migrate() {
  need_root
  phase_detect
  if [[ "$FAIL_COUNT" -gt 0 && "$FORCE" -eq 0 ]]; then
    die "Fix requirement FAILs or pass --force before migrating"
  fi
  confirm "Backup and migrate database ${DB_NAME}?" || die "Aborted"
  backup_database
  if [[ -n "$FROM_HOST" ]]; then
    local remote="${BACKUP_DIR}/remote-${STARTED_AT}.sql.gz"
    info "Dumping remote ${FROM_HOST}:${DB_NAME}"
    mysqldump -h "$FROM_HOST" -u "$DB_USER" -p"$DB_PASS" --single-transaction \
      --routines --triggers "$DB_NAME" | gzip > "$remote"
    DUMP_PATH="$remote"
  fi
  if [[ -n "$DUMP_PATH" ]]; then
    import_dump "$DUMP_PATH"
  fi
  configure_mariadb_timestamp_only
  migrate_schema_chain
  ok "Migration complete. Rebuild Asterisk conf from Admin → Servers (Rebuild conf files = Y)."
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

cmd_verify_soft() {
  header "Post-install verification"
  detect_php; detect_asterisk; detect_mariadb
  [[ -n "$PHP_VERSION" ]] && ok "PHP $PHP_VERSION" || warn "PHP missing"
  [[ -n "$ASTERISK_VERSION" ]] && ok "Asterisk $ASTERISK_VERSION" || warn "Asterisk missing"
  [[ -n "$MARIADB_VERSION" ]] && ok "MariaDB $MARIADB_VERSION" || warn "MariaDB missing"
  if have_cmd screen; then
    screen -ls || info "No screen sessions yet (normal before first reboot / keepalive)"
  fi
  if have_cmd apachectl || have_cmd apache2ctl; then
    (apachectl configtest || apache2ctl configtest) 2>&1 | tee -a "$LOG_FILE" || true
  fi
  if [[ -d "${WWW_ROOT}/vicidial" ]]; then
    ok "Web files in ${WWW_ROOT}/vicidial"
  elif [[ -d /var/www/html/vicidial ]]; then
    ok "Web files in /var/www/html/vicidial"
  else
    warn "VICIdial web directory not found"
  fi
  info "Admin UI: http://${SERVER_IP:-$(detect_primary_ip)}/vicidial/welcome.php"
  info "Default login 6666 / 1234 — change immediately"
  info "Credentials file: ${CRED_FILE}"
}

# ---------------------------------------------------------------------------
# Install orchestration
# ---------------------------------------------------------------------------

assert_can_install() {
  if [[ "$FAIL_COUNT" -gt 0 && "$FORCE" -eq 0 ]]; then
    die "Requirements have FAIL items. Fix them, or re-run with --force (not recommended)."
  fi
  if [[ "$OS_ID" != "opensuse-leap" && "$OS_ID" != "opensuse" && "$IS_VICIBOX" -ne 1 ]]; then
    die "This installer targets OpenSUSE Leap / ViciBox. Detected: ${OS_NAME}"
  fi
}

cmd_install() {
  need_root
  phase_detect
  if [[ -n "$ISO_PATH" ]]; then
    die "ISO install is disabled. Use scratch install: $SCRIPT_NAME install --role express --yes --stop-conflicts"
  fi
  assert_can_install
  resolve_conflicts
  if [[ "$IS_VICIBOX" -eq 1 ]]; then
    warn "ViciBox tools are present, but ISO/vicibox-express is skipped. Installing from packages + source."
  fi
  confirm "Install VICIdial 12 scratch stack (${ROLE}) on $(host_name)? (no ISO)" || die "Aborted"

  ensure_opensuse_repos
  case "$ROLE" in
    express|all)
      install_base_packages
      install_php
      configure_mariadb
      install_dahdi
      install_asterisk
      checkout_vicidial
      load_schema_if_empty
      migrate_schema_chain
      run_install_pl
      install_crontab_and_boot
      configure_firewall
      write_credentials
      ;;
    database)
      install_base_packages
      configure_mariadb
      checkout_vicidial
      load_schema_if_empty
      migrate_schema_chain
      write_credentials
      ;;
    web)
      install_base_packages
      install_php
      checkout_vicidial
      run_install_pl
      write_credentials
      configure_firewall
      ;;
    telephony)
      install_base_packages
      install_dahdi
      install_asterisk
      checkout_vicidial
      run_install_pl
      install_crontab_and_boot
      configure_firewall
      write_credentials
      ;;
    archive)
      install_base_packages
      zypper_n in -y vsftpd || true
      run systemctl enable --now vsftpd || true
      ;;
  esac
  cmd_verify_soft
  info "Reboot recommended. After reboot: screen -ls should show keepalive sockets."
}

cmd_detect() {
  mkdir -p "$LOG_DIR"
  phase_detect
}

cmd_check() {
  mkdir -p "$LOG_DIR"
  phase_detect
  echo
  printf '  %-22s %-28s %-28s %s\n' "COMPONENT" "FOUND" "REQUIRED" "STATUS"
  printf '  %-22s %-28s %-28s %s\n' "---------" "-----" "--------" "------"
  local row st comp found req detail
  for row in "${REQ_ROWS[@]}"; do
    IFS='|' read -r st comp found req detail <<<"$row"
    printf '  %-22s %-28s %-28s %s\n' "$comp" "$found" "$req" "$st"
  done
  echo
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    fail "Host is NOT ready for VICIdial 12 without fixes (${FAIL_COUNT} FAIL)"
    return 1
  fi
  ok "Host meets or can be upgraded to the ViciBox 12 profile (${WARN_COUNT} warnings)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

init_paths() {
  if [[ "${EUID}" -ne 0 ]]; then
    LOG_DIR="${HOME}/.vicidial-installer-logs"
    LOG_FILE="${LOG_DIR}/install-${STARTED_AT}.log"
    REPORT_FILE="${LOG_DIR}/detect-${STARTED_AT}.txt"
    if [[ "$COMMAND" != "help" && "$COMMAND" != "detect" && "$COMMAND" != "check" ]]; then
      die "This command must run as root."
    fi
  fi
  mkdir -p "$LOG_DIR"
}

main() {
  parse_args "$@"
  init_paths
  case "$COMMAND" in
    help) usage ;;
    detect) cmd_detect ;;
    check) cmd_check ;;
    install) cmd_install ;;
    migrate) cmd_migrate ;;
    iso-verify|download-iso|write-usb)
      die "ISO install is disabled. On Hetzner: install OpenSUSE Leap 15.6, then $SCRIPT_NAME install --role express --yes --stop-conflicts"
      ;;
    *) die "Unknown command: $COMMAND (try: $SCRIPT_NAME help)" ;;
  esac
}

main "$@"
