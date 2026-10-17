# shellcheck shell=sh

ensure_settings_php() {
  root=$1
  product=$2
  web=$root/web
  src=$web/settings.php
  dest=$web/sites/$product/settings.php
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  run_root mkdir -p "$web/sites/$product"
  if [ -f "$src" ] && [ ! -f "$dest" ]; then
    run_root cp "$src" "$dest"
  elif [ ! -f "$dest" ]; then
    as_root tee "$dest" >/dev/null <<'EOF'
<?php
EOF
  fi
  if ! grep -q "config/$product/active" "$dest" 2>/dev/null; then
    as_root tee -a "$dest" >/dev/null <<EOF

\$config_directories['active']  = '../../config/$product/active';
\$config_directories['staging'] = '../../config/$product/staging';
\$config['system.core']['config_sync_clear_staging'] = 0;
\$config['system.core']['file_private_path'] = '../../files_private/$product';
\$settings['file_public_path'] = '../../files/$product';

if (file_exists(__DIR__ . '/settings.local.php')) {
  include __DIR__ . '/settings.local.php';
}
EOF
  fi
  run_root chown "$OWNER:$GROUP" "$dest"
}

ensure_sites_php() {
  web=$1
  host=$2
  product=$3
  dest=$web/sites/sites.php
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ \$sites['$host'] = '$product' in $dest"
    return 0
  fi
  run_root mkdir -p "$web/sites"
  if [ ! -f "$dest" ]; then
    as_root tee "$dest" >/dev/null <<'EOF'
<?php
EOF
  fi
  if ! grep -q "sites\['$host'\]" "$dest" 2>/dev/null; then
    as_root tee -a "$dest" >/dev/null <<EOF
\$sites['$host'] = '$product';
EOF
  fi
  run_root chown "$OWNER:$GROUP" "$dest"
}

ensure_local_php() {
  dest=$1
  dsn=$2
  hostpat=$3
  role=$4
  if [ -f "$dest" ]; then
    echo "settings.local.php exists: $dest (not overwritten)"
    return 0
  fi
  pre="FALSE"
  if [ "$role" = live ]; then
    pre="TRUE"
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  as_root tee "$dest" >/dev/null <<EOF
<?php
\$database = '$dsn';
\$settings['trusted_host_patterns'] = array('$hostpat');
\$config['system.core']['preprocess_css'] = $pre;
\$config['system.core']['preprocess_js']  = $pre;
EOF
  run_root chown "$OWNER:$GROUP" "$dest"
  run_root chmod 0640 "$dest"
}

ensure_db() {
  db=$1
  user=$2
  pass=$3
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ mysql CREATE DATABASE $db / USER $user@localhost"
    return 0
  fi
  cnf=$(secret_file "$platform" "$product").cnf
  if [ ! -f "$cnf" ]; then
    echo "$PROG: missing $cnf — write_secret first" >&2
    return 1
  fi
  priv mysql-create "$db" "$user" "$cnf"
}

ensure_vhost() {
  platform=$1
  host=$2
  web=$3
  root=$4
  role=$5
  conf=/etc/apache2/sites-available/${platform}-${role}.conf
  if [ ! -d /etc/apache2/sites-available ]; then
    note "no /etc/apache2/sites-available — write the vhost by hand"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ vhost $conf ServerName/Alias $host DocumentRoot $web"
    return 0
  fi
  if [ ! -f "$conf" ]; then
    as_root tee "$conf" >/dev/null <<EOF
<VirtualHost *:80>
  ServerName $host
  DocumentRoot $web
  <Directory $web>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  <Directory $root/config>
    Require all denied
  </Directory>
  <Directory $root/files_private>
    Require all denied
  </Directory>
</VirtualHost>
EOF
  else
    if ! grep -q "$host" "$conf"; then
      as_root sed -i "s/^\\([[:space:]]*ServerName .*\\)/\\1\\n    ServerAlias $host/" "$conf"
    fi
  fi
  if have a2ensite; then
    run_root a2ensite "${platform}-${role}.conf" >/dev/null 2>&1 || true
  fi
  run_root sh -c "$APACHE_RELOAD" || true
}

