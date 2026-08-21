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
#   ./install-vicidial12-opensuse.sh setup --yes
#   ./install-vicidial12-opensuse.sh install --role express --yes --stop-conflicts
#   ./install-vicidial12-opensuse.sh migrate --dump /path/asterisk.sql.gz
#
# Run as root on the target OpenSUSE server. Never use `zypper dup`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="1.4.1"
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
# Asterisk 18 is EOL — asterisk-18-current.tar.gz 404s; use last 18.x in old-releases.
ASTERISK_SRC_URL="${ASTERISK_SRC_URL:-https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-18.26.4.tar.gz}"
DAHDI_SRC_URL="${DAHDI_SRC_URL:-https://downloads.asterisk.org/pub/telephony/dahdi-linux-complete/dahdi-linux-complete-current.tar.gz}"
LIBPRI_SRC_URL="${LIBPRI_SRC_URL:-https://downloads.asterisk.org/pub/telephony/libpri/libpri-1-current.tar.gz}"

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
  setup          Enable/start required services (Apache, MariaDB, Asterisk, portal IP sync)
  install        Scratch install: box → Apache/PHP → MariaDB → DAHDI → Asterisk → VICIdial
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

  # After Asterisk is built (or on a re-run): create unit, enable chan_sip, start telephony
  $SCRIPT_NAME setup --yes

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
  * Required services (Apache, MariaDB, Asterisk, chronyd) are checked first: if missing
    they are installed, enabled, started, and verified (same pattern as the DB).
  * Use 'setup' to enable/start Asterisk (systemd unit + chan_sip) without rebuilding.
  * Use 'zypper up' only. Never 'zypper dup' on a ViciDial box.
  * After a new MariaDB 10.11+ database: explicit_defaults_for_timestamp=Off and
    sql_mode=NO_ENGINE_SUBSTITUTION (avoids blank admin pages on agent/phone save).
  * Default web login after a fresh install is 6666 / 1234 — change it immediately.
  * Demo agent login: 8001 / 8001 with phone 8001 / 8001 (also 6001, 7001); campaign DEMOCAMP.
  * Demo USA leads: list 1001 on DEMOCAMP (phone_code=1, country USA, 555-01xx fiction numbers).

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
  local unit="$1" s=""
  if have_cmd systemctl; then
    s="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    s="$(printf '%s' "$s" | tr -d '\r' | awk 'NF{print; exit}')"
  fi
  printf '%s' "${s:-disabled}"
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
  # ss column layout varies: with -tu the local address is not always $4.
  # Match a field that ends in :PORT so *:80, 0.0.0.0:80, and [::]:80 all count.
  # Do not use ":80" as a substring — that false-matches :8080.
  # Prefer plain ss -lntH parsing first: some Leap 16 ss builds accept
  # "sport = :80" but still return empty while *:80 is listening.
  if have_cmd ss; then
    if ss -lntuH 2>/dev/null | awk -v port="$port" -v proto="$proto" '
      {
        if (proto == "tcp" && $1 !~ /^tcp/) next
        if (proto == "udp" && $1 !~ /^udp/) next
        for (i = 1; i <= NF; i++) {
          if ($i ~ (":" port "$")) { found = 1; exit }
        }
      }
      END { exit found ? 0 : 1 }'
    then
      return 0
    fi
    if [[ "$proto" == "tcp" || "$proto" == "any" ]]; then
      ss -H -l -n -t "sport = :${port}" 2>/dev/null | grep -q LISTEN && return 0
    fi
    if [[ "$proto" == "udp" || "$proto" == "any" ]]; then
      ss -H -l -n -u "sport = :${port}" 2>/dev/null | grep -q LISTEN && return 0
    fi
    return 1
  elif have_cmd netstat; then
    netstat -lntu 2>/dev/null | awk -v port="$port" '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ (":" port "$")) found = 1
        }
      }
      END { exit found ? 0 : 1 }'
  else
    return 1
  fi
}

unit_exists() {
  local unit="$1"
  have_cmd systemctl || return 1
  systemctl cat "${unit}.service" >/dev/null 2>&1
}

wait_for_unit_active() {
  local unit="$1" timeout="${2:-30}" i=0
  while [[ "$i" -lt "$timeout" ]]; do
    if [[ "$(unit_state "$unit")" == "active" ]]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_for_listen() {
  local port="$1" timeout="${2:-20}" i=0
  while [[ "$i" -lt "$timeout" ]]; do
    if listening_on "$port" any; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

apache_unit_name() {
  if unit_exists apache2; then
    printf '%s' apache2
  elif unit_exists httpd; then
    printf '%s' httpd
  else
    printf '%s' apache2
  fi
}

db_unit_name() {
  if unit_exists mariadb; then
    printf '%s' mariadb
  elif unit_exists mysql; then
    printf '%s' mysql
  elif unit_exists mysqld; then
    printf '%s' mysqld
  else
    printf '%s' mariadb
  fi
}

ensure_unit() {
  local unit="$1" timeout="${2:-30}"
  have_cmd systemctl || { warn "systemctl not found; cannot start ${unit}"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "(dry-run) would systemctl enable --now ${unit}"
    return 0
  fi
  run systemctl enable "$unit" || warn "Could not enable ${unit} at boot"
  if [[ "$(unit_state "$unit")" == "active" ]]; then
    run systemctl reload-or-restart "$unit" || run systemctl restart "$unit" || true
  else
    run systemctl start "$unit" || run systemctl restart "$unit" || true
  fi
  if wait_for_unit_active "$unit" "$timeout"; then
    ok "${unit} is active (enabled=$(unit_enabled "$unit"))"
    return 0
  fi
  fail "${unit} did not become active (state=$(unit_state "$unit"))"
  systemctl status "$unit" --no-pager -l 2>/dev/null | tail -n 25 | tee -a "$LOG_FILE" || true
  journalctl -u "$unit" -n 30 --no-pager 2>/dev/null | tee -a "$LOG_FILE" || true
  return 1
}

wait_for_mariadb_ping() {
  local timeout="${1:-45}" i=0
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  while [[ "$i" -lt "$timeout" ]]; do
    if have_cmd mysqladmin && mysqladmin ping --silent >/dev/null 2>&1; then
      return 0
    fi
    if have_cmd mariadb-admin && mariadb-admin ping --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
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
  # Prefer /root/.my.cnf when DB_ROOT_PASS is unset. Never invent a -p that
  # overrides a working .my.cnf — that silently kills re-runs after Phase 4.
  local extra=()
  if [[ -n "${DB_ROOT_PASS}" ]]; then
    extra+=(-p"${DB_ROOT_PASS}")
  fi
  "$(mysql_cli)" -u root "${extra[@]}" "$@"
}

load_root_my_cnf_pass() {
  # Populate DB_ROOT_PASS from an existing installer .my.cnf (mode 0600).
  [[ -n "${DB_ROOT_PASS}" ]] && return 0
  [[ -f /root/.my.cnf ]] || return 1
  local p=""
  p="$(awk -F= '/^[[:space:]]*password=/{sub(/^[[:space:]]*password=/,""); print; exit}' /root/.my.cnf 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  DB_ROOT_PASS="$p"
  return 0
}

trap_err() {
  local ec=$? line="${1:-?}" cmd="${2:-}"
  log "${C_RED}[FATAL]${C_RST} Command failed (exit ${ec}) at line ${line}: ${cmd}"
  exit "$ec"
}

write_timestamp_cnf() {
  mkdir -p /etc/my.cnf.d
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  # Leap 16 / MariaDB 11 requires a [mysqld] group.
  cat > /etc/my.cnf.d/general.cnf <<'CNF'
[mysqld]
explicit_defaults_for_timestamp = Off
sql_mode = NO_ENGINE_SUBSTITUTION
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
APACHE_PKG="not installed"; APACHE_UNIT="apache2"; APACHE_VERSION=""
APACHE_ACTIVE="unknown"; APACHE_ENABLED="unknown"
APACHE_LISTEN80="no"; APACHE_LISTEN443="no"  # 443 tracked only; installer never enables HTTPS/SSL
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
  if have_cmd mysqladmin && mysqladmin ping --silent >/dev/null 2>&1; then
    DB_SCHEMA="$(mysql_exec -e "SELECT db_schema_version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || true)"
    DB_CODE_VERSION="$(mysql_exec -e "SELECT version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || true)"
  elif have_cmd mariadb-admin && mariadb-admin ping --silent >/dev/null 2>&1; then
    DB_SCHEMA="$(mysql_exec -e "SELECT db_schema_version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || true)"
    DB_CODE_VERSION="$(mysql_exec -e "SELECT version FROM ${DB_NAME}.system_settings LIMIT 1;" 2>/dev/null || true)"
  fi
}

