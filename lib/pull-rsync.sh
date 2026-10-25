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