cmd_site_add() {
  platform=${1:-}
  product=${2:-}
  shift 2 2>/dev/null || true
  host=""
  title=""
  pass=""
  while [ $# -gt 0 ]; do
    case $1 in
      --host) host=$2; shift 2 ;;
      --name) title=$2; shift 2 ;;
      --pass) pass=$2; shift 2 ;;
      *) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
    esac
  done

  resolve_site "$platform" "$product"

  role=$STARDUST_ROLE
  if [ -z "$host" ]; then
    host="${product}.${role}"
  fi
  if [ -z "$title" ]; then
    title="$product $role"
  fi
  db=$(db_name "$product" "$role")
  user=$(printf '%s' "$db" | cut -c1-32)
  if [ -z "$pass" ]; then
    existing=$(read_secret_pass "$platform" "$product" || true)
    if [ -n "$existing" ]; then
      pass=$existing
      write_secret "$platform" "$product" "$user" "$pass" "$db"
      echo "db pass from $SECRETDIR/$platform/$product"
    else
      pass=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
      write_secret "$platform" "$product" "$user" "$pass" "$db"
      echo "db pass written to $(secret_file "$platform" "$product") (not printed)"
    fi
  else
    write_secret "$platform" "$product" "$user" "$pass" "$db"
  fi

  hostpat=$(printf '%s' "$host" | sed 's/\./\\\\./g')
  hostpat="^${hostpat}$"
  dsn="mysql://${user}:${pass}@localhost/${db}"

  cr=$(need_crdir)
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ $cr -s -o $DAEMON -g $GROUP $root/files/$product $root/files_private/$product $root/config/$product/active"
    echo "+ $cr -o $OWNER -g $GROUP $root/config/$product/staging"
  else
    # crdir calls sudo itself; run as the operator, not deploy
    "$cr" -s -o "$DAEMON" -g "$GROUP" \
      "$root/files/$product" \
      "$root/files_private/$product" \
      "$root/config/$product/active"
    "$cr" -o "$OWNER" -g "$GROUP" \
      "$root/config/$product/staging"
  fi

  ensure_settings_php "$root" "$product"
  ensure_sites_php "$web" "$host" "$product"
  ensure_local_php "$web/sites/$product/settings.local.php" "$dsn" "$hostpat" "$role"
  ensure_db "$db" "$user" "$pass"

  bee=$(bee_bin)
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ $bee --root=$web --site=$product install --db-name=$db --db-user=$user --auto"
  else
    if [ -f "$web/sites/$product/.stardust-installed" ]; then
      echo "bee install already marked for $product — skip"
    else
      as_root -u "$OWNER" "$bee" --root="$web" --site="$product" install \
        --db-name="$db" --db-user="$user" --db-pass="$pass" \
        --site-name="$title" --auto || true
      as_root touch "$web/sites/$product/.stardust-installed"
      run_root chown "$OWNER:$GROUP" "$web/sites/$product/.stardust-installed"
    fi
  fi

  ensure_vhost "$platform" "$host" "$web" "$root" "$role"
  echo "site $product on $platform -> http://$host  db=$db"
}

cmd_site_delete() {
  force=0
  while [ $# -gt 0 ]; do
    case $1 in
      --force) force=1; shift ;;
      *) break ;;
    esac
  done
  resolve_site "${1:-}" "${2:-}"
  if [ "$STARDUST_ROLE" = live ] && [ "$force" -ne 1 ]; then
    echo "$PROG: refuse site-delete on live without --force" >&2
    exit 2
  fi
  echo "delete $platform/$product"
  cmd_site_backup "$platform" "$product" || {
    echo "$PROG: backup failed — delete aborted" >&2
    exit 1
  }
  db=$(db_name "$product" "$STARDUST_ROLE")
  user=$(printf '%s' "$db" | cut -c1-32)
  dest=$(secret_file "$platform" "$product")
  if [ -f "$dest" ]; then
    db=$(sed -n 's/^db=//p' "$dest" | head -n 1)
    user=$(sed -n 's/^user=//p' "$dest" | head -n 1)
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ DROP DATABASE $db / USER $user"
    echo "+ rm files/config/sites for $product"
    return 0
  fi
  priv mysql-drop "$db" "$user" || {
    as_root mysql -e "DROP DATABASE IF EXISTS \`$db\`;" || true
    as_root mysql -e "DROP USER IF EXISTS '$user'@'localhost'; FLUSH PRIVILEGES;" || true
  }
  run_root rm -rf \
    "$root/files/$product" \
    "$root/files_private/$product" \
    "$root/config/$product" \
    "$web/sites/$product"
  if [ -f "$web/sites/sites.php" ]; then
    as_root sed -i "/sites\\['[^']*'\\] *= *'$product';/d" "$web/sites/sites.php" || true
  fi
  run_root rm -f "$dest"
  echo "deleted $platform/$product (platform left in place)"
}
