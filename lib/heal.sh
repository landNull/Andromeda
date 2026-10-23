# shellcheck shell=sh

# site-debug — print the common Backdrop / PHP failures.
# site-heal  — fix the ones that are safe to fix.

cmd_site_debug() {
  platform=${1:-}
  product=${2:-}
  if [ -z "$platform" ] || [ -z "$product" ]; then
    found=0
    for p in "$PLATFORMS"/*; do
      [ -d "$p/web/sites" ] || continue
      name=${p##*/}
      for s in "$p/web/sites"/*; do
        [ -d "$s" ] || continue
        base=${s##*/}
        case $base in default|all) continue ;; esac
        if [ -f "$s/settings.php" ] || [ -f "$s/settings.local.php" ]; then
          found=1
          echo "== $name/$base"
          cmd_site_debug "$name" "$base" || true
        fi
      done
    done
    if [ "$found" -eq 0 ]; then
      echo "(no sites to debug)"
    fi
    return 0
  fi
  resolve_site "$platform" "$product"
  host=$(guess_host "$product")
  echo "debug $platform/$product host=$host"

  _check_php
  _check_settings "$web" "$product" "$root"
  _check_dirs "$root" "$product"
  _check_db "$platform" "$product"
  _check_http "$host"
}

cmd_site_heal() {
  platform=${1:-}
  product=${2:-}
  resolve_site "$platform" "$product"
  host=$(guess_host "$product")
  echo "heal $platform/$product"

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ rewrite settings paths"
    echo "+ chown files, private, config"
    echo "+ set trusted host"
    echo "+ reload apache"
    return 0
  fi

  ensure_settings_php "$root" "$product"
  ensure_sites_php "$web" "$host" "$product"
  hostpat=$(printf '%s' "$host" | sed 's/\./\\\\./g')
  localphp=$web/sites/$product/settings.local.php
  if [ -f "$localphp" ]; then
    as_root sed -i "s/trusted_host_patterns.*/trusted_host_patterns'] = array('^${hostpat}$');/" "$localphp" || true
  fi
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true
  run_root chown -R "$OWNER:$GROUP" "$root/config/$product" 2>/dev/null || true
  run_root sh -c "$APACHE_RELOAD" 2>/dev/null || true
  echo "heal done $platform/$product"
}

_check_php() {
  if ! have php; then
    echo "FAIL  php not on PATH"
    return
  fi
  ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "?")
  echo "ok    php $ver"
  for ext in pdo_mysql gd mbstring xml; do
    if php -m 2>/dev/null | grep -qx "$ext"; then
      echo "ok    php-$ext"
    else
      echo "FAIL  php-$ext missing"
    fi
  done
}

_check_settings() {
  web=$1
  product=$2
  root=$3
  s=$web/sites/$product/settings.php
  l=$web/sites/$product/settings.local.php
  if [ ! -f "$s" ]; then
    echo "FAIL  missing $s"
  elif ! grep -q "config/$product/active" "$s" 2>/dev/null; then
    echo "FAIL  $s has no config/$product/active path"
  else
    echo "ok    settings.php paths"
  fi
  if [ ! -f "$l" ]; then
    echo "FAIL  missing $l"
  elif ! grep -q "trusted_host_patterns" "$l" 2>/dev/null; then
    echo "FAIL  $l has no trusted host"
  else
    echo "ok    settings.local.php"
  fi
}

_check_dirs() {
  root=$1
  product=$2
  for d in "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active"; do
    if [ ! -d "$d" ]; then
      echo "FAIL  missing $d"
    elif [ ! -w "$d" ]; then
      echo "FAIL  not writable $d"
    else
      echo "ok    $d"
    fi
  done
}

_check_db() {
  platform=$1
  product=$2
  cnf=$(secret_file "$platform" "$product").cnf
  if [ ! -f "$cnf" ]; then
    echo "FAIL  missing db secret $cnf"
    return
  fi
  if mysql --defaults-extra-file="$cnf" -e "SELECT 1" >/dev/null 2>&1; then
    echo "ok    db"
  else
    echo "FAIL  db connection"
  fi
}

_check_http() {
  host=$1
  if ! have curl; then
    echo "note  curl missing — skip HTTP"
    return
  fi
  code=$(curl -sS -L --max-time 15 -o /dev/null -w '%{http_code}' "http://$host/" || echo 000)
  case $code in
    200) echo "ok    HTTP $code" ;;
    500) echo "FAIL  HTTP 500 — settings, config, or db" ;;
    000) echo "FAIL  HTTP unreachable" ;;
    *)   echo "FAIL  HTTP $code" ;;
  esac
}
