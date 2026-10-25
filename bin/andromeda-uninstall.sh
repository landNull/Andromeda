#!/bin/sh
# andromeda-uninstall.sh — Remove Andromeda and its managed platforms/sites.
# Usage: ./andromeda-uninstall.sh [-n] [--force] [--keep-backups]
#   -n: Dry run (show what would be deleted).
#   --force: Skip confirmation prompts (DANGEROUS).
#   --keep-backups: Preserve backup directories (default: delete).

set -eu

PROG=${0##*/}
DRYRUN=0
FORCE=0
KEEP_BACKUPS=0
STARDUST_ROOT=${STARDUST_ROOT:-/srv/andromeda}
PLATFORMS=${PLATFORMS:-/srv/platforms}
BACKUP_ROOT=${BACKUP_ROOT:-$STARDUST_ROOT/backups}
APACHE_CONF=${APACHE_CONF:-/etc/apache2}
MYSQL_CMD="mysql -u root"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
  cat <<EOF
${PROG} — Uninstall Andromeda and its managed platforms/sites.

USAGE:
  ${PROG} [-n] [--force] [--keep-backups]

FLAGS:
  -n              Dry run. Show what would be deleted without making changes.
  --force        Skip all confirmation prompts (USE WITH CAUTION).
  --keep-backups  Preserve backup directories (default: delete).

EXAMPLES:
  ${PROG} -n                          # Preview what would be deleted.
  ${PROG} --force                     # Uninstall without prompts.
  ${PROG} --keep-backups              # Uninstall but keep backups.

NOTES:
  - This script must be run as root or via sudo.
  - It will remove ALL platforms under ${PLATFORMS} and Andromeda files under ${STARDUST_ROOT}.
  - Databases prefixed with 'bd_' will be dropped unless --keep-backups is used.
EOF
}

log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

# Check if we are root or have sudo privileges
check_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      echo -e "${YELLOW}This script requires root privileges.${NC}"
      printf "Would you like to run it with sudo? [Y/n]: "
      read -r response
      case "$response" in
        [nN]|[nN][oO])
          error "Aborted. Please run with sudo manually: sudo $0 $*"
          ;;
        *)
          echo -e "${GREEN}Re-executing with sudo...${NC}"
          exec sudo "$0" "$@"
          ;;
      esac
    else
      error "This script must be run as root. sudo is not available."
    fi
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case $1 in
    -n) DRYRUN=1 ;;
    --force) FORCE=1 ;;
    --keep-backups) KEEP_BACKUPS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown flag: $1" ;;
  esac
  shift
done

# Check for root or sudo
check_sudo

# Confirm Andromeda is installed
if [ ! -d "$STARDUST_ROOT" ] || [ ! -d "$PLATFORMS" ]; then
  error "Andromeda does not appear to be installed (missing $STARDUST_ROOT or $PLATFORMS)."
fi

# List platforms
list_platforms() {
  if [ -d "$PLATFORMS" ]; then
    find "$PLATFORMS" -mindepth 1 -maxdepth 1 -type d | sort
  else
    echo ""
  fi
}

# List databases
list_databases() {
  $MYSQL_CMD -e "SHOW DATABASES;" | grep "^bd_" | awk '{print $1}'
}

# List Apache vhosts
list_vhosts() {
  if [ -d "$APACHE_CONF/sites-enabled" ]; then
    ls "$APACHE_CONF/sites-enabled/" | sed 's/\.conf$//' | grep -E '^bd_|^[a-zA-Z0-9-]+\.[a-zA-Z0-9-]+\.devel$'
  else
    echo ""
  fi
}

