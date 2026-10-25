# shellcheck shell=sh

# Pull a site from a VPS and stand it up as a devel site.
# usage: stardust site-pull VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]
cmd_site_pull() {
  role=${STARDUST_ROLE:-devel}
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; shift 2 ;;
      --) shift; break ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  vps=${1:-}
  src_p=${2:-}
  src_s=${3:-}
  dst_p=${4:-$src_p}
  dst_s=${5:-$src_s}
  if [ -z "$vps" ] || [ -z "$src_p" ] || [ -z "$src_s" ]; then
    echo "usage: $PROG site-pull [--role ROLE] VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]" >&2
    exit 2
  fi

  echo "pull $vps:$src_p/$src_s -> $dst_p/$dst_s ($role)"
  wg_up || return 1
  trap wg_down EXIT
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ ssh $vps stardust site-backup $src_p $src_s"
    echo "+ rsync snapshot"
    echo "+ platform-add $dst_p   (if missing)"
    echo "+ site-add $dst_p $dst_s"
    echo "+ restore files, private, config, db"
    return 0
  fi

  ssh "$vps" "stardust site-backup $src_p $src_s" || {
    echo "$PROG: remote backup failed" >&2
    exit 1
  }
  echo "remote  latest"
  remote=$(ssh "$vps" "stardust site-backup $src_p $src_s --latest" 2>/dev/null || true)
  remote=$(printf '%s\n' "$remote" | sed 's/\x1b\[[0-9;]*m//g' | grep '^/srv/stardust/backups/' | tail -n 1)
  if [ -z "$remote" ]; then
    echo "$PROG: remote snapshot path missing" >&2
    exit 1
  fi
  local_snap="$HOME/.stardust/pull/$src_p/$src_s"
  mkdir -p "$local_snap"
  rsync -a "$vps:$remote/" "$local_snap/" || {
    echo "$PROG: rsync failed" >&2
    exit 1
  }

  if [ ! -d "$PLATFORMS/$dst_p" ]; then
    echo "create platform $dst_p"
    cmd_platform_add "$dst_p" --no-prompt
  fi
  host="${dst_s}.${role}"
  STARDUST_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host"

  # Fill the devel site from the snapshot so Backdrop boots the pulled content.
  resolve_site "$dst_p" "$dst_s"
  _restore_snap "$local_snap" "$root" "$web" "$product" "$src_s" "$host"
  echo "pull done  http://$host"
}

_restore_snap() {
  snap=$1
  root=$2
  web=$3
  product=$4
  src_product=$5
  host=$6

  bee=$(bee_bin)
  dump="$snap/db.sql"
  if [ ! -s "$dump" ] && [ -s "$snap/db.sql.gz" ]; then
    dump="$snap/db.sql.gz"
  fi
  if [ -s "$dump" ]; then
    as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump"
  fi
  if [ -f "$snap/files.tar.gz" ]; then
    echo "unpack files -> $root/files/$product"
    mkdir -p "$root/files/$product"
    top=$(tar -tzf "$snap/files.tar.gz" | head -n 1 | cut -d/ -f1)
    if [ "$top" = "files" ]; then
      tar -C "$root/files/$product" -xzf "$snap/files.tar.gz" --strip-components=1
    elif [ "$top" = "$src_product" ] || [ "$top" = "$product" ]; then
      tar -C "$root/files" -xzf "$snap/files.tar.gz"
      if [ "$top" != "$product" ] && [ -d "$root/files/$top" ]; then
        rm -rf "$root/files/$product"
        mv "$root/files/$top" "$root/files/$product"
      fi
    else
      tar -C "$root/files/$product" -xzf "$snap/files.tar.gz"
    fi
    n=$(find "$root/files/$product" -type f | wc -l)
    echo "files  $n"
    if [ "$n" -eq 0 ]; then
      echo "$PROG: files archive unpacked empty" >&2
      return 1
    fi
    chown_files "$root/files/$product" 2>/dev/null || true
  else
    echo "files  none in snapshot"
  fi
  if [ -f "$snap/files_private.tar.gz" ]; then
    run_root mkdir -p "$root/files_private/$product"
    as_root tar -C "$root/files_private" -xzf "$snap/files_private.tar.gz"
    if [ "$src_product" != "$product" ] && [ -d "$root/files_private/$src_product" ]; then
      as_root mv "$root/files_private/$src_product" "$root/files_private/$product.tmp" 2>/dev/null || true
      as_root rm -rf "$root/files_private/$product"
      as_root mv "$root/files_private/$product.tmp" "$root/files_private/$product"
    fi
  fi
  if [ -f "$snap/config-active.tar.gz" ]; then
    run_root mkdir -p "$root/config/$product/active"
    as_root tar -C "$root/config/$product" -xzf "$snap/config-active.tar.gz"
    run_root chown -R "$OWNER:$GROUP" "$root/config/$product" 2>/dev/null || true
  fi
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true

  localphp=$web/sites/$product/settings.local.php
  hostpat=$(printf '%s' "$host" | sed 's/\./\\\\./g')
  if [ -f "$localphp" ]; then
    as_root sed -i "s/trusted_host_patterns.*/trusted_host_patterns'] = array('^${hostpat}$');/" "$localphp" || true
  fi
}
