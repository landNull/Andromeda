# shellcheck shell=sh
# Two distinct migrate paths:
#   migrate-www (or migrate www) — interactive move of a standalone Backdrop
#     docroot from /var/www into a new platform under $PLATFORMS (/srv/platforms).
#     This is the only command that reads /var/www.
#   migrate site SRC DEST — move a site that already lives under $PLATFORMS
#     from one platform to another. Never touches /var/www.
# The docroot from migrate-www lands at /srv/platforms/<name>/web.

is_docroot() {
  d=$1
  [ -f "$d/index.php" ] || return 1
  [ -d "$d/core" ] || [ -f "$d/settings.php" ] || return 1
  return 0
}



_write_default_vhost() {
  plat=$1
  web=$2
  def=/etc/apache2/sites-available/000-default.conf
  [ -f "$def" ] || return 0
  echo "fix   000-default.conf -> $web"
  sudo tee "$def" >/dev/null << EOF
<VirtualHost *:80>
  ServerName ${plat}.live
  DocumentRoot $web
  <Directory $web>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  <Directory $PLATFORMS/$plat/config>
    Require all denied
  </Directory>
  <Directory $PLATFORMS/$plat/files_private>
    Require all denied
  </Directory>
</VirtualHost>
EOF
  sudo a2ensite 000-default.conf >/dev/null 2>&1 || true
}


_map_site() {
  web=$1
  host=$2
  product=$3
  dest=$web/sites/sites.php
  sudo mkdir -p "$web/sites/$product"
  if [ ! -f "$dest" ]; then
    echo "<?php" | sudo tee "$dest" >/dev/null
  fi
  if ! grep -q "sites\['$host'\]" "$dest" 2>/dev/null; then
    echo "map   $host -> $product"
    echo "\$sites['$host'] = '$product';" | sudo tee -a "$dest" >/dev/null
  else
    echo "map   $host already set"
  fi
  # Single-site installs keep settings.php at the web root. Copy it into the product
  # so the host map has a folder to land on.
  if [ -f "$web/settings.php" ] && [ ! -f "$web/sites/$product/settings.php" ]; then
    echo "copy  settings.php -> sites/$product/"
    sudo cp "$web/settings.php" "$web/sites/$product/settings.php"
  fi
  localphp=$web/sites/$product/settings.local.php
  if [ ! -f "$localphp" ]; then
    hostpat=$(printf '%s' "$host" | sed 's/\./\\\\./g')
    echo "write trusted host in settings.local.php"
    sudo tee "$localphp" >/dev/null << EOF
<?php
\$settings['trusted_host_patterns'] = array('^${hostpat}$');
EOF
  fi
}


_ensure_apache_mysql() {
  # CLI php and Apache php are different. Bee can pass while the site 500s.
  if ! command -v phpenmod >/dev/null 2>&1; then
    echo "note  no phpenmod, skip apache php check"
    return 0
  fi
  echo "php   enable pdo_mysql for apache"
  sudo phpenmod -s apache2 pdo_mysql 2>/dev/null || true
  sudo phpenmod -s fpm pdo_mysql 2>/dev/null || true
  sudo phpenmod -s apache2 mysqli 2>/dev/null || true
}

cmd_migrate_heal() {
  plat=${1:-}
  if [ -n "$plat" ]; then
    _scan_one "$(slug "$plat")"
    return 0
  fi
  found=0
  for p in "$PLATFORMS"/*; do
    [ -d "$p/web" ] || continue
    found=1
    _scan_one "${p##*/}"
  done
  [ "$found" -eq 1 ] || echo "(no platforms)"
}

_scan_one() {
  plat=$1
  web=$PLATFORMS/$plat/web
  mark=/srv/andromeda/state/migrate/$plat
  echo "== $plat"
  if [ ! -f "$mark" ]; then
    echo "skip  no $mark  (not a migrated platform)"
    return 0
  fi

  if [ -f "$web/index.php" ] && [ -d "$web/core" ]; then
    echo "ok    docroot $web"
  else
    echo "fail  docroot missing  $web"
  fi

  if [ -f "$web/sites/sites.php" ]; then
    echo "ok    sites.php"
  else
    echo "fail  sites.php missing"
  fi

  for s in "$web/sites"/*; do
    [ -d "$s" ] || continue
    base=${s##*/}
    case $base in default|all) continue ;; esac
    if [ -f "$s/settings.php" ]; then
      echo "ok    $base settings.php"
    else
      echo "fail  $base settings.php missing"
    fi
    if [ -f "$s/settings.local.php" ]; then
      echo "ok    $base settings.local.php"
    else
      echo "fail  $base settings.local.php missing"
    fi
  done

  def=/etc/apache2/sites-available/000-default.conf
  if [ -f "$def" ] && grep -q "/var/www" "$def" 2>/dev/null; then
    echo "fail  000-default.conf still /var/www"
  else
    echo "ok    000-default.conf"
  fi

  if [ -f /etc/php/8.4/apache2/conf.d/20-pdo_mysql.ini ]; then
    echo "ok    apache pdo_mysql"
  else
    echo "fail  apache pdo_mysql missing"
  fi
  echo "scan  $plat"
}