detect_apache() {
  APACHE_UNIT="$(apache_unit_name)"
  APACHE_ACTIVE="$(unit_state "$APACHE_UNIT")"
  APACHE_ENABLED="$(unit_enabled "$APACHE_UNIT")"
  APACHE_LISTEN80="no"
  APACHE_LISTEN443="no"
  APACHE_PKG="not installed"
  APACHE_VERSION=""
  if pkg_installed apache2; then
    APACHE_PKG="apache2"
  elif pkg_installed httpd; then
    APACHE_PKG="httpd"
  fi
  local ver_out=""
  if have_cmd httpd; then
    ver_out="$(httpd -v 2>/dev/null || true)"
  elif have_cmd apache2ctl; then
    ver_out="$(apache2ctl -v 2>/dev/null || true)"
  elif have_cmd apachectl; then
    ver_out="$(apachectl -v 2>/dev/null || true)"
  elif have_cmd apache2; then
    ver_out="$(apache2 -v 2>/dev/null || true)"
  fi
  if [[ -n "$ver_out" ]]; then
    APACHE_VERSION="$(printf '%s\n' "$ver_out" | awk -F'/' '/Server version/{print $2; exit}' | awk '{print $1}')"
  fi
  listening_on 80 any && APACHE_LISTEN80="yes"
  listening_on 443 any && APACHE_LISTEN443="yes"
  if [[ "$APACHE_PKG" == "not installed" && -n "$APACHE_VERSION" ]]; then
    APACHE_PKG="present"
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
  "apache2|apache2|80|required-web|VICIdial web UI (HTTP only — no SSL)"
  "httpd|apache2|80|required-web|Apache alias"
  "nginx|nginx|80|conflict-web|Conflicts with Apache on :80"
  "lighttpd|lighttpd|80|conflict-web|Conflicts with Apache"
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
            # Leap 16: mysql/mysqld are MariaDB aliases or share :3306 with mariadb.
            # Do not treat our own MariaDB listener as Oracle MySQL.
            if [[ "$name" == mysql || "$name" == mysqld ]]; then
              local real_id=""
              real_id="$(systemctl show -p Id --value "${name}.service" 2>/dev/null || true)"
              if [[ "$real_id" == "mariadb.service" || "$(unit_state mariadb)" == "active" ]]; then
                continue
              fi
            fi
            CONFLICT_ROWS+=("$name|$level|$notes")
            CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
          fi
          ;;
      esac
    fi
  done

  # Always list required stack units, even when the package is not installed yet.
  local req_name already row
  for req_name in apache2 mariadb asterisk chronyd; do
    already=0
    for row in "${SERVICE_ROWS[@]+"${SERVICE_ROWS[@]}"}"; do
      if [[ "${row%%|*}" == "$req_name" ]]; then
        already=1
        break
      fi
    done
    [[ "$already" -eq 1 ]] && continue
    for entry in "${SERVICE_CATALOG[@]}"; do
      IFS='|' read -r name pkg ports level notes <<<"$entry"
      if [[ "$name" == "$req_name" ]]; then
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
        SERVICE_ROWS+=("$name|$(unit_state "$name")|$(unit_enabled "$name")|$listening|$level|$notes")
        break
      fi
    done
  done

  # Catch anything else bound to VICIdial ports.
  local port
  for port in 80 3306 5038 5060 4569; do
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

  # Apache — missing is installable; installer enables and starts it like MariaDB.
  local ap_ok="WARN" ap_found
  ap_found="pkg=${APACHE_PKG} unit=${APACHE_UNIT} ${APACHE_ACTIVE} :80=${APACHE_LISTEN80}"
  if [[ "$APACHE_ACTIVE" == "active" && "$APACHE_LISTEN80" == "yes" ]]; then
    ap_ok="PASS"
  elif [[ "$APACHE_PKG" != "not installed" || -n "$APACHE_VERSION" ]]; then
    ap_ok="WARN"
  else
    APACHE_PKG="not installed"
    ap_ok="WARN"
    ap_found="not installed"
  fi
  add_req "$ap_ok" "Apache" "${APACHE_VERSION:-$ap_found}" "apache2 enabled + listening :80" "Missing Apache is installed, enabled, started, and verified automatically (same as MariaDB)."

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
  add_req "$db_ok" "MariaDB" "$MARIADB_VERSION" "${REQ_MARIADB_MIN}+" "TIMESTAMP implicit ON UPDATE broke in 10.11. Missing MariaDB is installed, enabled, started, and ping-checked automatically."

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

role_needs_service() {
  local name="$1"
  case "$ROLE" in
    express|all)
      case "$name" in apache2|mariadb|asterisk|chronyd) return 0 ;; *) return 1 ;; esac
      ;;
    web)
      case "$name" in apache2|chronyd) return 0 ;; *) return 1 ;; esac
      ;;
    database)
      case "$name" in mariadb|chronyd) return 0 ;; *) return 1 ;; esac
      ;;
    telephony)
      case "$name" in asterisk|dahdi|chronyd) return 0 ;; *) return 1 ;; esac
      ;;
    archive)
      case "$name" in vsftpd|chronyd) return 0 ;; *) return 1 ;; esac
      ;;
    *)
      return 0
      ;;
  esac
}

plan_required_service() {
  local name="$1" pkg="$2" unit="$3" port="$4" note="$5"
  local installed="no" active enabled listen="-" action needed="yes"
  case "$name" in
    apache2)
      unit="${APACHE_UNIT:-$unit}"
      if pkg_installed apache2 || pkg_installed httpd || [[ -n "${APACHE_VERSION}" ]]; then
        installed="yes"
      fi
      ;;
    mariadb)
      unit="$(db_unit_name)"
      if pkg_installed mariadb || have_cmd mysql || have_cmd mariadb; then
        installed="yes"
      fi
      ;;
    asterisk)
      if pkg_installed asterisk || have_cmd asterisk; then
        installed="yes"
      fi
      ;;
    chronyd)
      if pkg_installed chrony || have_cmd chronyd; then
        installed="yes"
      fi
      ;;
    *)
      if pkg_installed "$pkg" || have_cmd "$name"; then
        installed="yes"
      fi
      ;;
  esac
  active="$(unit_state "$unit")"
  enabled="$(unit_enabled "$unit")"
  if [[ -n "$port" ]]; then
    listen="no"
    listening_on "$port" any && listen="yes"
  fi
  if ! role_needs_service "$name"; then
    needed="no"
    action="skip (not required for --role ${ROLE})"
  elif [[ "$installed" == "no" ]]; then
    action="NEED INSTALL + ENABLE + START"
  elif [[ "$active" != "active" ]]; then
    action="NEED ENABLE + START"
  elif [[ -n "$port" && "$listen" != "yes" ]]; then
    action="NEED START (port ${port} not listening)"
  else
    action="OK (running)"
  fi
  ACTION_ROWS+=("$name|$installed|$active|$enabled|$listen|$action")
  printf '  %-12s %-12s %-10s %-12s %-8s %s\n' "$name" "$installed" "$active" "$enabled" "$listen" "$action"
  : "${note}"
}

print_required_services() {
  ACTION_ROWS=()
  header "Required services — check, install, enable, start"
  info "Role ${ROLE}: missing units are installed and started the same way as MariaDB."
  printf '  %-12s %-12s %-10s %-12s %-8s %s\n' "SERVICE" "INSTALLED" "ACTIVE" "ENABLED" "LISTEN" "ACTION"
  printf '  %-12s %-12s %-10s %-12s %-8s %s\n' "-------" "---------" "------" "-------" "------" "------"
  plan_required_service apache2 apache2 apache2 80 "VICIdial web UI (Apache + mod_php)"
  plan_required_service mariadb mariadb mariadb 3306 "VICIdial database"
  plan_required_service asterisk asterisk asterisk 5060 "Telephony engine (started by VICIdial keepalive after install)"
  plan_required_service chronyd chrony chronyd "" "Time sync (client; may not listen on UDP 123)"
  echo
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
  Apache          : ${APACHE_VERSION:-none}  (${APACHE_PKG}, unit=${APACHE_UNIT}, ${APACHE_ACTIVE}, enabled=${APACHE_ENABLED}, :80=${APACHE_LISTEN80})
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
    echo "Apache: pkg=${APACHE_PKG} unit=${APACHE_UNIT} active=${APACHE_ACTIVE} enabled=${APACHE_ENABLED} :80=${APACHE_LISTEN80} version=${APACHE_VERSION:-none}"
    echo "MariaDB: ${MARIADB_VERSION:-none}  Asterisk: ${ASTERISK_VERSION:-none}  PHP: ${PHP_VERSION:-none}"
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
  detect_apache
  detect_asterisk
  detect_mariadb
  detect_security
  detect_services
  print_detect_summary
  print_service_table
  print_required_services
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
  # Leap 16 zypper does not accept global --no-confirm. Use --non-interactive
  # and pass -y on install/remove subcommands.
  run zypper --non-interactive --gpg-auto-import-keys "$@"
}

