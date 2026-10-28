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


cmd_heal_all() {
  echo "heal all"
  found=0
  for p in "$PLATFORMS"/*; do
    [ -d "$p/web/sites" ] || continue
    name=${p##*/}
    case $name in .*) continue ;; esac
    for s in "$p/web/sites"/*; do
      [ -d "$s" ] || continue
      base=${s##*/}
      case $base in default|all) continue ;; esac
      if [ ! -f "$s/settings.php" ] && [ ! -f "$s/settings.local.php" ]; then
        continue
      fi
      found=1
      out=$(cmd_site_debug "$name" "$base" 2>&1) || true
      echo "$out" | grep -q "FAIL" || continue
      echo "== $name/$base"
      echo "$out" | grep "FAIL"
      cmd_site_heal "$name" "$base" || true
    done
  done
  if [ "$found" -eq 0 ]; then
    echo "(no sites)"
  fi
}

cmd_site_heal() {
  platform=${1:-}
  product=${2:-}
  platform=${platform#\'}; platform=${platform%\'}
  platform=${platform#\"}; platform=${platform%\"}
  product=${product#\'}; product=${product%\'}
  product=${product#\"}; product=${product%\"}
  resolve_site "$platform" "$product"
  host=$(guess_host "$product")
  echo "heal $platform/$product"; echo "settings"; echo "trusted host"
  echo "settings"
  echo "trusted host"
  echo "ownership"
  echo "apache reload"

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ rewrite settings paths"
    echo "+ chown files, private, config"
    echo "+ set trusted host"
    echo "+ reload apache"
    return 0
  fi

  # Group-writable. Do not sudo these. www-admin already owns the write.
  mkdir -p "$web/sites/$product" 2>/dev/null || true
  [ -f "$web/settings.php" ] && [ ! -f "$web/sites/$product/settings.php" ] && cp "$web/settings.php" "$web/sites/$product/settings.php" 2>/dev/null || true
  hostpat=$(printf '%s' "$host" | sed 's/[][\.*^$+?(){}|\/]/\\\\&/g')
  localphp=$web/sites/$product/settings.local.php
  # Do not sed an existing line. Append only when the line is missing.
  if [ -f "$localphp" ] && ! grep -q "trusted_host_patterns" "$localphp" 2>/dev/null; then
    printf '%s\n' "\$settings['trusted_host_patterns'] = array('^${hostpat}\$');" >> "$localphp" || true
  fi
  priv=${PRIV:-/usr/local/sbin/andromeda-priv}
  sudo -n "$priv" mkdir "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active" 2>/dev/null || true
  sudo -n "$priv" chown-files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true
  apache_reload || echo "apache: reload skipped"
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

# verify — Aegir-style: check configuration, rebuild vhosts, enforce permissions.
# Safe to run anytime. Does not mutate site content or DB.
cmd_verify() {
  target=${1:-}
  if [ -z "$target" ] || [ "$target" = "all" ]; then
    echo "verify all"
    for p in "$PLATFORMS"/*; do
      [ -d "$p/web" ] || continue
      name=${p##*/}
      case $name in .*) continue ;; esac
      cmd_verify_platform "$name" || true
    done
    return 0
  fi
  # site form: verify site PLATFORM PRODUCT
  if [ "$target" = "site" ]; then
    shift
    platform=${1:-}
    product=${2:-}
    if [ -z "$platform" ] || [ -z "$product" ]; then
      echo "usage: $PROG verify site PLATFORM PRODUCT" >&2
      exit 2
    fi
    cmd_verify_site "$platform" "$product"
    return
  fi
  # bare platform name
  cmd_verify_platform "$target"
}

cmd_verify_platform() {
  name=$1
  echo "== verify platform $name"
  dest=$PLATFORMS/$name
  if [ ! -d "$dest/web" ]; then
    echo "  missing web root"
    return 1
  fi
  # Enforce ownership on the platform tree (safe directories only).
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ chown -R $OWNER:$GROUP $dest"
  else
    run_root chown -R "$OWNER:$GROUP" "$dest" 2>/dev/null || true
  fi
  # Rebuild vhost for the current role (and any site that declares a host).
  web=$dest/web
  root=$dest
  role=${ANDROMEDA_ROLE:-devel}
  for s in "$web/sites"/*; do
    [ -d "$s" ] || continue
    base=${s##*/}
    case $base in default|all) continue ;; esac
    host=$(ANDROMEDA_ROLE=$role guess_host "$base" 2>/dev/null || printf '%s.%s' "$base" "$role")
    ensure_vhost "$name" "$host" "$web" "$root" "$role" || true
  done
  echo "  vhosts rebuilt (configtest gated)"
  # Per-site checks
  for s in "$dest/web/sites"/*; do
    [ -d "$s" ] || continue
    base=${s##*/}
    case $base in default|all) continue ;; esac
    if [ -f "$s/settings.php" ] || [ -f "$s/settings.local.php" ]; then
      cmd_verify_site "$name" "$base" || true
    fi
  done
}

cmd_verify_site() {
  platform=$1
  product=$2
  echo "  verify site $platform/$product"
  resolve_site "$platform" "$product" || return 1
  host=$(guess_host "$product")
  # Debug checks (read-only)
  cmd_site_debug "$platform" "$product" >/tmp/andromeda-verify.debug 2>&1 || true
  if grep -q FAIL /tmp/andromeda-verify.debug; then
    echo "  FAIL (see debug):"
    grep FAIL /tmp/andromeda-verify.debug | sed 's/^/    /'
  else
    echo "  checks ok"
  fi
  # Rebuild this site's vhost
  ensure_vhost "$platform" "$host" "$web" "$root" "$ANDROMEDA_ROLE" || true
  # Ownership on site dirs
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ crdir ownership $root/files/$product ..."
  else
    cr=$(need_crdir)
    "$cr" -s -o "$DAEMON" -g "$GROUP" \
      "$root/files/$product" \
      "$root/files_private/$product" \
      "$root/config/$product/active" 2>/dev/null || true
    "$cr" -o "$OWNER" -g "$GROUP" \
      "$root/config/$product/staging" 2>/dev/null || true
  fi
  echo "  permissions enforced"
}