_convert_standalone() {
  dest=$1
  web=$2
  product=$3
  # Move hashed config out of files/ into the platform config store.
  hashed=$(find "$web/files" -maxdepth 1 -type d -name "config_*" 2>/dev/null | head -n 1)
  if [ -n "$hashed" ] && [ -d "$hashed/active" ]; then
    echo "move  $hashed -> $dest/config/$product"
    sudo mkdir -p "$dest/config/$product"
    sudo cp -a "$hashed/active" "$dest/config/$product/active"
    [ -d "$hashed/staging" ] && sudo cp -a "$hashed/staging" "$dest/config/$product/staging"
    sudo mkdir -p "$dest/config/$product/staging"
    sudo chown -R "$OWNER:$GROUP" "$dest/config/$product" 2>/dev/null || true
  fi
  # Custom modules/themes/layouts stay in the platform web tree. A standalone
  # site already has them there. Nothing to move.
  # Point settings at the platform config store. Absolute, so multi-site depth
  # does not matter.
  localphp="$web/sites/$product/settings.local.php"
  sudo mkdir -p "$web/sites/$product"
  if [ -f "$localphp" ] && grep -q "config_directories" "$localphp"; then
    sudo sed -i "s|config_directories\['active'\].*|config_directories['active']  = '$dest/config/$product/active';|" "$localphp" || true
    sudo sed -i "s|config_directories\['staging'\].*|config_directories['staging'] = '$dest/config/$product/staging';|" "$localphp" || true
  else
    if [ ! -f "$localphp" ]; then
      printf "%s\n" "<?php" "\$config_directories['active']  = '$dest/config/$product/active';" "\$config_directories['staging'] = '$dest/config/$product/staging';" | sudo tee "$localphp" >/dev/null
    else
      printf "%s\n" "\$config_directories['active']  = '$dest/config/$product/active';" "\$config_directories['staging'] = '$dest/config/$product/staging';" | sudo tee -a "$localphp" >/dev/null
    fi
  fi
  echo "config $dest/config/$product/active"
}

