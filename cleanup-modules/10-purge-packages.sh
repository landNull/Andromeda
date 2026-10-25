# cleanup-modules/10-purge-packages.sh
# Stop listeners, drop Andromeda databases while MariaDB still answers,
# then optionally apt-purge the packages the installer added.

echo "STEP 10: services, databases, apt packages"
echo "------------------------------------------"

drop_andromeda_databases() {
  cli=""
  if command -v mariadb >/dev/null 2>&1; then
    cli=mariadb
  elif command -v mysql >/dev/null 2>&1; then
    cli=mysql
  fi
  if [ -z "$cli" ]; then
    echo "  no mysql/mariadb client; skip database drop"
    return 0
  fi
  if ! as_root "$cli" -N -e "SELECT 1" >/dev/null 2>&1; then
    echo "  MariaDB not answering; skip database drop"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ DROP DATABASE bd_* and gitea; DROP USER gitea@localhost"
    as_root "$cli" -N -e "SHOW DATABASES;" 2>/dev/null | grep -E '^(bd_|gitea$)' | while read -r db; do
      echo "    would drop $db"
    done
    return 0
  fi
  as_root "$cli" -N -e "SHOW DATABASES;" 2>/dev/null | grep -E '^(bd_|gitea$)' | while read -r db; do
    [ -n "$db" ] || continue
    as_root "$cli" -e "DROP DATABASE IF EXISTS \`${db}\`;" >/dev/null 2>&1 || true
    echo "  dropped database $db"
  done
  as_root "$cli" -e "DROP USER IF EXISTS 'gitea'@'localhost';" >/dev/null 2>&1 || true
  as_root "$cli" -e "DROP USER IF EXISTS 'gitea'@'127.0.0.1';" >/dev/null 2>&1 || true
  as_root "$cli" -e "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
  echo "  dropped MariaDB user gitea (if it existed)"
}

stop_andromeda_services() {
  echo "  stopping listeners..."
  stop_svc gitea
  stop_svc apache2
  stop_svc httpd
  stop_svc php-fpm
  for s in /etc/init.d/php*-fpm; do
    [ -x "$s" ] || continue
    stop_svc "$(basename "$s")"
  done
  # Leave MariaDB up until drop_andromeda_databases has run.
}

APT_PACKAGES="apache2 mariadb-server php-fpm php-cli php-mysql php-xml php-gd php-mbstring php-curl php-zip php-intl php-bcmath php-imagick php-apcu apache2-utils mariadb-backup msmtp-mta unattended-upgrades needrestart logwatch goaccess etckeeper smartmontools irqbalance haveged moreutils jq pv age dnsmasq"

purge_package_framework() {
  if [ "$PURGE_ALL" -ne 1 ]; then
    echo "  apt packages kept (soft removal). Re-run with -p to purge them."
    return 0
  fi
  echo "  purge flag: stripping apt packages the installer added..."
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ stop mysql/mariadb"
    echo "+ DEBIAN_FRONTEND=noninteractive apt-get purge -y $APT_PACKAGES"
    echo "+ apt-get autoremove --purge -y && apt-get clean"
    return 0
  fi
  stop_svc mysql
  stop_svc mariadb
  as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confmiss" \
    $APT_PACKAGES || true
  as_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge || true
  as_root env DEBIAN_FRONTEND=noninteractive apt-get clean || true
  echo "  apt packages purged"
}

stop_andromeda_services
drop_andromeda_databases
purge_package_framework