zypper_try_in() {
  local p rc=0
  for p in "$@"; do
    if pkg_installed "$p"; then
      continue
    fi
    if zypper --non-interactive --gpg-auto-import-keys in -y "$p" >/dev/null 2>&1; then
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

ensure_apache() {
  header "Apache HTTP server — check, install, enable, start"
  if pkg_installed apache2 || have_cmd apache2ctl || have_cmd apachectl || have_cmd httpd; then
    ok "Apache package already present"
  else
    info "Apache not installed — installing apache2 apache2-mod_php8 apache2-utils"
    zypper_n in -y apache2 apache2-mod_php8 apache2-utils || \
      zypper_try_in apache2 apache2-mod_php8 apache2-utils || \
      die "Apache install failed. On Leap 16 try: zypper se apache2"
  fi
  if have_cmd a2enmod; then
    run a2enmod php8 || run a2enmod php || true
    run a2enmod rewrite || true
  fi
  mkdir -p "$WWW_ROOT"
  local unit
  unit="$(apache_unit_name)"
  if ! ensure_unit "$unit" 25; then
    fail "Could not start Apache (${unit})"
    [[ "$FORCE" -eq 1 ]] || die "Apache did not start. Stop nginx/lighttpd with --stop-conflicts, then: systemctl status ${unit}"
  fi
  # httpd.service is a Leap 16 alias of apache2 — do not systemctl enable the link.
  if wait_for_listen 80 15; then
    ok "Apache is listening on TCP 80"
  elif have_cmd curl && curl -sI -m 5 http://127.0.0.1/ >/dev/null 2>&1; then
    ok "Apache answers on http://127.0.0.1/"
  else
    fail "Apache unit is up but TCP 80 is not listening"
    ss -lntH 2>/dev/null | tee -a "$LOG_FILE" || true
    [[ "$FORCE" -eq 1 ]] || die "Apache did not bind port 80. Resolve the port conflict, then re-run."
  fi
  if have_cmd apachectl; then
    apachectl configtest 2>&1 | tee -a "$LOG_FILE" || true
  elif have_cmd apache2ctl; then
    apache2ctl configtest 2>&1 | tee -a "$LOG_FILE" || true
  fi
  detect_apache
  ok "Apache ${APACHE_VERSION:-installed} (${unit} ${APACHE_ACTIVE}, enabled=${APACHE_ENABLED})"
}

ensure_mariadb_running() {
  local unit
  unit="$(db_unit_name)"
  header "MariaDB — enable, start, ping"
  if ! pkg_installed mariadb && ! have_cmd mysql && ! have_cmd mariadb; then
    die "MariaDB is not installed"
  fi
  if ! ensure_unit "$unit" 40; then
    fail "Could not start MariaDB (${unit})"
    [[ "$FORCE" -eq 1 ]] || die "MariaDB did not start. Check: systemctl status ${unit}  and /etc/my.cnf.d/*.cnf"
  fi
  if wait_for_mariadb_ping 45; then
    ok "MariaDB accepts connections (mysqladmin ping)"
  else
    fail "MariaDB is active but not accepting connections yet"
    [[ "$FORCE" -eq 1 ]] || die "MariaDB ping failed. If you see 'option without preceding group', /etc/my.cnf.d/general.cnf needs a [mysqld] header."
  fi
  detect_mariadb
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

  # Leap 16 renames: jansson-devel→libjansson-devel, openssl-devel→libopenssl-devel
  # sqlite3-devel is ONLY for Asterisk astdb (internal). VICIdial app data is MariaDB.
  local devel=(
    ncurses-devel libxml2-devel openssl-devel libopenssl-devel libopenssl-3-devel
    libuuid-devel speex-devel libcurl-devel libedit-devel sqlite3-devel
    unixODBC-devel kernel-devel kernel-default-devel
    libsrtp-devel jansson-devel libjansson-devel newt-devel speexdsp-devel
  )
  zypper_try_in "${devel[@]}" || true

  # perl-Time-HiRes is core on Leap 16; nmap/sipsak are often absent from oss.
  local perlmods=(
    perl-DBI perl-DBD-mysql perl-DBD-MariaDB perl-Net-Telnet perl-Time-HiRes
    perl-IO-Socket-SSL perl-libwww-perl perl-Digest-MD5
    perl-YAML perl-JSON perl-Try-Tiny perl-Mail-Sendmail hostname
    lame mpg123 pv nmap sipsak
  )
  zypper_try_in "${perlmods[@]}" || true

  if have_cmd systemctl; then
    ensure_unit chronyd 15 || warn "Could not enable chronyd"
  fi
}

install_php() {
  header "Phase 3 — PHP ${REQ_PHP_MIN} + Apache (web)"
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
    run a2enmod php8 || run a2enmod php || true
    run a2enmod rewrite || true
  fi
  # OpenSUSE Apache default document root is /srv/www/htdocs
  mkdir -p "$WWW_ROOT"
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
# VICIdial admin POSTs empty strings for int fields; STRICT_TRANS_TABLES
# on MariaDB 10.11+ fatals and shows a blank page (e.g. agent update).
sql_mode = NO_ENGINE_SUBSTITUTION
character-set-server = utf8
collation-server = utf8_unicode_ci
CNF
    info "MariaDB innodb_buffer_pool_size=${innodb_pool} (RAM ${RAM_MB} MB)"
  fi
  write_timestamp_cnf
  ensure_mariadb_running
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mysql_file -e "SET GLOBAL sql_mode='NO_ENGINE_SUBSTITUTION';" || true
  fi
  ok "MariaDB ${MARIADB_VERSION:-installed}; TIMESTAMP + sql_mode tuned for VICIdial"

  local set_new_root=0
  if [[ "$LEGACY_PASSWORDS" -eq 1 ]]; then
    DB_PASS="${DB_PASS:-1234}"
    DB_CUSTOM_PASS="${DB_CUSTOM_PASS:-custom1234}"
  else
    DB_PASS="${DB_PASS:-$(rand_pass)}"
    DB_CUSTOM_PASS="${DB_CUSTOM_PASS:-$(rand_pass)}"
  fi
  # On re-run: reuse /root/.my.cnf. Generating a fresh -p here overrides .my.cnf
  # and aborts the install right after the MariaDB PASS line.
  if [[ -z "$DB_ROOT_PASS" && "$LEGACY_PASSWORDS" -eq 0 ]]; then
    if load_root_my_cnf_pass; then
      info "Reusing MariaDB root password from /root/.my.cnf (re-run safe)"
    else
      DB_ROOT_PASS="$(rand_pass)"
      set_new_root=1
    fi
  elif [[ -n "$DB_ROOT_PASS" && ! -f /root/.my.cnf ]]; then
    set_new_root=1
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    # ALTER USER so re-runs update passwords to match the credentials file.
    mysql_file <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_CUSTOM_USER}'@'localhost' IDENTIFIED BY '${DB_CUSTOM_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_CUSTOM_USER}'@'localhost' IDENTIFIED BY '${DB_CUSTOM_PASS}';
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_CUSTOM_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    if [[ "$set_new_root" -eq 1 && -n "$DB_ROOT_PASS" ]]; then
      # Connect without -p first (socket auth / empty root), then set password.
      DB_ROOT_PASS_TMP="$DB_ROOT_PASS"
      DB_ROOT_PASS=""
      mysql_file -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS_TMP}'; FLUSH PRIVILEGES;" || \
        warn "Could not set MariaDB root password automatically"
      DB_ROOT_PASS="$DB_ROOT_PASS_TMP"
      unset DB_ROOT_PASS_TMP
      umask 077
      cat > /root/.my.cnf <<EOF
[client]
user=root
password=${DB_ROOT_PASS}
EOF
      chmod 600 /root/.my.cnf
    fi
    ok "Database ${DB_NAME} and app users ready"
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
# Agent UI: http://SERVER_IP/agc/vicidial.php
AGENT_USER=8001
AGENT_PASS=8001
PHONE_LOGIN=8001
PHONE_PASS=8001
# Also created: agent/phone 6001/6001 and 7001/7001
DEMO_CAMPAIGN=DEMOCAMP
EOF
  chmod 600 "$CRED_FILE"
  ok "Credentials written to ${CRED_FILE}"
}

# Demo agent users + SIP phones so /agc/vicidial.php works out of the box.
# Classic lab IDs: 8001 (primary), 6001, 7001 — user/pass/phone_login all match.
ensure_demo_agent_phones() {
  header "Demo agent users + phones (8001 / 6001 / 7001)"
  [[ "$DRY_RUN" -eq 1 ]] && { info "(dry-run) would ensure demo agents/phones"; return 0; }
  local tables sip
  tables="$(mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='phones';" 2>/dev/null || echo 0)"
  if [[ "${tables:-0}" -lt 1 ]]; then
    warn "phones table missing — skip demo agents"
    return 0
  fi

  SERVER_IP="${SERVER_IP:-$(detect_primary_ip)}"
  [[ -n "$SERVER_IP" ]] || { warn "No SERVER_IP — skip demo agents"; return 0; }
  local gmt
  gmt="$(mysql_exec -N -e "SELECT local_gmt FROM ${DB_NAME}.servers WHERE server_ip='${SERVER_IP}' LIMIT 1;" 2>/dev/null || true)"
  gmt="${gmt:--5.00}"

  mysql_file --database="$DB_NAME" <<SQL
