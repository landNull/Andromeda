# shellcheck shell=sh
# Migrate a full Backdrop docroot from /var/www into a Stardust platform.
# The docroot lands at /srv/platforms/<name>/web, not under web/sites.

is_docroot() {
  d=$1
  [ -f "$d/index.php" ] || return 1
  [ -d "$d/core" ] || [ -f "$d/settings.php" ] || return 1
  return 0
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
  sudo chown -R "$OWNER:$GROUP" "$dest"

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

  printf "ServerName [$plat.live]: "
  read -r host
  host=${host:-$plat.live}

  echo "edit $conf"
  sudo sed -i "s|DocumentRoot .*|DocumentRoot $web|" "$conf"
  if grep -q "^[[:space:]]*ServerName" "$conf"; then
    sudo sed -i "s|^[[:space:]]*ServerName .*|  ServerName $host|" "$conf"
  else
    sudo sed -i "/<VirtualHost/a\  ServerName $host" "$conf"
  fi
  sudo a2ensite "${conf##*/}" >/dev/null 2>&1 || true
  echo "reload apache"
  if sudo service apache2 reload; then
    reloaded=1
  else
    reloaded=0
  fi

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
    _ok "apache reloaded"
  else
    _bad "apache reload failed" "sudo service apache2 reload returned non-zero"
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
