# shellcheck shell=sh

cmd_site_backup() {
  latest=0
  if [ "${3:-}" = "--latest" ]; then
    latest=1
  fi
  raw_plat=${1:-}
  raw_prod=${2:-}
  resolve_site "$raw_plat" "$raw_prod"
  if [ "$latest" -eq 1 ]; then
    platform=$(printf '%s' "$raw_plat" | tr '[:upper:]' '[:lower:]')
    product=$(printf '%s' "$raw_prod" | tr '[:upper:]' '[:lower:]')
    found=$(latest_backup "$platform" "$product" "${STARDUST_ROLE:-devel}" || true)
    if [ -z "$found" ]; then
      found=$(ls -1d /srv/stardust/backups/$platform/$product/*/20* 2>/dev/null | sort | tail -n 1)
    fi
    [ -n "$found" ] && echo "$found"
    return 0
  fi
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

  # Multi-site layout, then the single-site web/files this migrate left behind.
  if [ -d "$root/files/$product" ]; then
    echo "files $root/files/$product"
    tar -C "$root/files" -czf "$dest/files.tar.gz" "$product" 2>/dev/null || as_root tar -C "$root/files" -czf "$dest/files.tar.gz" "$product"
  elif [ -d "$web/files" ]; then
    echo "files $web/files"
    tar -C "$web/files" -czf "$dest/files.tar.gz" --transform "s|^|$product/|" . 2>/dev/null || as_root tar -C "$web/files" -czf "$dest/files.tar.gz" --transform "s|^|$product/|" .
  else
    echo "files none"
  fi
  if [ -d "$root/files_private/$product" ]; then
    echo "private $root/files_private/$product"
    tar -C "$root/files_private" -czf "$dest/files_private.tar.gz" "$product" 2>/dev/null || as_root tar -C "$root/files_private" -czf "$dest/files_private.tar.gz" "$product"
  elif [ -d "$web/files/private" ]; then
    echo "private $web/files/private"
    tar -C "$web/files" -czf "$dest/files_private.tar.gz" private 2>/dev/null || as_root tar -C "$web/files" -czf "$dest/files_private.tar.gz" private
  else
    echo "private none"
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
    echo "unpack files -> $root/files/$product"
    mkdir -p "$root/files"
    tar -C "$root/files" -xzf "$from/files.tar.gz" 2>/dev/null || as_root tar -C "$root/files" -xzf "$from/files.tar.gz"
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
