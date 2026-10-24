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
  if [ -d "$web/sites/default" ]; then
    echo "site      sites/default is still default"
    echo "rename:   stardust site add $plat PRODUCT"
  fi
  echo "check:    bee --root=$web status"
}
