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
  # @host:plat/site -> @host:plat/site
  if [ "${2:-}" = "->" ] && printf '%s' "${1:-}" | grep -q '^@'; then
    left=${1#@}
    right=${3#@}
    vps=${left%%:*}
    src_p=${left#*:}; src_p=${src_p%%/*}
    src_s=${left##*/}
    dst_p=${right#*:}; dst_p=${dst_p%%/*}
    dst_s=${right##*/}
  else
    vps=${1:-}
    src_p=${2:-}
    src_s=${3:-}
    dst_p=${4:-$src_p}
    dst_s=${5:-$src_s}
  fi
  if [ -z "$vps" ] || [ -z "$src_p" ] || [ -z "$src_s" ]; then
    echo "usage: $PROG site pull @host:plat/site -> @host:plat/site" >&2
    echo "   or: $PROG site-pull [--role ROLE] VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]" >&2
    exit 2
  fi

  src_path="/srv/platforms/$src_p/web/sites/$src_s"
  dst_path="/srv/platforms/$dst_p/web/sites/$dst_s"
  echo "pull @$vps:$src_p/$src_s -> @$dst_p/$dst_s ($role)"
  echo "from $src_path  on $vps"
  echo "to   $dst_path"
  echo "tunnel  up"
  wg_up || return 1
  trap wg_down EXIT
  echo "tunnel  $vps"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ ssh $vps stardust site-backup $src_p $src_s"
    echo "+ rsync snapshot"
    echo "+ platform-add $dst_p   (if missing)"
    echo "+ site-add $dst_p $dst_s"
    echo "+ restore files, private, config, db"
    return 0
  fi

  echo "remote  backup $src_p/$src_s"
  ssh "$vps" "stardust site-backup $src_p $src_s" || {
    echo "$PROG: remote backup failed" >&2
    exit 1
  }
  remote=$(ssh "$vps" "stardust site-backup $src_p $src_s --latest" 2>/dev/null || true)
  if [ -z "$remote" ]; then
    echo "$PROG: remote snapshot path missing" >&2
    exit 1
  fi
  local_snap="$HOME/.stardust/pull/$src_p/$src_s"
  mkdir -p "$local_snap"
  echo "rsync   $remote"
  echo "local   $local_snap"
  rsync -a --info=stats2 "$vps:$remote/" "$local_snap/" || {
    echo "$PROG: rsync failed" >&2
    exit 1
  }

  if [ ! -d "$PLATFORMS/$dst_p" ]; then
    echo "create platform $dst_p"
    cmd_platform_add "$dst_p" --no-prompt
  fi
  host="${dst_s}.${role}"
  echo "site    $dst_p/$dst_s host=$host"
  STARDUST_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host"
  echo "restore files, private, config, db"

  # Fill the devel site from the snapshot so Backdrop boots the pulled content.
  resolve_site "$dst_p" "$dst_s"
  _restore_snap "$local_snap" "$root" "$web" "$product" "$src_s" "$host"
  echo "tunnel  down"
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
    run_root mkdir -p "$root/files/$product"
    as_root tar -C "$root/files" -xzf "$snap/files.tar.gz"
    if [ "$src_product" != "$product" ] && [ -d "$root/files/$src_product" ]; then
      as_root mv "$root/files/$src_product" "$root/files/$product.tmp" 2>/dev/null || true
      as_root rm -rf "$root/files/$product"
      as_root mv "$root/files/$product.tmp" "$root/files/$product"
    fi
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
