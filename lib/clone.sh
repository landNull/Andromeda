# shellcheck shell=sh

cmd_site_clone() {
  host=""
  pass=""
  while [ $# -gt 0 ]; do
    case $1 in
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
    echo "usage: $PROG site-clone SRC_PLATFORM SRC_PRODUCT DEST_PLATFORM DEST_PRODUCT [--host HOST]" >&2
    exit 2
  fi

  resolve_site "$src_p" "$src_s"
  src_root=$root
  src_web=$web
  src_platform=$platform
  src_product=$product

  echo "clone $src_platform/$src_product -> $dst_p/$dst_s"
  cmd_site_backup "$src_platform" "$src_product" || {
    echo "$PROG: source backup failed — clone aborted" >&2
    exit 1
  }
  snap=$(latest_backup "$src_platform" "$src_product" "$STARDUST_ROLE" || true)
  if [ -z "$snap" ]; then
    echo "$PROG: backup dir missing after site-backup" >&2
    exit 1
  fi

  if [ -z "$host" ]; then
    host="${dst_s}.${STARDUST_ROLE}"
  fi

  addargs="$dst_p $dst_s --host $host"
  if [ -n "$pass" ]; then
    addargs="$addargs --pass $pass"
  fi
  # shellcheck disable=SC2086
  cmd_site_add $addargs

  # restore files+db onto dest (overwrites empty bee install DB)
  cmd=${cmd:-site-clone}
  resolve_site "$dst_p" "$dst_s"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ restore $snap into $root product=$product"
    return 0
  fi

  bee=$(bee_bin)
  dump="$snap/db.sql"
  if [ ! -s "$dump" ] && [ -s "$snap/db.sql.gz" ]; then
    dump="$snap/db.sql.gz"
  fi
  as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump"
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
  # Backdrop boots from the active config directory, not only the DB.
  # Without this the preview has a fresh empty config and returns 500.
  if [ -f "$snap/config-active.tar.gz" ]; then
    run_root mkdir -p "$root/config/$product"
    as_root tar -C "$root/config/$product" -xzf "$snap/config-active.tar.gz"
    run_root chown -R "$OWNER:$GROUP" "$root/config/$product" 2>/dev/null || true
  fi
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true

  localphp=$web/sites/$product/settings.local.php
  hostpat=$(printf '%s' "$host" | sed 's/\./\\\\./g')
  if [ -f "$localphp" ]; then
    as_root sed -i "s/trusted_host_patterns.*/trusted_host_patterns'] = array('^${hostpat}$');/" "$localphp" || true
  fi
  echo "clone done  http://$host"
}