INSERT INTO vicidial_user_groups (
  user_group, group_name, allowed_campaigns, forced_timeclock_login, shift_enforcement,
  agent_status_viewable_groups, allowed_reports, admin_viewable_groups,
  agent_ip_list, admin_ip_list, api_ip_list
) SELECT 'AGENTS', 'Demo Agents', ' -ALL-CAMPAIGNS- - -', 'N', 'OFF',
  ' --ALL-GROUPS-- ', 'ALL REPORTS', ' ---ALL--- ', '', '', ''
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_user_groups WHERE user_group='AGENTS');

UPDATE vicidial_user_groups SET
  allowed_campaigns=' -ALL-CAMPAIGNS- - -',
  agent_ip_list='',
  forced_timeclock_login='N',
  shift_enforcement='OFF'
WHERE user_group='AGENTS';

INSERT INTO vicidial_campaigns (
  campaign_id, campaign_name, active, dial_method, auto_dial_level,
  dial_timeout, campaign_cid, campaign_vdad_exten, local_call_time, campaign_recording,
  hopper_level, lead_order, dial_statuses, no_hopper_leads_logins, no_hopper_dialing
) SELECT 'DEMOCAMP', 'Demo Campaign', 'Y', 'MANUAL', '0',
  '60', '0000000000', '8368', '24hours', 'ONDEMAND',
  100, 'DOWN', ' NEW -', 'Y', 'Y'
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_campaigns WHERE campaign_id='DEMOCAMP');

UPDATE vicidial_campaigns SET
  active='Y', dial_method='MANUAL', auto_dial_level='0', hopper_level=100,
  lead_order=IFNULL(NULLIF(lead_order,''),'DOWN'), dial_statuses=' NEW -',
  local_call_time='24hours', no_hopper_leads_logins='Y', no_hopper_dialing='Y'
WHERE campaign_id='DEMOCAMP';

INSERT INTO vicidial_lists (list_id, list_name, campaign_id, active, list_description)
SELECT 1001, 'USA Demo Leads', 'DEMOCAMP', 'Y', 'Installer demo — USA phone_code=1 only'
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_lists WHERE list_id=1001);

UPDATE vicidial_lists SET
  list_name='USA Demo Leads', campaign_id='DEMOCAMP', active='Y',
  list_description='Installer demo — USA phone_code=1 only'
WHERE list_id=1001;
SQL

  # USA-only demo leads (NANP fiction 555-01xx). Idempotent via source_id=USA-DEMO.
  local usa_count
  usa_count="$(mysql_exec -N -e "SELECT COUNT(*) FROM ${DB_NAME}.vicidial_list WHERE list_id=1001 AND source_id='USA-DEMO';" 2>/dev/null || echo 0)"
  if [[ "${usa_count:-0}" -lt 1 ]]; then
    mysql_file --database="$DB_NAME" <<'SQL'
INSERT INTO vicidial_list (
  entry_date, status, user, vendor_lead_code, source_id, list_id, gmt_offset_now,
  called_since_last_reset, phone_code, phone_number, title, first_name, middle_initial, last_name,
  address1, city, state, postal_code, country_code, gender, email, comments, called_count, rank, owner, entry_list_id
) VALUES
(NOW(),'NEW','','USA001','USA-DEMO',1001,-5.00,'N','1','2125550101','MR','James','A','Wilson','100 Broadway','New York','NY','10005','USA','M','james.wilson@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA002','USA-DEMO',1001,-5.00,'N','1','2125550102','MS','Emily','B','Johnson','200 Park Ave','New York','NY','10166','USA','F','emily.johnson@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA003','USA-DEMO',1001,-8.00,'N','1','3105550103','MR','Michael','C','Brown','3400 Ocean Ave','Los Angeles','CA','90291','USA','M','michael.brown@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA004','USA-DEMO',1001,-8.00,'N','1','4155550104','MS','Sarah','D','Davis','500 Market St','San Francisco','CA','94105','USA','F','sarah.davis@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA005','USA-DEMO',1001,-6.00,'N','1','3125550105','MR','Robert','E','Miller','233 S Wacker Dr','Chicago','IL','60606','USA','M','robert.miller@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA006','USA-DEMO',1001,-6.00,'N','1','2145550106','MS','Amanda','F','Garcia','1201 Elm St','Dallas','TX','75270','USA','F','amanda.garcia@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA007','USA-DEMO',1001,-6.00,'N','1','7135550107','MR','David','G','Martinez','910 Louisiana St','Houston','TX','77002','USA','M','david.martinez@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA008','USA-DEMO',1001,-5.00,'N','1','3055550108','MS','Jessica','H','Rodriguez','100 Biscayne Blvd','Miami','FL','33132','USA','F','jessica.rodriguez@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA009','USA-DEMO',1001,-5.00,'N','1','4045550109','MR','Christopher','I','Lee','1 Atlantic Station','Atlanta','GA','30363','USA','M','chris.lee@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA010','USA-DEMO',1001,-5.00,'N','1','6175550110','MS','Ashley','J','Walker','1 Federal St','Boston','MA','02110','USA','F','ashley.walker@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA011','USA-DEMO',1001,-5.00,'N','1','2025550111','MR','Daniel','K','Hall','1600 Pennsylvania Ave','Washington','DC','20500','USA','M','daniel.hall@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA012','USA-DEMO',1001,-7.00,'N','1','6025550112','MS','Lauren','L','Allen','2 N Central Ave','Phoenix','AZ','85004','USA','F','lauren.allen@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA013','USA-DEMO',1001,-8.00,'N','1','2065550113','MR','Matthew','M','Young','1201 3rd Ave','Seattle','WA','98101','USA','M','matthew.young@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA014','USA-DEMO',1001,-7.00,'N','1','3035550114','MS','Nicole','N','King','1700 Broadway','Denver','CO','80202','USA','F','nicole.king@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA015','USA-DEMO',1001,-5.00,'N','1','2155550115','MR','Andrew','O','Wright','1601 Market St','Philadelphia','PA','19103','USA','M','andrew.wright@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA016','USA-DEMO',1001,-8.00,'N','1','7025550116','MS','Megan','P','Lopez','3700 W Flamingo Rd','Las Vegas','NV','89103','USA','F','megan.lopez@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA017','USA-DEMO',1001,-6.00,'N','1','6125550117','MR','Joshua','Q','Hill','90 S 7th St','Minneapolis','MN','55402','USA','M','joshua.hill@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA018','USA-DEMO',1001,-5.00,'N','1','7045550118','MS','Stephanie','R','Scott','100 N Tryon St','Charlotte','NC','28202','USA','F','stephanie.scott@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA019','USA-DEMO',1001,-5.00,'N','1','3135550119','MR','Ryan','S','Green','1 Campus Martius','Detroit','MI','48226','USA','M','ryan.green@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA020','USA-DEMO',1001,-6.00,'N','1','8165550120','MS','Brittany','T','Adams','1200 Main St','Kansas City','MO','64105','USA','F','brittany.adams@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA021','USA-DEMO',1001,-6.00,'N','1','5045550121','MR','Justin','U','Baker','1 Canal St','New Orleans','LA','70130','USA','M','justin.baker@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA022','USA-DEMO',1001,-8.00,'N','1','5035550122','MS','Rachel','V','Nelson','111 SW 5th Ave','Portland','OR','97204','USA','F','rachel.nelson@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA023','USA-DEMO',1001,-7.00,'N','1','8015550123','MR','Brandon','W','Carter','15 W South Temple','Salt Lake City','UT','84101','USA','M','brandon.carter@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA024','USA-DEMO',1001,-6.00,'N','1','9015550124','MS','Heather','X','Mitchell','100 Peabody Pl','Memphis','TN','38103','USA','F','heather.mitchell@example.com','USA demo lead',0,0,'',0),
(NOW(),'NEW','','USA025','USA-DEMO',1001,-5.00,'N','1','7575550125','MR','Kevin','Y','Perez','150 W Main St','Norfolk','VA','23510','USA','M','kevin.perez@example.com','USA demo lead',0,0,'',0);
SQL
    ok "Loaded 25 USA-only demo leads into list 1001 (DEMOCAMP)"
  else
    info "USA demo leads already present on list 1001 (${usa_count})"
  fi

  # Seed hopper so agent login is not blocked by empty hopper
  mysql_file --database="$DB_NAME" <<'SQL'
DELETE FROM vicidial_hopper WHERE campaign_id='DEMOCAMP';
INSERT INTO vicidial_hopper (lead_id, campaign_id, status, user, list_id, gmt_offset_now, state, alt_dial, priority, source, vendor_lead_code)
SELECT lead_id, 'DEMOCAMP', 'READY', '', list_id, gmt_offset_now, IFNULL(state,''), 'NONE', 0, 'S', IFNULL(vendor_lead_code,'')
FROM vicidial_list
WHERE list_id IN (SELECT list_id FROM vicidial_lists WHERE campaign_id='DEMOCAMP' AND active='Y')
  AND status='NEW' AND called_since_last_reset='N'
