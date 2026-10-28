# shellcheck shell=sh

# pull-rsync — internal helper. Called by cmd_site_pull.
# Code by git (rsync of the web tree is the fallback).
# Content by rsync. Database by Bee. settings.local.php written once.

# pull_code ROOT WEB VPS SRC_PLATFORM
pull_code() {
  root=$1
  web=$2
  vps=$3
  src_p=$4
  if [ -e "$root/.git" ]; then
    echo "code  git pull"
    if as_root -u "$OWNER" git -C "$root" pull --ff-only 2>/dev/null; then
      return 0
    fi
    echo "code  git pull skipped — rsync web tree"
  else
    echo "code  rsync web tree"
  fi
  # Run as OWNER so we can write and set times. Exclude the site
  # directory that site-add just created so --delete does not remove it.
  as_root -u "$OWNER" rsync -a --delete \
    --exclude='files/' --exclude='files_private/' \
    --exclude='sites/*/settings.local.php' \
    --exclude='sites/*/files' \
    --exclude='sites/*/' \
    "$vps:/srv/platforms/$src_p/web/" "$web/" || {
    echo "$PROG: rsync web tree failed" >&2
    return 1
  }
}

# pull_content ROOT PRODUCT VPS SRC_PLATFORM SRC_SITE
pull_content() {
  root=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  run_root mkdir -p "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active"
  echo "files rsync"
  as_root -u "$OWNER" rsync -a --delete "$vps:/srv/platforms/$src_p/files/$src_s/" "$root/files/$product/" 2>/dev/null || \
    as_root -u "$OWNER" rsync -a --delete "$vps:/srv/platforms/$src_p/web/files/" "$root/files/$product/" || true
  echo "private rsync"
  as_root -u "$OWNER" rsync -a --delete "$vps:/srv/platforms/$src_p/files_private/$src_s/" "$root/files_private/$product/" 2>/dev/null || true
  echo "config rsync"
  as_root -u "$OWNER" rsync -a --delete "$vps:/srv/platforms/$src_p/config/$src_s/active/" "$root/config/$product/active/" 2>/dev/null || true
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true
}

# pull_db WEB PRODUCT VPS SRC_PLATFORM SRC_SITE
pull_db() {
  web=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  bee=$(bee_bin)
  dump=$(mktemp)
  echo "db    export on $vps"
  ssh "$vps" "andromeda bee $src_p $src_s db-export -" > "$dump" 2>/dev/null || \
    ssh "$vps" "bee --root=/srv/platforms/$src_p/web --site=$src_s db-export -" > "$dump" || true
  if [ -s "$dump" ]; then
    echo "db    import"
    as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump" || true
  else
    echo "db    none"
  fi
  rm -f "$dump"
}

# Local variants — same host, no ssh. Used when the source ref is bare or local.

pull_code_local() {
  root=$1
  web=$2
  src_p=$3
  src_web="/srv/platforms/$src_p/web"
  if [ ! -d "$src_web" ]; then
    echo "$PROG: local source web missing: $src_web" >&2
    return 1
  fi
  echo "code  rsync local web tree"
  as_root -u "$OWNER" rsync -a --delete \
    --exclude='files/' --exclude='files_private/' \
    --exclude='sites/*/settings.local.php' \
    --exclude='sites/*/files' \
    --exclude='sites/*/' \
    "$src_web/" "$web/" || {
    echo "$PROG: local rsync web tree failed" >&2
    return 1
  }
}

pull_content_local() {
  root=$1
  product=$2
  src_p=$3
  src_s=$4
  src_root="/srv/platforms/$src_p"
  run_root mkdir -p "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active"
  echo "files rsync local"
  if [ -d "$src_root/files/$src_s" ]; then
    as_root -u "$OWNER" rsync -a --delete "$src_root/files/$src_s/" "$root/files/$product/" || true
  fi
  echo "private rsync local"
  if [ -d "$src_root/files_private/$src_s" ]; then
    as_root -u "$OWNER" rsync -a --delete "$src_root/files_private/$src_s/" "$root/files_private/$product/" || true
  fi
  echo "config rsync local"
  if [ -d "$src_root/config/$src_s/active" ]; then
    as_root -u "$OWNER" rsync -a --delete "$src_root/config/$src_s/active/" "$root/config/$product/active/" || true
  fi
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true
}

pull_db_local() {
  web=$1
  product=$2
  src_p=$3
  src_s=$4
  bee=$(bee_bin)
  dump=$(mktemp)
  echo "db    export local"
  as_root -u "$OWNER" "$bee" --root="/srv/platforms/$src_p/web" --site="$src_s" db-export "$dump" 2>/dev/null || true
  if [ -s "$dump" ]; then
    echo "db    import"
    as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump" || true
  else
    echo "db    none"
  fi
  rm -f "$dump"
}