cmd_migrate_www() {
  src_root=${WWW_ROOT:-/var/www}
  if [ ! -d "$src_root" ]; then
    echo "$PROG: $src_root is not a directory" >&2
    exit 2
  fi

  echo "docroots in $src_root"
  i=0
  list=""
  for d in "$src_root"/*; do
    [ -d "$d" ] || continue
    base=${d##*/}
    case $base in html|default) continue ;; esac
    is_docroot "$d" || continue
    i=$((i + 1))
    list="$list $i:$base"
    echo "  $i) $base"
  done
  if [ "$i" -eq 0 ]; then
    echo "$PROG: no Backdrop docroot in $src_root" >&2
    exit 1
  fi

  printf "number: "
  read -r pick
  src=""
  for item in $list; do
    n=${item%%:*}
    name=${item#*:}
    if [ "$n" = "$pick" ]; then
      src=$src_root/$name
      break
    fi
  done
  if [ -z "$src" ]; then
    echo "$PROG: no such number" >&2
    exit 2
  fi

  printf "new platform name: "
  read -r plat
  plat=$(slug "$plat")
  if [ -z "$plat" ]; then
    echo "$PROG: platform name required" >&2
    exit 2
  fi

  # Site directory under web/sites/. Default is the source folder name.
  # Example: /var/www/kl_test -> keslerlumber.test
  srcbase=${src##*/}
  printf "site directory name [%s]: " "$srcbase"
  read -r product
  product=${product:-$srcbase}
  product=$(slug "$product")
  if [ -z "$product" ]; then
    echo "$PROG: site directory name required" >&2
    exit 2
  fi
  echo "site   $product"

  dest=$PLATFORMS/$plat
  web=$dest/web
  echo "migrate $src -> $web"
  printf "sudo to copy? [y/N] "
  read -r ok
  [ "$ok" = "y" ] || { echo "stopped"; return 0; }

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ platform-add $plat"
    echo "+ cp -a $src/. $web/"
    echo "+ chown $OWNER:$GROUP $dest"
    return 0
  fi

  if [ ! -d "$dest" ]; then
    cmd_platform_add "$plat" --no-prompt || true
  fi
  sudo mkdir -p "$web"
  sudo cp -a "$src"/. "$web"/
  # code is deploy:www-admin. files are www-data:www-admin. ACL rides on both.
  chown_code "$web" || sudo chown -R "$OWNER:$GROUP" "$web"
  [ -d "$dest/files" ] && chown_files "$dest/files" || true
  [ -d "$dest/files_private" ] && chown_files "$dest/files_private" || true

  # Standalone installs keep config under files/config_HASH and modules in
  # the docroot. Move both into the platform store so the site matches a
  # native Andromeda site.
  _convert_standalone "$dest" "$web" "$product"

  echo "platform $plat"
  echo "web root  $web"

  avail=/etc/apache2/sites-available
  if [ ! -d "$avail" ]; then
    echo "no $avail"
    return 0
  fi
  echo "apache configs"
  j=0
  alist=""
  for c in "$avail"/*.conf; do
    [ -f "$c" ] || continue
    j=$((j + 1))
    base=${c##*/}
    alist="$alist $j:$base"
    echo "  $j) $base"
  done
  if [ "$j" -eq 0 ]; then
    echo "no vhost to update"
    return 0
  fi
  printf "vhost number: "
  read -r vp
  conf=""
  for item in $alist; do
    n=${item%%:*}
    name=${item#*:}
    if [ "$n" = "$vp" ]; then
      conf=$avail/$name
      break
    fi
  done
  if [ -z "$conf" ]; then
    echo "no such vhost"
    return 0
  fi

  printf "ServerName [$product]: "
  read -r host
  host=${host:-$product}

  echo "edit $conf"
  sudo sed -i "s|DocumentRoot .*|DocumentRoot $web|" "$conf"
  if grep -q "^[[:space:]]*ServerName" "$conf"; then
    sudo sed -i "s|^[[:space:]]*ServerName .*|  ServerName $host|" "$conf"
  else
    sudo sed -i "/<VirtualHost/a\  ServerName $host" "$conf"
  fi
  sudo a2ensite "${conf##*/}" >/dev/null 2>&1 || true
  _ensure_apache_mysql
  echo "reload apache"
  if apache_reload; then
    reloaded=1
  else
    reloaded=0
  fi

  _map_site "$web" "$host" "$product"
  _write_default_vhost "$plat" "$web"
  mkdir -p /srv/andromeda/state/migrate
  : > /srv/andromeda/state/migrate/$plat
  _migrate_report "$plat" "$web" "$host" "$conf" "$reloaded"
}

_ok() { printf '  \033[32m✔\033[0m  %s\n' "$1"; }
_bad() { printf '  \033[31m✘\033[0m  %s\n' "$1"; printf '      %s\n' "$2"; }

_migrate_report() {
  plat=$1
  web=$2
  host=$3
  conf=$4
  reloaded=$5
  fail=0

  echo
  echo "  migrate $plat"
  echo "  ----------------------------------------"

  if [ -f "$web/index.php" ] && { [ -d "$web/core" ] || [ -f "$web/settings.php" ]; }; then
    _ok "Backdrop docroot at $web"
  else
    _bad "Backdrop docroot missing" "no index.php and core under $web"
    fail=1
  fi

  if grep -q "DocumentRoot $web" "$conf" 2>/dev/null; then
    _ok "vhost DocumentRoot is $web"
  else
    _bad "vhost still points elsewhere" "DocumentRoot in $conf is not $web"
    fail=1
  fi

  old=$(grep -l "/var/www" /etc/apache2/sites-available/*.conf 2>/dev/null || true)
  if [ -z "$old" ]; then
    _ok "no vhost still uses /var/www"
  else
    _bad "a vhost still uses /var/www" "$old"
    fail=1
  fi

  if [ "$reloaded" -eq 1 ]; then
    _ok "apache restarted"
  else
    _bad "apache restart failed" "sudo service apache2 restart returned non-zero"
    fail=1
  fi
  if [ -f /etc/php/8.4/apache2/conf.d/20-pdo_mysql.ini ] || [ -f /etc/php/*/apache2/conf.d/20-pdo_mysql.ini ]; then
    _ok "apache php has pdo_mysql"
  else
    _bad "apache php missing pdo_mysql" "CLI can have it while Apache does not. phpenmod -s apache2 pdo_mysql"
    fail=1
  fi

  code=$(curl -sS -L --max-time 15 -o /dev/null -w '%{http_code}' "http://$host/" || echo 000)
  case $code in
    200|301|302)
      _ok "curl http://$host/ -> $code"
      ;;
    521|522|523)
      _bad "curl http://$host/ -> $code" "Cloudflare cannot reach origin. Tunnel or apache."
      fail=1
      ;;
    000)
      _bad "curl http://$host/ -> unreachable" "no answer. Host not in DNS, or apache down."
      fail=1
      ;;
    *)
      _bad "curl http://$host/ -> $code" "not a clean answer. Check the vhost and the site."
      fail=1
      ;;
  esac

  echo "  ----------------------------------------"
  if [ "$fail" -eq 0 ]; then
    printf '  \033[32m✔ done\033[0m  %s is on %s\n' "$plat" "$web"
  else
    printf '  \033[31m✘ done with failures\033[0m  see the lines above\n'
  fi
  echo
}

