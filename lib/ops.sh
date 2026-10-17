# shellcheck shell=sh
# Journal, locks, secrets, backup-all, cron-all, log/last.

TASKS=${STARDUST_ROOT}/state/tasks.log
LOCKDIR=${STARDUST_ROOT}/state/locks
SECRETDIR=${STARDUST_ROOT}/state/secrets
KEEP_BACKUPS=${KEEP_BACKUPS:-7}

task_log() {
  # task_log CMD RC [detail]
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    return 0
  fi
  line=$(printf '%s host=%s role=%s user=%s cmd=%s rc=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(hostname 2>/dev/null || echo unknown)" \
    "${STARDUST_ROLE}" \
    "$(id -un 2>/dev/null || echo ?)" \
    "${1:-?}" \
    "${2:-0}" \
    "${3:-}")
  run_root mkdir -p "$STARDUST_ROOT/state"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ journal $line"
    return 0
  fi
  if [ -w "$TASKS" ] || [ -w "$STARDUST_ROOT/state" ]; then
    printf '%s\n' "$line" >> "$TASKS" 2>/dev/null || \
      as_root sh -c "printf '%s\n' '$line' >> '$TASKS'"
  else
    as_root sh -c "printf '%s\n' '$line' >> '$TASKS'"
  fi
}

with_lock() {
  # with_lock NAME cmd...
  name=$(slug "${1:-global}")
  shift
  run_root mkdir -p "$LOCKDIR"
  lock=$LOCKDIR/${name}.lock
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ lock $lock"
    "$@"
    return $?
  fi
  if have flock; then
    # lock fd 9
    exec 9>"$lock" || as_root touch "$lock"
    if ! flock -n 9; then
      echo "$PROG: $name already running (lock $lock)" >&2
      return 1
    fi
    "$@"
    rc=$?
    flock -u 9 2>/dev/null || true
    return $rc
  fi
  if ! mkdir "$lock.dir" 2>/dev/null; then
    echo "$PROG: $name already running (lock $lock.dir)" >&2
    return 1
  fi
  "$@"
  rc=$?
  rmdir "$lock.dir" 2>/dev/null || true
  return $rc
}

secret_file() {
  echo "$SECRETDIR/$1/$2"
}

write_secret() {
  platform=$1
  product=$2
  user=$3
  pass=$4
  db=$5
  dest=$(secret_file "$platform" "$product")
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ write $dest (0640)"
    return 0
  fi
  run_root mkdir -p "$SECRETDIR/$platform"
  # operator is in stardust and must be able to stat the .cnf
  run_root chown "$OWNER:stardust" "$SECRETDIR" "$SECRETDIR/$platform"
  run_root chmod 2750 "$SECRETDIR" "$SECRETDIR/$platform"
  # tee, not sh -c cat: sudo does not forward a heredoc to sh -c
  as_root tee "$dest" >/dev/null <<EOF
# stardust secret — do not commit
db=$db
user=$user
pass=$pass
host=localhost
EOF
  cnf=${dest}.cnf
  as_root tee "$cnf" >/dev/null <<EOF
[client]
user=$user
password=$pass
host=localhost
EOF
  chown_secret "$dest" "$cnf"
}

read_secret_pass() {
  dest=$(secret_file "$1" "$2")
  if [ -f "$dest" ]; then
    sed -n 's/^pass=//p' "$dest" | head -n 1
  fi
}

cmd_log() {
  n=${1:-30}
  if [ ! -f "$TASKS" ]; then
    echo "(no $TASKS yet)"
    return 0
  fi
  tail -n "$n" "$TASKS"
}

cmd_last() {
  if [ ! -f "$TASKS" ]; then
    echo "(no tasks yet)"
    return 0
  fi
  tail -n 1 "$TASKS"
}

each_site() {
  # prints "platform product" lines
  if [ ! -d "$PLATFORMS" ]; then
    return 0
  fi
  for p in "$PLATFORMS"/*; do
    [ -d "$p" ] || continue
    plat=${p##*/}
    web=""
    if [ -d "$p/web" ]; then web="$p/web"; elif [ -f "$p/index.php" ]; then web="$p"; fi
    [ -n "$web" ] || continue
    if [ -d "$web/sites" ]; then
      for s in "$web/sites"/*; do
        [ -d "$s" ] || continue
        base=${s##*/}
        case $base in default|all) continue ;; esac
        if [ -f "$s/settings.php" ] || [ -f "$s/settings.local.php" ]; then
          printf '%s %s\n' "$plat" "$base"
        fi
      done
    fi
  done
}

prune_backups() {
  platform=$1
  product=$2
  base=$(backup_dir "$platform" "$product" "$STARDUST_ROLE")
  [ -d "$base" ] || return 0
  # keep newest KEEP_BACKUPS stamp dirs
  count=$(ls -1d "$base"/20* 2>/dev/null | wc -l)
  count=$(echo "$count" | tr -d ' ')
  if [ "$count" -le "$KEEP_BACKUPS" ]; then
    return 0
  fi
  drop=$((count - KEEP_BACKUPS))
  ls -1d "$base"/20* 2>/dev/null | sort | head -n "$drop" | while read -r old; do
    run_root rm -rf "$old"
    echo "pruned $old"
  done
}

cmd_backup_all() {
  echo "backup-all role=$STARDUST_ROLE keep=$KEEP_BACKUPS"
  fail=0
  each_site | while read -r plat prod; do
    [ -n "$plat" ] || continue
    cmd_site_backup "$plat" "$prod" || fail=1
    prune_backups "$plat" "$prod"
  done
  return 0
}

cmd_inventory() {
  echo "inventory role=$STARDUST_ROLE platforms=$PLATFORMS"
  each_site | while read -r plat prod; do
    [ -n "$plat" ] || continue
    root=$PLATFORMS/$plat
    gitb=""
    if [ -e "$root/.git" ] && have git; then
      gitb=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    fi
    snap=$(latest_backup "$plat" "$prod" "$STARDUST_ROLE" 2>/dev/null || true)
    printf 'platform=%s product=%s branch=%s backup=%s\n' \
      "$plat" "$prod" "${gitb:-none}" "${snap:-none}"
  done
}

cmd_cron_all() {
  bee=$(bee_bin)
  n=0
  each_site | while read -r plat prod; do
    [ -n "$plat" ] || continue
    web=$PLATFORMS/$plat/web
    [ -d "$web" ] || continue
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ $bee --root=$web --site=$prod cron"
    else
      as_root -u "$OWNER" "$bee" --root="$web" --site="$prod" cron || true
      echo "cron $plat/$prod"
      # stagger 20s so two shops do not stampede MariaDB
      sleep 20
    fi
    n=$((n + 1))
  done
}

mm_set() {
  web=$1
  product=$2
  on=$3
  bee=$(bee_bin)
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ $bee --root=$web --site=$product maintenance-mode $on"
    return 0
  fi
  as_root -u "$OWNER" "$bee" --root="$web" --site="$product" maintenance-mode "$on" || \
    as_root -u "$OWNER" "$bee" --root="$web" --site="$product" mm "$on" || true
}

cmd_site_disable() {
  resolve_site "${1:-}" "${2:-}"
  mm_set "$web" "$product" 1
  echo "maintenance on $platform/$product"
}

cmd_site_enable() {
  resolve_site "${1:-}" "${2:-}"
  mm_set "$web" "$product" 0
  echo "maintenance off $platform/$product"
}