# push_site SRC_HOST SRC_PLAT SRC_SITE DST_HOST DST_PLAT DST_SITE HOSTNAME ROLE
# Moves code, content, and db. Ensures the destination site exists with the
# computed hostname. Local ends use the filesystem; remote ends use ssh/rsync.
push_site() {
  src_h=$1
  src_p=$2
  src_s=$3
  dst_h=$4
  dst_p=$5
  dst_s=$6
  host=$7
  role=$8

  # Resolve source root
  if is_local_host "$src_h"; then
    src_root="/srv/platforms/$src_p"
  else
    src_root="$src_h:/srv/platforms/$src_p"
  fi

  # Ensure destination platform and site
  if is_local_host "$dst_h"; then
    if [ ! -d "$PLATFORMS/$dst_p" ]; then
      echo "create platform $dst_p"
      cmd_platform_add "$dst_p" --no-prompt
    fi
    ANDROMEDA_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host" || true
    # First local push between stages inits the platform repo and
    # checks out the destination stage branch.
    stage=$(stage_from_site "$dst_s")
    ensure_platform_git "$dst_p" "$stage" || true
    dst_root="/srv/platforms/$dst_p"
    dst_web="$dst_root/web"
  else
    echo "ensure dest site on $dst_h"
    ssh "$dst_h" "andromeda add platform $dst_p --no-prompt" 2>/dev/null || true
    ssh "$dst_h" "andromeda add site $dst_p $dst_s --host $host" || true
    stage=$(stage_from_site "$dst_s")
    # Remote dest: init the platform repo and checkout the stage branch
    # if the remote Andromeda supports ensure. Fall back to a direct init.
    ssh "$dst_h" "cd /srv/platforms/$dst_p &&       if [ ! -e .git ]; then git init && git add -A && git commit -m 'init platform $dst_p' --allow-empty || true;       for b in devel test live; do git branch \$b 2>/dev/null || true; done; fi &&       git checkout -B $stage" 2>/dev/null || true
    dst_root="$dst_h:/srv/platforms/$dst_p"
    dst_web="$dst_h:/srv/platforms/$dst_p/web"
  fi

  echo "code  rsync"
  if is_local_host "$src_h" && is_local_host "$dst_h"; then
    as_root -u "$OWNER" rsync -a --delete \
      --exclude='files/' --exclude='files_private/' \
      --exclude='sites/*/settings.local.php' \
      --exclude='sites/*/files' \
      --exclude='sites/*/' \
      "/srv/platforms/$src_p/web/" "$dst_web/" || true
  else
    as_root -u "$OWNER" rsync -a --delete \
      --exclude='files/' --exclude='files_private/' \
      --exclude='sites/*/settings.local.php' \
      --exclude='sites/*/files' \
      --exclude='sites/*/' \
      "$src_root/web/" "$dst_web/" || true
  fi

  echo "files rsync"
  if is_local_host "$src_h" && is_local_host "$dst_h"; then
    run_root mkdir -p "$dst_root/files/$dst_s" "$dst_root/files_private/$dst_s" "$dst_root/config/$dst_s/active"
    [ -d "/srv/platforms/$src_p/files/$src_s" ] && \
      as_root -u "$OWNER" rsync -a --delete "/srv/platforms/$src_p/files/$src_s/" "$dst_root/files/$dst_s/" || true
    [ -d "/srv/platforms/$src_p/files_private/$src_s" ] && \
      as_root -u "$OWNER" rsync -a --delete "/srv/platforms/$src_p/files_private/$src_s/" "$dst_root/files_private/$dst_s/" || true
    [ -d "/srv/platforms/$src_p/config/$src_s/active" ] && \
      as_root -u "$OWNER" rsync -a --delete "/srv/platforms/$src_p/config/$src_s/active/" "$dst_root/config/$dst_s/active/" || true
  else
    as_root -u "$OWNER" rsync -a --delete "$src_root/files/$src_s/" "$dst_root/files/$dst_s/" || true
    as_root -u "$OWNER" rsync -a --delete "$src_root/files_private/$src_s/" "$dst_root/files_private/$dst_s/" || true
    as_root -u "$OWNER" rsync -a --delete "$src_root/config/$src_s/active/" "$dst_root/config/$dst_s/active/" || true
  fi

  echo "db    export/import"
  bee=$(bee_bin)
  dump=$(mktemp)
  if is_local_host "$src_h"; then
    as_root -u "$OWNER" "$bee" --root="/srv/platforms/$src_p/web" --site="$src_s" db-export "$dump" 2>/dev/null || true
  else
    ssh "$src_h" "andromeda bee $src_p $src_s db-export -" > "$dump" 2>/dev/null || true
  fi
  if [ -s "$dump" ]; then
    if is_local_host "$dst_h"; then
      as_root -u "$OWNER" "$bee" --root="/srv/platforms/$dst_p/web" --site="$dst_s" db-import "$dump" || true
    else
      ssh "$dst_h" "andromeda bee $dst_p $dst_s db-import -" < "$dump" || true
    fi
  else
    echo "db    none"
  fi
  rm -f "$dump"

  if is_local_host "$dst_h"; then
    resolve_site "$dst_p" "$dst_s"
    _write_local "$root" "$web" "$product" "$host" "$role"
  fi
}