ORDER BY lead_id LIMIT 100;
SQL
  if [[ -x /usr/share/astguiclient/AST_VDhopper.pl ]]; then
    /usr/share/astguiclient/AST_VDhopper.pl >/dev/null 2>&1 || true
  fi

  local id
  for id in 8001 6001 7001; do
    mysql_file --database="$DB_NAME" <<SQL
INSERT INTO phones (
  extension, dialplan_number, voicemail_id, server_ip, login, pass, status, active,
  phone_type, fullname, protocol, local_gmt, outbound_cid, template_id, conf_secret,
  user_group, is_webphone
) SELECT '${id}','${id}','${id}','${SERVER_IP}','${id}','${id}','ACTIVE','Y',
  'Demo Agent Phone','Demo Agent ${id}','SIP','${gmt}','0000000000','','${id}',
  '---ALL---','N'
FROM DUAL WHERE NOT EXISTS (
  SELECT 1 FROM phones WHERE extension='${id}' AND server_ip='${SERVER_IP}'
);

UPDATE phones SET
  dialplan_number='${id}', voicemail_id='${id}', login='${id}', pass='${id}',
  status='ACTIVE', active='Y', phone_type='Demo Agent Phone', fullname='Demo Agent ${id}',
  protocol='SIP', conf_secret='${id}',
  outbound_cid=IFNULL(NULLIF(outbound_cid,''),'0000000000'),
  local_gmt='${gmt}', user_group='---ALL---', is_webphone='N'
WHERE extension='${id}' AND server_ip='${SERVER_IP}';

INSERT INTO vicidial_users (
  user, pass, full_name, user_level, user_group, phone_login, phone_pass,
  active, force_change_password, api_only_user
) SELECT '${id}','${id}','Demo Agent ${id}',1,'AGENTS','${id}','${id}','Y','N','0'
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_users WHERE user='${id}');

UPDATE vicidial_users SET
  pass='${id}', full_name='Demo Agent ${id}', user_level=IF(user_level<1,1,user_level),
  user_group='AGENTS', phone_login='${id}', phone_pass='${id}',
  active='Y', force_change_password='N', api_only_user='0',
  failed_login_count=0, failed_login_attempts_today=0, failed_login_count_today=0,
  failed_last_ip_today='', failed_last_type_today=''
WHERE user='${id}';
SQL
  done

  mysql_file --database="$DB_NAME" -e \
    "UPDATE servers SET rebuild_conf_files='Y', generate_vicidial_conf='Y' WHERE server_ip='${SERVER_IP}';" \
    || true

  if [[ -x /usr/share/astguiclient/ADMIN_keepalive_ALL.pl ]]; then
    /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES --quiet >/dev/null 2>&1 || true
    if have_cmd asterisk; then
      asterisk -rx "sip reload" >/dev/null 2>&1 || true
    fi
  fi

  ok "Demo agents ready — agent 8001/8001 phone 8001/8001 (also 6001, 7001)"
  info "Agent login: http://${SERVER_IP}/agc/vicidial.php — campaign DEMOCAMP"
  info "USA demo list 1001: 25 leads, phone_code=1 (e.g. 2125550101)"

  ensure_confbridge_sessions || true
}

# Asterisk 18 has no MeetMe — use ConfBridge, and point conference rooms at the real server IP
# (sample schema ships rooms on 10.10.10.15 which causes "no available sessions").
ensure_confbridge_sessions() {
  header "ConfBridge agent sessions"
  [[ "$DRY_RUN" -eq 1 ]] && { info "(dry-run) would fix ConfBridge sessions"; return 0; }
  SERVER_IP="${SERVER_IP:-$(detect_primary_ip)}"
  [[ -n "$SERVER_IP" ]] || { warn "No SERVER_IP — skip ConfBridge fix"; return 0; }

  local tables
  tables="$(mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='vicidial_conferences';" 2>/dev/null || echo 0)"
  if [[ "${tables:-0}" -lt 1 ]]; then
    warn "vicidial_conferences missing — skip ConfBridge fix"
    return 0
  fi

  local old_ip
  old_ip="$(mysql_exec -N -e "SELECT server_ip FROM ${DB_NAME}.vicidial_conferences WHERE server_ip<>'${SERVER_IP}' GROUP BY server_ip LIMIT 1;" 2>/dev/null || true)"

  if [[ -n "$old_ip" && -x /usr/share/astguiclient/ADMIN_update_server_ip.pl ]]; then
    info "Rewriting conference server_ip ${old_ip} → ${SERVER_IP}"
    /usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
      --old-server_ip="$old_ip" --server_ip="$SERVER_IP" >/dev/null 2>&1 || true
  fi

  mysql_file --database="$DB_NAME" <<SQL
UPDATE conferences SET server_ip='${SERVER_IP}' WHERE server_ip<>'${SERVER_IP}';
UPDATE vicidial_conferences SET server_ip='${SERVER_IP}' WHERE server_ip<>'${SERVER_IP}';
UPDATE vicidial_conferences SET extension='' WHERE server_ip='${SERVER_IP}';

UPDATE servers SET
  conf_engine='CONFBRIDGE',
  active='Y',
  active_asterisk_server='Y',
  active_agent_login_server='Y',
  rebuild_conf_files='Y',
  generate_vicidial_conf='Y'
WHERE server_ip='${SERVER_IP}';

DELETE FROM vicidial_confbridges WHERE server_ip='${SERVER_IP}';
INSERT INTO vicidial_confbridges (conf_exten, server_ip, extension, leave_3way)
SELECT conf_exten, server_ip, '', '0'
FROM vicidial_conferences
WHERE server_ip='${SERVER_IP}';
SQL

  if [[ -x /usr/share/astguiclient/ADMIN_keepalive_ALL.pl ]]; then
    /usr/share/astguiclient/ADMIN_keepalive_ALL.pl --CONFERENCES >/dev/null 2>&1 || true
  fi
  if have_cmd asterisk; then
    asterisk -rx "module reload app_confbridge.so" >/dev/null 2>&1 || true
    asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
  fi

  local free
  free="$(mysql_exec -N -e "SELECT COUNT(*) FROM ${DB_NAME}.vicidial_confbridges WHERE server_ip='${SERVER_IP}' AND (extension IS NULL OR extension='');" 2>/dev/null || echo 0)"
  ok "ConfBridge ready — ${free} free agent sessions on ${SERVER_IP}"
}

# Original VICIdial web admin (HTTP Basic Auth): user 6666 / pass 1234 with full rights.
ensure_default_admin_full_access() {
  header "Default admin 6666 — full access"
  [[ "$DRY_RUN" -eq 1 ]] && { info "(dry-run) would ensure admin 6666/1234 full access"; return 0; }
  local tables
  tables="$(mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='vicidial_users';" 2>/dev/null || echo 0)"
  if [[ "${tables:-0}" -lt 1 ]]; then
    warn "vicidial_users missing — skip default admin (load schema first)"
    return 0
  fi
  mysql_file --database="$DB_NAME" <<'SQL'
INSERT INTO vicidial_users (
  user, pass, full_name, user_level, user_group, active, force_change_password,
  modify_users, modify_campaigns, modify_lists, modify_servers, view_reports,
  ast_admin_access, alter_admin_interface_options, modify_same_user_level
) SELECT '6666','1234','Admin',9,'ADMIN','Y','N','1','1','1','1','1','1','1','1'
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_users WHERE user='6666');

UPDATE vicidial_users SET
  pass='1234',
  full_name='Admin',
  user_level=9,
  user_group='ADMIN',
  active='Y',
  force_change_password='N',
  api_only_user='0',
  delete_users='1',
  delete_user_groups='1',
  delete_lists='1',
  delete_campaigns='1',
  delete_ingroups='1',
  delete_remote_agents='1',
  load_leads='1',
  campaign_detail='1',
  ast_admin_access='1',
  ast_delete_phones='1',
  delete_scripts='1',
  modify_leads='1',
  hotkeys_active='1',
  change_agent_campaign='1',
  agent_choose_ingroups='1',
  scheduled_callbacks='1',
  agentonly_callbacks='1',
  agentcall_manual='1',
  vicidial_recording='1',
  vicidial_transfers='1',
  delete_filters='1',
  alter_agent_interface_options='1',
  closer_default_blended='1',
  delete_call_times='1',
  modify_call_times='1',
  modify_users='1',
  modify_campaigns='1',
  modify_lists='1',
  modify_scripts='1',
  modify_filters='1',
  modify_ingroups='1',
  modify_usergroups='1',
  modify_remoteagents='1',
  modify_servers='1',
  view_reports='1',
  qc_enabled='1',
  qc_pass='1',
  qc_finish='1',
  qc_commit='1',
  add_timeclock_log='1',
  modify_timeclock_log='1',
  delete_timeclock_log='1',
  modify_inbound_dids='1',
  delete_inbound_dids='1',
  download_lists='1',
  manager_shift_enforcement_override='1',
  shift_override_flag='1',
  export_reports='1',
  delete_from_dnc='1',
  allow_alerts='1',
  callcard_admin='1',
  modify_shifts='1',
  modify_phones='1',
  modify_carriers='1',
  modify_labels='1',
  modify_statuses='1',
  modify_voicemail='1',
  modify_audiostore='1',
  modify_moh='1',
  modify_tts='1',
  modify_contacts='1',
  modify_same_user_level='1',
  agentcall_email='1',
  modify_email_accounts='1',
  alter_admin_interface_options='1',
  modify_custom_dialplans='1',
  modify_languages='1',
  modify_colors='1',
  modify_auto_reports='1',
  download_invalid_files='1',
  modify_dial_prefix='1',
  hci_enabled='1',
  modify_settings_containers='1',
  export_gdpr_leads='1',
  vdc_agent_api_access='1',
  modify_ip_lists='1',
  ignore_ip_list='1'