# Confirmation prompt
confirm() {
  if [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  printf "${YELLOW}WARNING: This will IRREVERSIBLY delete:${NC}\n"
  printf "  - All platforms in ${PLATFORMS}\n"
  printf "  - All databases prefixed with 'bd_'\n"
  printf "  - All Apache vhosts managed by Andromeda\n"
  printf "  - Andromeda files in ${STARDUST_ROOT}\n"
  if [ "$KEEP_BACKUPS" -eq 0 ]; then
    printf "  - All backups in ${BACKUP_ROOT}\n"
  fi
  printf "\n"
  printf "Type 'YES' to confirm: "
  read -r response
  if [ "$response" != "YES" ]; then
    error "Aborted by user."
  fi
}

# Dry-run mode
run_cmd() {
  if [ "$DRYRUN" -eq 1 ]; then
    echo "[DRY RUN] $1"
  else
    eval "$1"
  fi
}

# Main uninstall logic
uninstall() {
  log "Starting Andromeda uninstallation..."

  # 1. Disable and remove Apache vhosts
  for vhost in $(list_vhosts); do
    if [ -n "$vhost" ]; then
      run_cmd "a2dissite ${vhost}.conf"
      run_cmd "rm -f ${APACHE_CONF}/sites-enabled/${vhost}.conf"
      run_cmd "rm -f ${APACHE_CONF}/sites-available/${vhost}.conf"
      log "Removed Apache vhost: ${vhost}"
    fi
  done

  # 2. Drop databases
  for db in $(list_databases); do
    if [ -n "$db" ]; then
      run_cmd "$MYSQL_CMD -e \"DROP DATABASE IF EXISTS \`${db}\`;\""
      log "Dropped database: ${db}"
    fi
  done

  # 3. Remove platforms
  for platform in $(list_platforms); do
    if [ -n "$platform" ]; then
      run_cmd "rm -rf ${platform}"
      log "Removed platform: ${platform}"
    fi
  done

  # 4. Remove backups (unless --keep-backups)
  if [ "$KEEP_BACKUPS" -eq 0 ]; then
    if [ -d "$BACKUP_ROOT" ]; then
      run_cmd "rm -rf ${BACKUP_ROOT}"
      log "Removed backups: ${BACKUP_ROOT}"
    fi
  else
    log "Preserved backups: ${BACKUP_ROOT}"
  fi

  # 5. Remove Andromeda root
  if [ -d "$STARDUST_ROOT" ]; then
    run_cmd "rm -rf ${STARDUST_ROOT}"
    log "Removed Andromeda root: ${STARDUST_ROOT}"
  fi

  # 6. Remove cron jobs
  if [ -f "/etc/cron.d/andromeda" ]; then
    run_cmd "rm -f /etc/cron.d/andromeda"
    log "Removed cron file: /etc/cron.d/andromeda"
  fi

  # 7. Remove andromeda-priv
  if [ -f "/usr/local/sbin/andromeda-priv" ]; then
    run_cmd "rm -f /usr/local/sbin/andromeda-priv"
    log "Removed andromeda-priv: /usr/local/sbin/andromeda-priv"
  fi

  # 8. Reload Apache
  if command -v systemctl >/dev/null 2>&1; then
    run_cmd "systemctl reload apache2"
  elif [ -x /etc/init.d/apache2 ]; then
    run_cmd "/etc/init.d/apache2 reload"
  fi

  log "Uninstallation complete."
}

# Show what would be deleted in dry-run mode
if [ "$DRYRUN" -eq 1 ]; then
  echo "[DRY RUN MODE] No changes will be made."
  echo "The following would be deleted:"
  echo "----------------------------------------"
  echo "Platforms:"
  for platform in $(list_platforms); do
    echo "  - ${platform}"
  done
  echo "Databases:"
  for db in $(list_databases); do
    echo "  - ${db}"
  done
  echo "Apache Vhosts:"
  for vhost in $(list_vhosts); do
    echo "  - ${vhost}.conf"
  done
  echo "Andromeda Root: ${STARDUST_ROOT}"
  if [ "$KEEP_BACKUPS" -eq 0 ]; then
    echo "Backups: ${BACKUP_ROOT}"
  else
    echo "Backups: (preserved)"
  fi
  echo "----------------------------------------"
  exit 0
fi

# Confirm and proceed
confirm
uninstall

exit 0
