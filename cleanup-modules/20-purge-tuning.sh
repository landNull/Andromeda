# cleanup-modules/20-purge-tuning.sh
# Drop installer-written configs. Leave distro defaults.

echo "STEP 20: tuning drop-ins"
echo "-----------------------"

rm_if() {
  do_rm "$1"
}

echo "  Apache..."
rm_if /etc/apache2/conf-enabled/andromeda-perf.conf
rm_if /etc/apache2/conf-available/andromeda-perf.conf
rm_if /etc/apache2/conf-enabled/andromeda-harden.conf
rm_if /etc/apache2/conf-available/andromeda-harden.conf
rm_if /etc/apache2/conf-enabled/andromeda-localhost.conf
rm_if /etc/apache2/conf-available/andromeda-localhost.conf

# Platform / site vhosts that point at /srv/platforms or carry the andromeda- prefix.
if [ -d /etc/apache2/sites-available ]; then
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ scan /etc/apache2/sites-* for andromeda-* and /srv/platforms vhosts"
  else
    for f in /etc/apache2/sites-available/andromeda-*.conf \
             /etc/apache2/sites-enabled/andromeda-*.conf; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      base=$(basename "$f" .conf)
      if command -v a2dissite >/dev/null 2>&1; then
        as_root a2dissite "$base" >/dev/null 2>&1 || true
      fi
      as_root rm -f "$f"
      echo "  removed $f"
    done
    for f in /etc/apache2/sites-available/*.conf; do
      [ -f "$f" ] || continue
      case $f in
        */000-default.conf|*/default-ssl.conf|*/000-default-le-ssl.conf) continue ;;
      esac
      if grep -q /srv/platforms "$f" 2>/dev/null; then
        base=$(basename "$f" .conf)
        if command -v a2dissite >/dev/null 2>&1; then
          as_root a2dissite "$base" >/dev/null 2>&1 || true
        fi
        as_root rm -f "$f" "/etc/apache2/sites-enabled/${base}.conf"
        echo "  removed platform vhost $f"
      fi
    done
  fi
fi

echo "  PHP..."
if [ "$DRYRUN" -eq 1 ]; then
  echo "+ rm /etc/php*/**/{30-andromeda.ini,35-andromeda-*.ini,pool.d/andromeda.conf}"
else
  find /etc/php /etc/php.d -type f \( \
    -name "30-andromeda.ini" -o \
    -name "35-andromeda-*.ini" -o \
    -name "andromeda.ini" \
  \) 2>/dev/null | while read -r ini_file; do
    as_root rm -f "$ini_file"
    echo "  removed $ini_file"
  done
  find /etc/php -type f -path "*/fpm/pool.d/andromeda.conf" 2>/dev/null | while read -r pool; do
    as_root rm -f "$pool"
    echo "  removed $pool"
  done
  as_root rm -f /run/php/andromeda-fpm.sock /run/php/andromeda-fpm.sock.default
fi

echo "  MariaDB drop-ins..."
if [ "$DRYRUN" -eq 1 ]; then
  echo "+ rm */90-andromeda.cnf"
else
  find /etc/mysql /etc/my.cnf.d -type f -name "90-andromeda.cnf" 2>/dev/null | while read -r cnf_file; do
    as_root rm -f "$cnf_file"
    echo "  removed $cnf_file"
  done
fi

echo "  sysctl / limits / logrotate / apt / dns / profile..."
rm_if /etc/sysctl.d/60-andromeda.conf
rm_if /etc/security/limits.d/andromeda.conf
rm_if /etc/logrotate.d/andromeda
rm_if /etc/apt/apt.conf.d/52andromeda-unattended
rm_if /etc/dnsmasq.d/andromeda.conf
rm_if /etc/profile.d/andromeda.sh
if [ "$DRYRUN" -ne 1 ]; then
  as_root sysctl --system >/dev/null 2>&1 || true
fi

echo "  tuning drop-ins removed"