WHERE user='6666';
SQL
  ok "Default admin 6666 / 1234 has full access (original VICIdial Basic Auth login)"
}

# Dynamic portal IP validation: enable Allow IP Lists, keep PORTAL_DYNAMIC in sync
# with the current public/LAN IP, and bind it to ADMIN web access.
ensure_dynamic_portal_ip_validation() {
  header "Dynamic portal IP validation"
  [[ "$DRY_RUN" -eq 1 ]] && { info "(dry-run) would enable portal IP lists"; return 0; }

  SERVER_IP="${SERVER_IP:-$(detect_primary_ip)}"
  PUBLIC_IP="${PUBLIC_IP:-$SERVER_IP}"
  local tables
  tables="$(mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='vicidial_ip_lists';" 2>/dev/null || echo 0)"
  if [[ "${tables:-0}" -lt 1 ]]; then
    warn "vicidial_ip_lists missing — skip portal IP validation"
    return 0
  fi

  # Discover current addresses (LAN + public + localhost for webserver callbacks).
  local -a ips=()
  local cand
  for cand in "$SERVER_IP" "$PUBLIC_IP" "127.0.0.1" "$(detect_primary_ip 2>/dev/null || true)"; do
    [[ -n "$cand" ]] || continue
    [[ "$cand" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    ips+=("$cand")
  done
  # Optional: public IP via metadata/DNS if different
  if have_cmd curl; then
    cand="$(curl -4 -fsS -m 3 https://ifconfig.me/ip 2>/dev/null || curl -4 -fsS -m 3 https://api.ipify.org 2>/dev/null || true)"
    if [[ "$cand" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ips+=("$cand")
      PUBLIC_IP="${PUBLIC_IP:-$cand}"
    fi
  fi
  # Unique
  local uniq="" ip
  for ip in "${ips[@]}"; do
    [[ " $uniq " == *" $ip "* ]] && continue
    uniq+=" $ip"
  done
  ips=($uniq)
  [[ ${#ips[@]} -gt 0 ]] || { warn "No IPs detected for portal list"; return 0; }

  info "Portal IP whitelist: ${ips[*]}"

  mysql_file --database="$DB_NAME" <<SQL
UPDATE system_settings SET allow_ip_lists='1' WHERE allow_ip_lists IS NOT NULL;

INSERT INTO vicidial_ip_lists (ip_list_id, ip_list_name, active, user_group)
SELECT 'PORTAL_DYNAMIC', 'Dynamic portal whitelist (auto)', 'Y', '---ALL---'
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM vicidial_ip_lists WHERE ip_list_id='PORTAL_DYNAMIC');

UPDATE vicidial_ip_lists SET active='Y', ip_list_name='Dynamic portal whitelist (auto)' WHERE ip_list_id='PORTAL_DYNAMIC';

DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='PORTAL_DYNAMIC';
SQL

  for ip in "${ips[@]}"; do
    mysql_file --database="$DB_NAME" -e \
      "INSERT INTO vicidial_ip_list_entries (ip_list_id, ip_address) VALUES ('PORTAL_DYNAMIC','${ip}');" \
      || true
  done

  # ADMIN group: portal (admin) access must match whitelist. Agents stay open (empty).
  mysql_file --database="$DB_NAME" <<'SQL'
UPDATE vicidial_user_groups
  SET admin_ip_list='PORTAL_DYNAMIC'
  WHERE user_group='ADMIN';
UPDATE vicidial_users
  SET modify_ip_lists='1', ignore_ip_list='1'
  WHERE user='6666';
SQL

  # Helper: refresh whitelist + optional ADMIN_update_server_ip when the host IP changes.
  local helper="/usr/local/sbin/vicidial-portal-ip-sync.sh"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p /usr/local/sbin /var/log/astguiclient
    cat > "$helper" <<'HELPER'
#!/usr/bin/env bash
# Keep VICIdial PORTAL_DYNAMIC IP list + VARserver_ip in sync with this host.
set -euo pipefail
CONF="${ASTGUI_CONF:-/etc/astguiclient.conf}"
LOG="${VICI_IP_SYNC_LOG:-/var/log/astguiclient/portal-ip-sync.log}"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >/dev/null; }

new_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -z "$new_ip" ]] && new_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
pub_ip="$(curl -4 -fsS -m 3 https://ifconfig.me/ip 2>/dev/null || true)"
[[ "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || pub_ip=""

old_ip=""
if [[ -f "$CONF" ]]; then
  old_ip="$(awk -F= '/^VARserver_ip=/{print $2; exit}' "$CONF" | tr -d ' \t\r')"
fi
[[ -n "$new_ip" ]] || { log "ERROR: could not detect local IP"; exit 1; }

mysql_cli=(mysql -N -B)
have_mariadb=0
command -v mariadb >/dev/null 2>&1 && { mysql_cli=(mariadb -N -B); have_mariadb=1; }

db_exec() { "${mysql_cli[@]}" -u root "$@" 2>/dev/null; }

db_exec asterisk -e "UPDATE system_settings SET allow_ip_lists='1';" || true
db_exec asterisk -e "INSERT IGNORE INTO vicidial_ip_lists (ip_list_id,ip_list_name,active,user_group) VALUES ('PORTAL_DYNAMIC','Dynamic portal whitelist (auto)','Y','---ALL---');" || true
db_exec asterisk -e "UPDATE vicidial_ip_lists SET active='Y' WHERE ip_list_id='PORTAL_DYNAMIC';" || true

# Refresh entries: localhost + LAN + public
db_exec asterisk -e "DELETE FROM vicidial_ip_list_entries WHERE ip_list_id='PORTAL_DYNAMIC';" || true
for ip in 127.0.0.1 "$new_ip" $pub_ip; do
  [[ -n "$ip" ]] || continue
  db_exec asterisk -e "INSERT INTO vicidial_ip_list_entries (ip_list_id,ip_address) VALUES ('PORTAL_DYNAMIC','${ip}');" || true
done
db_exec asterisk -e "UPDATE vicidial_user_groups SET admin_ip_list='PORTAL_DYNAMIC' WHERE user_group='ADMIN';" || true

log "Portal IP list synced (local=${new_ip} public=${pub_ip:-none} previous=${old_ip:-none})"

if [[ -n "$old_ip" && "$old_ip" != "$new_ip" && -x /usr/share/astguiclient/ADMIN_update_server_ip.pl ]]; then
  log "Server IP changed ${old_ip} → ${new_ip}; running ADMIN_update_server_ip.pl"
  /usr/share/astguiclient/ADMIN_update_server_ip.pl --auto \
    --old-server_ip="$old_ip" --server_ip="$new_ip" >>"$LOG" 2>&1 || \
    log "WARN: ADMIN_update_server_ip.pl failed"
fi
HELPER
    chmod 755 "$helper"

    # Prefer systemd timer (Leap 16 / minimal images often have no cronie).
    if have_cmd systemctl; then
      cat > /etc/systemd/system/vicidial-portal-ip-sync.service <<'UNIT'
[Unit]
Description=VICIdial dynamic portal IP list sync
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vicidial-portal-ip-sync.sh
UNIT
      cat > /etc/systemd/system/vicidial-portal-ip-sync.timer <<'UNIT'
[Unit]
Description=Hourly VICIdial portal IP validation sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
      systemctl daemon-reload || true
      systemctl enable --now vicidial-portal-ip-sync.timer || true
      systemctl start vicidial-portal-ip-sync.service || true
      info "systemd timer: vicidial-portal-ip-sync.timer (hourly + after boot)"
    fi

    # Also install cron entries when cron directories exist (or after installing cronie).
    local cronf=""
    if [[ -d /etc/cron.d ]]; then
      cronf="/etc/cron.d/vicidial-portal-ip"
    elif [[ -d /var/spool/cron/tabs ]]; then
      cronf="/var/spool/cron/tabs/root"
    elif [[ -d /var/spool/cron ]]; then
      mkdir -p /var/spool/cron
      cronf="/var/spool/cron/root"
    fi
    if [[ -n "$cronf" ]]; then
      if [[ "$cronf" == /etc/cron.d/* ]]; then
        cat > "$cronf" <<'CRON'
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
@reboot root /usr/local/sbin/vicidial-portal-ip-sync.sh
15 * * * * root /usr/local/sbin/vicidial-portal-ip-sync.sh
CRON
        chmod 644 "$cronf"
      else
        touch "$cronf"
        if ! grep -q 'vicidial-portal-ip-sync.sh' "$cronf" 2>/dev/null; then
          cat >> "$cronf" <<'CRON'
### VICIdial dynamic portal IP validation
@reboot /usr/local/sbin/vicidial-portal-ip-sync.sh
15 * * * * /usr/local/sbin/vicidial-portal-ip-sync.sh
CRON
          chmod 600 "$cronf"
        fi
      fi
    fi
  fi

  ok "Dynamic portal IP validation enabled (list PORTAL_DYNAMIC → ADMIN admin_ip_list)"
  info "6666 has ignore_ip_list=1 so default admin cannot lock itself out"
  info "Sync helper: /usr/local/sbin/vicidial-portal-ip-sync.sh (systemd timer and/or cron)"
}

ensure_kernel_build_dir() {
  local kver="${1:-$(uname -r)}"
  local build="/lib/modules/${kver}/build"
  if [[ -f "${build}/Makefile" ]]; then
    # Refuse mismatched headers (e.g. running .36 with linked .37 tree).
    local hdr=""
    hdr="$(readlink -f "$build" 2>/dev/null || true)"
    if [[ -n "$hdr" && "$hdr" != *"${kver%-default}"* && "$hdr" != *"${kver}"* ]]; then
      warn "Kernel build dir ${build} → ${hdr} does not match running ${kver}"
      return 1
    fi
    ok "Kernel headers present for ${kver}"
    return 0
  fi
  info "Installing kernel headers for ${kver}"
  zypper_try_in kernel-default-devel kernel-devel kernel-source kernel-syms || true
  local ver="${kver%-default}"
  zypper --non-interactive --gpg-auto-import-keys in -y "kernel-default-devel-${ver}" >/dev/null 2>&1 || true
  if [[ -f "${build}/Makefile" ]]; then
    ok "Kernel headers installed for ${kver}"
    return 0
  fi
  # Do not symlink a different kernel's obj dir — DAHDI will fail to compile.
  warn "No matching kernel headers for ${kver} (DAHDI skip is OK on a Cloud VM). Reboot into a kernel that has -devel installed if you need MeetMe/DAHDI."
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
  if pkg_installed libpri1 || pkg_installed libpri || [[ -f /usr/lib64/libpri.so || -f /usr/lib/libpri.so ]]; then
    ok "libpri already present"
    return 0
  fi
  zypper_n in -y libpri1 libpri-devel || zypper_try_in libpri1 libpri-devel || true
  if pkg_installed libpri1 || pkg_installed libpri || [[ -f /usr/lib64/libpri.so || -f /usr/lib/libpri.so ]]; then
    return 0
  fi
  info "Building libpri from source (${LIBPRI_SRC_URL})"
  mkdir -p "$SRC_DIR/libpri-build"
  (
    cd "$SRC_DIR/libpri-build"
    [[ -f libpri.tar.gz ]] || wget -O libpri.tar.gz "$LIBPRI_SRC_URL"
    tar xf libpri.tar.gz
    local tree
    tree="$(find "$SRC_DIR/libpri-build" -maxdepth 1 -type d -name 'libpri-*' | sort | tail -n1)"
    [[ -n "$tree" ]] || die "libpri source tree not found"
    # Utilities (pridump) need dahdi/user.h — not required for Asterisk. Build libs only.
    make -C "$tree" libpri.a libpri.so.1.4
    make -C "$tree" install
    ldconfig
  )
  [[ -f /usr/lib64/libpri.so || -f /usr/lib/libpri.so || -f /usr/local/lib/libpri.so ]] \
    || die "libpri install failed"
  ok "libpri installed from source"
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
    ensure_asterisk_systemd_unit
    return
  fi
  install_libpri
  mkdir -p "$SRC_DIR/asterisk-build"
  (
    cd "$SRC_DIR/asterisk-build"
    local tarball="asterisk-18.tar.gz" url=""
    # Reject tiny/HTML leftovers from a prior 404 download.
    if [[ -f "$tarball" ]] && ! tar tzf "$tarball" >/dev/null 2>&1; then
      warn "Removing corrupt ${tarball}"
      rm -f "$tarball"
    fi
    if [[ ! -f "$tarball" ]]; then
      for url in \
        "$ASTERISK_SRC_URL" \
        "https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-18.26.4.tar.gz"
      do
        info "Trying Asterisk source: $url"
        if wget -O "$tarball" "$url" && tar tzf "$tarball" >/dev/null 2>&1; then
          break
        fi
        rm -f "$tarball"
      done
      [[ -f "$tarball" ]] || die "Could not download Asterisk 18 (use old-releases/asterisk-18.26.4.tar.gz)"
    else
      info "Reusing existing ${SRC_DIR}/asterisk-build/${tarball}"
    fi
    run tar xf "$tarball"
    local tree
    tree="$(find "$SRC_DIR/asterisk-build" -maxdepth 1 -type d -name 'asterisk-18*' | sort -V | tail -n1)"
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
    # Asterisk 18.26+ renamed Dial() timeout vars (to/orig → to_answer/orig_answer_to).
    if grep -q '\*to = orig;' apps/app_dial.c 2>/dev/null; then
      info "Adapting timeout_reset dial patch for Asterisk 18.26+ API"
      sed -i \
        -e 's/\*to = orig;/*to_answer = orig_answer_to;/' \
        -e 's/Dial Tiemout Reset/Dial Timeout Reset/g' \
        apps/app_dial.c
    fi

    contrib/scripts/install_prereq install || warn "Asterisk install_prereq reported issues"
    # OpenSSL libs for crypto; do NOT enable Asterisk TLS / Apache HTTPS.
    # sqlite3 is Asterisk astdb only — VICIdial lives in MariaDB.
    run ./configure --libdir=/usr/lib64 --with-gsm=internal --with-ssl \
      LDFLAGS='-L/usr/lib64' --with-pjproject-bundled --with-jansson-bundled
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
  ensure_asterisk_systemd_unit
  detect_asterisk
  ok "Asterisk installed: ${ASTERISK_VERSION:-unknown}"
}

ensure_asterisk_systemd_unit() {
  ensure_asterisk
}

ensure_asterisk() {
  # SETUP: unit + chan_sip + enable/start (same pattern as ensure_apache / MariaDB).
  header "Asterisk telephony — check unit, enable chan_sip, start"
  [[ "$DRY_RUN" -eq 1 ]] && { info "(dry-run) would ensure Asterisk systemd unit + start"; return 0; }
  if ! have_cmd asterisk; then
    warn "asterisk binary not found — run install (Phase 6) first"
    return 1
  fi

  mkdir -p /run/asterisk /var/run/asterisk /var/log/asterisk /var/spool/asterisk /var/lib/asterisk

  # VICIdial uses classic chan_sip (Asterisk samples noload it for PJSIP).
  if [[ -f /etc/asterisk/modules.conf ]]; then
    sed -i 's/^noload *= *chan_sip.so/;noload = chan_sip.so/' /etc/asterisk/modules.conf || true
    ok "chan_sip enabled in modules.conf"
  fi

  local unit_file="/etc/systemd/system/asterisk.service"
  if [[ ! -f "$unit_file" ]] && [[ ! -f /usr/lib/systemd/system/asterisk.service ]]; then
    info "Creating ${unit_file}"
  fi
  # Always (re)write our known-good unit so Leap source builds get enable+start.
  cat > "$unit_file" <<'UNIT'
[Unit]
Description=Asterisk PBX (VICIdial)
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=forking
Environment=HOME=/var/lib/asterisk
WorkingDirectory=/var/lib/asterisk
ExecStartPre=-/bin/mkdir -p /run/asterisk /var/log/asterisk /var/spool/asterisk
ExecStart=/usr/sbin/asterisk -g -vvvg
ExecReload=/usr/sbin/asterisk -rx 'core reload'
ExecStop=/usr/sbin/asterisk -rx 'core stop gracefully'
PIDFile=/run/asterisk/asterisk.pid
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

  if have_cmd systemctl; then
    systemctl daemon-reload || true
    if ! ensure_unit asterisk 40; then
      warn "asterisk.service did not become active — try: asterisk -vvvg &"
      # Last resort: start binary so CLI works for lab boxes
      if [[ "$(unit_state asterisk)" != "active" ]] && ! pgrep -x asterisk >/dev/null 2>&1; then
        /usr/sbin/asterisk -g -vvvg || true
        sleep 2
      fi
    fi
  else
    pgrep -x asterisk >/dev/null 2>&1 || /usr/sbin/asterisk -g -vvvg || true
  fi

  # Load chan_sip if Asterisk is up but module was noloaded at start
  if [[ -S /run/asterisk/asterisk.ctl ]] || [[ -S /var/run/asterisk/asterisk.ctl ]]; then
    asterisk -rx 'module show like chan_sip.so' 2>/dev/null | grep -q 'chan_sip' || \
      asterisk -rx 'module load chan_sip.so' >/dev/null 2>&1 || true
  fi

  detect_asterisk
  if [[ -S /run/asterisk/asterisk.ctl ]] || [[ -S /var/run/asterisk/asterisk.ctl ]]; then
    ok "Asterisk ${ASTERISK_VERSION:-ok} running (use: asterisk -r)"
    return 0
  fi
  warn "Asterisk installed but remote console socket missing"
  return 1
}

cmd_setup() {
  need_root
  header "SETUP — enable and start VICIdial services"
  phase_detect
  confirm "Run SETUP (Apache/MariaDB/Asterisk/portal IP) on $(host_name)?" || die "Aborted"

  case "$ROLE" in
    express|all|web)
      ensure_apache || true
      ;;
  esac
  case "$ROLE" in
    express|all|database|web)
      ensure_mariadb_running || true
      ;;
  esac
  case "$ROLE" in
    express|all|telephony)
      ensure_asterisk || true
      ;;
  esac
  if have_cmd systemctl; then
    ensure_unit chronyd 15 || warn "chronyd not active"
  fi

  # Portal IP + default admin + demo agents when DB is reachable
  if wait_for_mariadb_ping 5 2>/dev/null; then
    ensure_default_admin_full_access || true
    ensure_demo_agent_phones || true
    ensure_dynamic_portal_ip_validation || true
  else
    warn "MariaDB not ready — skipped portal IP / admin / demo agent SETUP"
  fi

  # Boot hook so Asterisk comes back after reboot
  local rc="/etc/rc.d/rc.local"
  [[ -f /etc/rc.local ]] && rc="/etc/rc.local"
  if [[ -d "$(dirname "$rc")" ]]; then
    touch "$rc"
    chmod +x "$rc"
    ensure_line "$rc" "#!/bin/bash"
    if [[ -x /usr/share/astguiclient/start_asterisk_boot.pl ]]; then
      ensure_line "$rc" "/usr/share/astguiclient/start_asterisk_boot.pl"
    fi
  fi

  cmd_verify_soft
  info "SETUP done. Connect with: asterisk -r"
  info "Admin: http://${SERVER_IP:-$(detect_primary_ip)}/vicidial/admin.php (6666 / 1234)"
  info "Agent: http://${SERVER_IP:-$(detect_primary_ip)}/agc/vicidial.php (8001 / 8001, phone 8001 / 8001)"
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
    ensure_default_admin_full_access
    ensure_demo_agent_phones
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
  header "Phase 9 — Firewall ports (HTTP only — no SSL/443)"
  if have_cmd firewall-cmd && [[ "$(unit_state firewalld)" == "active" ]]; then
    local p
    # Explicitly HTTP only. Do not open 443 / https.
    firewall-cmd --permanent --remove-service=https >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port=443/tcp >/dev/null 2>&1 || true
    for p in 80/tcp 22/tcp 5060/tcp 5060/udp 4569/udp 5038/tcp; do
      run firewall-cmd --permanent --add-port="$p" || true
    done
    run firewall-cmd --permanent --add-service=http || true
    run firewall-cmd --permanent --add-port=10000-20000/udp || true
    run firewall-cmd --reload || true
    ok "firewalld ports opened (HTTP :80, SIP, IAX, AMI, RTP 10000-20000) — SSL/443 disabled"
    info "Leave 3306 closed to the internet on a single Express box"
    info "Access VICIdial at http://SERVER_IP/vicidial/welcome.php (not https)"
  else
    warn "firewalld not active; configure SIP 5060 and RTP 10000-20000 UDP yourself"
  fi
}

configure_mariadb_timestamp_only() {
  write_timestamp_cnf
  local unit
  unit="$(db_unit_name)"
  if have_cmd systemctl; then
    run systemctl restart "$unit" || run systemctl restart mariadb || true
  fi
  if wait_for_mariadb_ping 30; then
    ok "Applied MariaDB TIMESTAMP bugfix ([mysqld] explicit_defaults_for_timestamp=Off)"
  else
    warn "Wrote TIMESTAMP cnf but MariaDB ping failed after restart"
  fi
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
  detect_php; detect_apache; detect_asterisk; detect_mariadb
  [[ -n "$PHP_VERSION" ]] && ok "PHP $PHP_VERSION" || warn "PHP missing"
  if [[ "$APACHE_ACTIVE" == "active" && "$APACHE_LISTEN80" == "yes" ]]; then
    ok "Apache ${APACHE_VERSION:-ok} (${APACHE_UNIT} active, :80 listening)"
  elif [[ "$APACHE_ACTIVE" == "active" ]]; then
    warn "Apache ${APACHE_UNIT} is active but TCP 80 is not listening"
  else
    warn "Apache not running (unit=${APACHE_UNIT} state=${APACHE_ACTIVE})"
  fi
  [[ -n "$ASTERISK_VERSION" ]] && ok "Asterisk $ASTERISK_VERSION" || warn "Asterisk missing"
  if [[ -n "$MARIADB_VERSION" ]] && wait_for_mariadb_ping 5; then
    ok "MariaDB $MARIADB_VERSION (ping ok)"
  elif [[ -n "$MARIADB_VERSION" ]]; then
    warn "MariaDB $MARIADB_VERSION installed but ping failed"
  else
    warn "MariaDB missing"
  fi
  if have_cmd screen; then
    screen -ls || info "No screen sessions yet (normal before first reboot / keepalive)"
  fi
  if have_cmd apachectl || have_cmd apache2ctl; then
    (apachectl configtest || apache2ctl configtest) 2>&1 | tee -a "$LOG_FILE" || true
  fi
  if have_cmd curl; then
    info "HTTP HEAD http://127.0.0.1/"
    curl -sI -m 5 http://127.0.0.1/ | head -n 5 | tee -a "$LOG_FILE" || warn "localhost:80 did not answer"
  fi
  if [[ -d "${WWW_ROOT}/vicidial" ]]; then
    ok "Web files in ${WWW_ROOT}/vicidial"
  elif [[ -d /var/www/html/vicidial ]]; then
    ok "Web files in /var/www/html/vicidial"
  else
    warn "VICIdial web directory not found"
  fi
  info "Admin UI: http://${SERVER_IP:-$(detect_primary_ip)}/vicidial/admin.php"
  info "Default admin (original Basic Auth): 6666 / 1234 — full access; change immediately"
  info "Agent UI: http://${SERVER_IP:-$(detect_primary_ip)}/agc/vicidial.php"
  info "Demo agent: user 8001 / pass 8001 — phone login 8001 / pass 8001 (also 6001, 7001)"
  info "Demo campaign: DEMOCAMP — USA list 1001 (25 demo numbers, phone_code=1)"
  info "Portal IP validation: Allow IP Lists + PORTAL_DYNAMIC (synced hourly)"
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
      ensure_apache
      configure_mariadb
      install_dahdi
      install_asterisk
      ensure_asterisk
      checkout_vicidial
      load_schema_if_empty
      migrate_schema_chain
      run_install_pl
      ensure_default_admin_full_access
      ensure_demo_agent_phones
      ensure_dynamic_portal_ip_validation
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
      ensure_default_admin_full_access
      ensure_demo_agent_phones
      ensure_dynamic_portal_ip_validation
      write_credentials
      ;;
    web)
      install_base_packages
      install_php
      ensure_apache
      checkout_vicidial
      run_install_pl
      ensure_default_admin_full_access
      ensure_demo_agent_phones
      ensure_dynamic_portal_ip_validation
      write_credentials
      configure_firewall
      ;;
    telephony)
      install_base_packages
      install_dahdi
      install_asterisk
      ensure_asterisk
      checkout_vicidial
      run_install_pl
      install_crontab_and_boot
      configure_firewall
      write_credentials
      ;;
    archive)
      install_base_packages
      zypper_n in -y vsftpd || true
      ensure_unit vsftpd 15 || true
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
  if [[ "$COMMAND" == "install" || "$COMMAND" == "migrate" || "$COMMAND" == "setup" ]]; then
    trap 'trap_err $LINENO "$BASH_COMMAND"' ERR
  fi
  case "$COMMAND" in
    help) usage ;;
    detect) cmd_detect ;;
    check) cmd_check ;;
    setup) cmd_setup ;;
    install) cmd_install ;;
    migrate) cmd_migrate ;;
    iso-verify|download-iso|write-usb)
      die "ISO install is disabled. On Hetzner: install OpenSUSE Leap 15.6, then $SCRIPT_NAME install --role express --yes --stop-conflicts"
      ;;
    *) die "Unknown command: $COMMAND (try: $SCRIPT_NAME help)" ;;
  esac
}

main "$@"
