# shellcheck shell=sh

cmd_site_backup() {
  raw_plat=${1:-}
  raw_prod=${2:-}
  resolve_site "$raw_plat" "$raw_prod"
  # Keep underscores. slug used to turn kl_test into kl-test, and Bee
  # then missed the sites.php line.
  platform=$(printf '%s' "$raw_plat" | tr '[:upper:]' '[:lower:]')
  product=$(printf '%s' "$raw_prod" | tr '[:upper:]' '[:lower:]')
  root=$PLATFORMS/$platform
  web=$root/web
  role=$STARDUST_ROLE
  dest=$(backup_dir "$platform" "$product" "$role")/$(stamp)
  bee=$(bee_bin)

  run_root mkdir -p "$dest"
  run_root chown "$OWNER:$GROUP" "$(backup_dir "$platform" "$product" "$role")" "$dest" 2>/dev/null || true

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ $bee --root=$web --site=$product db-export $dest/db.sql"
    echo "+ tar files/ files_private/ config/active -> $dest"
    return 0
  fi

  as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-export "$dest/db.sql"
  # Bee may gzip even when asked for .sql
  if [ ! -s "$dest/db.sql" ] && [ -s "$dest/db.sql.gz" ]; then
    echo "note: Bee wrote db.sql.gz"
  elif [ ! -s "$dest/db.sql" ]; then
    echo "$PROG: db-export produced no $dest/db.sql" >&2
    return 1
  fi

  if [ -d "$root/files/$product" ]; then
    as_root tar -C "$root/files" -czf "$dest/files.tar.gz" "$product"
  fi
  if [ -d "$root/files_private/$product" ]; then
    as_root tar -C "$root/files_private" -czf "$dest/files_private.tar.gz" "$product"
  fi
  if [ -d "$root/config/$product/active" ]; then
    as_root tar -C "$root/config/$product" -czf "$dest/config-active.tar.gz" active
  fi

  as_root sh -c "cat > '$dest/MANIFEST'" <<EOF
platform=$platform
product=$product
role=$role
web=$web
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  run_root chown -R "$OWNER:$GROUP" "$dest"
  echo "backup $dest"
}

latest_backup() {
  platform=$1
  product=$2
  role=$3
  base=$(backup_dir "$platform" "$product" "$role")
  if [ ! -d "$base" ]; then
    return 1
  fi
  # newest stamp dir that has db.sql or db.sql.gz
  ls -1d "$base"/20* 2>/dev/null | sort | tail -n 1
}

cmd_site_restore() {
  from=""
  case ${1:-} in
    --from)
      from=$2
      shift 2
      ;;
  esac
  resolve_site "${1:-}" "${2:-}"
  role=$STARDUST_ROLE

  if [ -z "$from" ]; then
    from=$(latest_backup "$platform" "$product" "$role" || true)
  fi
  if [ -z "$from" ] || [ ! -d "$from" ]; then
    echo "$PROG: no backup found. Pass --from DIR or run site-backup first." >&2
    exit 1
  fi
  dump="$from/db.sql"
  if [ ! -s "$dump" ] && [ -s "$from/db.sql.gz" ]; then
    dump="$from/db.sql.gz"
  fi
  if [ ! -s "$dump" ]; then
    echo "$PROG: $from/db.sql missing" >&2
    exit 1
  fi

  bee=$(bee_bin)
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ restore $from -> $root product=$product"
    echo "+ $bee --root=$web --site=$product db-import $dump"
    return 0
  fi

  as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump"

  cr=$(need_crdir)
  # crdir calls sudo itself; run as the operator, not deploy
  "$cr" -s -o "$OWNER" -g "$GROUP" \
    "$root/files/$product" \
    "$root/files_private/$product" \
    "$root/config/$product/active"

  if [ -f "$from/files.tar.gz" ]; then
    as_root tar -C "$root/files" -xzf "$from/files.tar.gz"
  fi
  if [ -f "$from/files_private.tar.gz" ]; then
    as_root tar -C "$root/files_private" -xzf "$from/files_private.tar.gz"
  fi
  if [ -f "$from/config-active.tar.gz" ]; then
    as_root tar -C "$root/config/$product" -xzf "$from/config-active.tar.gz"
  fi
  chown_files \
    "$root/files/$product" \
    "$root/files_private/$product" \
    "$root/config/$product/active" 2>/dev/null || true
  echo "restore $from -> $platform/$product"
}