# migrate site — move a site between platforms under $PLATFORMS (/srv/platforms).
# Does not touch /var/www. That path is migrate-www only.
#
# Default is a true move: the source site is deleted after the destination
# is confirmed. Pass --keep to leave the source in place (copy).
cmd_site_migrate() {
  keep=0
  host=""
  pass=""
  while [ $# -gt 0 ]; do
    case $1 in
      --keep) keep=1; shift ;;
      --host) host=$2; shift 2 ;;
      --pass) pass=$2; shift 2 ;;
      --) shift; break ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done

  src_p=${1:-}
  src_s=${2:-}
  dst_p=${3:-}
  dst_s=${4:-}
  if [ -z "$src_p" ] || [ -z "$src_s" ] || [ -z "$dst_p" ] || [ -z "$dst_s" ]; then
    echo "usage: $PROG migrate site SRC_PLATFORM SRC_PRODUCT DEST_PLATFORM DEST_PRODUCT [--host HOST] [--keep]" >&2
    echo "  both platforms must already exist under $PLATFORMS" >&2
    exit 2
  fi

  # Both ends must resolve under $PLATFORMS. resolve_site exits if not.
  resolve_site "$src_p" "$src_s"
  src_root=$root
  src_web=$web
  src_platform=$platform
  src_product=$product

  # Destination platform must exist (we do not create it).
  if [ ! -d "$PLATFORMS/$dst_p" ]; then
    echo "$PROG: destination platform $dst_p does not exist under $PLATFORMS" >&2
    echo "$PROG: add platform $dst_p first" >&2
    exit 1
  fi

  if [ "$src_platform" = "$dst_p" ] && [ "$src_product" = "$dst_s" ]; then
    echo "$PROG: source and destination are the same site" >&2
    exit 2
  fi

  echo "migrate $src_platform/$src_product -> $dst_p/$dst_s"
  if [ "$keep" -eq 1 ]; then
    echo "  --keep: source will remain"
  else
    echo "  source will be deleted after destination is ready"
  fi

  # Reuse the clone path (backup + add + restore). It already constrains
  # both ends to $PLATFORMS via resolve_site.
  clone_args="$src_platform $src_product $dst_p $dst_s"
  if [ -n "$host" ]; then
    clone_args="$clone_args --host $host"
  fi
  if [ -n "$pass" ]; then
    clone_args="$clone_args --pass $pass"
  fi
  # shellcheck disable=SC2086
  cmd_site_clone $clone_args || {
    echo "$PROG: clone step failed — source left untouched" >&2
    exit 1
  }

  if [ "$keep" -eq 1 ]; then
    echo "migrated (kept source) $src_platform/$src_product -> $dst_p/$dst_s"
    return 0
  fi

  # True move: remove the source site. site-delete refuses on live without --force.
  echo "removing source $src_platform/$src_product"
  if [ "$ANDROMEDA_ROLE" = live ]; then
    cmd_site_delete --force "$src_platform" "$src_product" || {
      echo "$PROG: destination is ready but source delete failed — run delete site manually" >&2
      return 1
    }
  else
    cmd_site_delete "$src_platform" "$src_product" || {
      echo "$PROG: destination is ready but source delete failed — run delete site manually" >&2
      return 1
    }
  fi
  echo "migrated $src_platform/$src_product -> $dst_p/$dst_s"
}
