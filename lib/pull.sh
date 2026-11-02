#!/bin/sh
# shellcheck shell=sh

# Shared ref parser for pull and push.
# Accepts:
#   @host:plat/site [to|+] @host:plat/site [hostname NAME]
#   plat/site [to|+] plat/site [hostname NAME]
#   mixed forms
# Bare plat/site means this host (local).
# Sets: SRC_HOST SRC_PLAT SRC_SITE DST_HOST DST_PLAT DST_SITE OVERRIDE_HOST
parse_site_refs() {
  SRC_HOST="" SRC_PLAT="" SRC_SITE=""
  DST_HOST="" DST_PLAT="" DST_SITE=""
  OVERRIDE_HOST=""
  left=""
  right=""
  # peel optional hostname / --host from the end
  set -- "$@"
  args=""
  while [ $# -gt 0 ]; do
    case $1 in
      hostname|--host|--hostname)
        OVERRIDE_HOST=${2:-}
        shift 2 || true
        ;;
      *)
        args="$args $1"
        shift
        ;;
    esac
  done
  # shellcheck disable=SC2086
  set -- $args
  left=${1:-}
  if [ "${2:-}" = "+" ] || [ "${2:-}" = "to" ]; then
    right=${3:-}
  else
    right=${2:-}
  fi
  if [ -z "$left" ] || [ -z "$right" ]; then
    return 1
  fi
  # left
  if printf '%s' "$left" | grep -q '^@'; then
    left=${left#@}
    SRC_HOST=${left%%:*}
    rest=${left#*:}
    SRC_PLAT=${rest%%/*}
    SRC_SITE=${rest##*/}
  else
    SRC_HOST=local
    SRC_PLAT=${left%%/*}
    SRC_SITE=${left##*/}
  fi
  # right
  if printf '%s' "$right" | grep -q '^@'; then
    right=${right#@}
    DST_HOST=${right%%:*}
    rest=${right#*:}
    DST_PLAT=${rest%%/*}
    DST_SITE=${rest##*/}
  else
    DST_HOST=local
    DST_PLAT=${right%%/*}
    DST_SITE=${right##*/}
  fi
  [ -n "$SRC_PLAT" ] && [ -n "$SRC_SITE" ] && [ -n "$DST_PLAT" ] && [ -n "$DST_SITE" ]
}


# heal_renamed_site WEB ROOT PRODUCT HOST
# The destination name in the command is the source of truth.
# A hand rename (keslerlumber.test, or the old product) is moved into place.
# Matching files, private, and config directories move with it.
heal_renamed_site() {
  web=$1
  root=$2
  product=$3
  host=$4
  sites=$web/sites
  [ -d "$sites" ] || return 0
  if [ -d "$sites/$product" ]; then
    return 0
  fi
  stem=$product
  case $stem in
    *.devel|*.test|*.live) stem=${stem%.*} ;;
  esac
  cand=""
  # Same stem, different stage. The user renamed the suffix.
  for s in "$stem" "$stem.devel" "$stem.test" "$stem.live"; do
    [ "$s" = "$product" ] && continue
    if [ -d "$sites/$s" ]; then
      cand="$cand $s"
    fi
  done
  # sites.php maps this host at an old product.
  if [ -f "$sites/sites.php" ]; then
    mapped=$(sed -n "s/.*sites\['$host'\] = '\([^']*\)'.*/\1/p" "$sites/sites.php" | head -1)
    if [ -n "$mapped" ] && [ "$mapped" != "$product" ] && [ -d "$sites/$mapped" ]; then
      case " $cand " in
        *" $mapped "*) ;;
        *) cand="$cand $mapped" ;;
      esac
    fi
  fi
  # shellcheck disable=SC2086
  set -- $cand
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  if [ "$#" -gt 1 ]; then
    echo "$PROG: several renamed dirs for $product:$*" >&2
    echo "$PROG: not guessing. Move one into $sites/$product and pull again." >&2
    return 0
  fi
  old=$1
  echo "heal  rename $old -> $product"
  as_root mv "$sites/$old" "$sites/$product" || return 1
  for kind in files files_private; do
    if [ -d "$root/$kind/$old" ] && [ ! -e "$root/$kind/$product" ]; then
      as_root mv "$root/$kind/$old" "$root/$kind/$product" || true
    fi
  done
  if [ -d "$root/config/$old" ] && [ ! -e "$root/config/$product" ]; then
    as_root mv "$root/config/$old" "$root/config/$product" || true
  fi
}

# Pull a site from a remote host and stand it up locally.
# Tools: WireGuard, git bundle, andro add platform, andro add site,
# rsync, andro bee, andromeda-priv, andro heal site.
# Code by git. Content and config by rsync. Database by Bee.
# settings.local.php is written by site-add. It is gitignored.
cmd_site_pull() {
  role=${ANDROMEDA_ROLE:-devel}
  role_set=0
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; role_set=1; shift 2 ;;
      -v|--verbose) VERBOSE=1; export VERBOSE; shift ;;
      --) shift; break ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  if ! parse_site_refs "$@"; then
    echo "usage: $PROG pull site [@host:]plat/site to [@host:]plat/site [hostname NAME]" >&2
    exit 2
  fi
  vps=$SRC_HOST
  src_p=$SRC_PLAT
  src_s=$SRC_SITE
  dst_h=$DST_HOST
  dst_p=$DST_PLAT
  dst_s=$DST_SITE
  if [ "$role_set" -eq 0 ]; then
    case $dst_s in
      *.devel|*.test|*.live) role=$(stage_from_site "$dst_s") ;;
    esac
  fi
  host=$(hostname_for_site "$dst_s" "$OVERRIDE_HOST")

  # Same failure twice is a loop. Refuse until the stamp is cleared.
  sig=$(printf '%s:%s:%s:%s' "$vps" "$src_p" "$src_s" "$dst_p/$dst_s" | tr '/ ' '__')
  stamp="$ANDROMEDA_ROOT/state/pull-fail-$sig"
  PULL_STAMP=$stamp
  export PULL_STAMP
  if [ -f "$stamp" ]; then
    echo "$PROG: last pull of this site failed at the same step." >&2
    echo "$PROG: $(cat "$stamp" 2>/dev/null)" >&2
    echo "$PROG: fix that, then remove $stamp and pull again." >&2
    exit 1
  fi
  echo "pull @$vps:$src_p/$src_s + @$dst_h:$dst_p/$dst_s ($role)"
  echo "hostname $host"
  echo "from /srv/platforms/$src_p/web/sites/$src_s  on $vps"
  echo "to   /srv/platforms/$dst_p/web/sites/$dst_s"
  vnote "verbose on — each step names the tool and stops on the first hard failure"
  # Tunnel. Existing tool.
  step 1 "WireGuard"
  wg_up || fail_step 1 "WireGuard did not come up"
  trap wg_down EXIT
  remote=$(tunnel_host "$vps")
  echo "tunnel $remote port $(ssh_port)"
  vnote "tunnel_host $vps -> $remote"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ git bundle from $remote:/srv/platforms/$src_p, checkout $role"
    echo "+ andro add platform $dst_p   (if missing)"
    echo "+ andro add site $dst_p $dst_s --host $host"
    echo "+ andromeda-priv mysql-create"
    echo "+ rsync files, private"
    echo "+ rsync config active + bee config-import"
    echo "+ andro bee db-export on $remote, db-import here"
    echo "+ _write_local (Backdrop 1.30 array)"
    echo "+ andro heal site"
    return 0
  fi

  # shellcheck disable=SC1091
  . "$LIBDIR/pull-rsync.sh"

  # Skeleton first on a local dest. Worktree, dirs, settings, security.
  if is_local_host "$dst_h"; then
    step 2 "ensure stage"
    cmd_ensure_stage "$dst_p" "$dst_s" --role "$role" || fail_step 2 "stage skeleton failed"
  fi

  # Platform first. pull_code fetches into its repo.
  step 3 "platform"
  if [ ! -d "$PLATFORMS/$dst_p" ] || [ ! -d "$PLATFORMS/$dst_p/web" ]; then
    echo "create platform $dst_p"
    cmd_platform_add "$dst_p" --no-prompt || fail_step 3 "platform-add failed for $dst_p"
  else
    echo "platform $dst_p already present"
    vnote "using $PLATFORMS/$dst_p"
  fi
  stage_paths "$dst_p" "$dst_s" "$role"
  root=$STAGE_ROOT
  web=$STAGE_WEB
  vnote "stage tree $root"

  # Code by git. A bundle, because the source repo is owned by deploy.
  # settings.local.php is gitignored, so the reset does not touch it.
  step 4 "code (git bundle)"
  pull_code "$root" "$web" "$vps" "$src_p" || fail_step 4 "code did not move"

  # Site skeleton. Writes settings.local.php, the sites.php line, and
  # the empty stores. --no-install: Bee does not run yet.
  step 5 "site skeleton (site-add --no-install)"
  ANDROMEDA_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host" --no-install || \
    fail_step 5 "site-add failed"
  resolve_site "$dst_p" "$dst_s"

  # Database user. andromeda-priv mysql-create. Bee cannot create a user.
  step 6 "database user (andromeda-priv mysql-create)"
  db=$(db_name "$product" "$role")
  user=$(printf '%s' "$db" | cut -c1-32)
  pass=$(read_secret_pass "$platform" "$product" || true)
  vnote "db=$db user=$user secret=$(secret_file "$platform" "$product")"
  if [ -z "$pass" ]; then
    fail_step 6 "no secret for $platform/$product"
  fi
  if ! ensure_db "$db" "$user" "$pass"; then
    fail_step 6 "database user not created — Bee will not run"
  fi
  cnf=$(secret_file "$platform" "$product").cnf
  echo "db    login test $user"
  if ! mysql --defaults-extra-file="$cnf" -e "SELECT 1" >/dev/null 2>&1; then
    mysql --defaults-extra-file="$cnf" -e "SELECT 1" >&2 || true
    fail_step 6 "$user cannot log in — Bee will not run"
  fi
  echo "db    $user can log in"

  # Content by rsync. Config by rsync. Database by Bee.
  step 7 "user content (rsync)"
  pull_files "$root" "$product" "$vps" "$src_p" "$src_s" || fail_step 7 "files did not move"

  step 8 "config (rsync + Bee config-import)"
  pull_config "$root" "$product" "$vps" "$src_p" "$src_s" || fail_step 8 "config did not import"

  step 9 "database (Bee db-export / db-import)"
  pull_db "$web" "$product" "$vps" "$src_p" "$src_s" || fail_step 9 "database did not import"

  # site-add only wrote the DSN-string settings.local.php and never links
  # sites/<product>/files — without this the pulled site has no public
  # files path and (on Backdrop 1.30+) no $database array. _write_local
  # creates the files symlink and rewrites settings.local.php in one pass.
  step 10 "settings.local.php (Backdrop 1.30 array)"
  if is_local_host "$dst_h"; then
    _write_local "$root" "$web" "$product" "$host" "$role" || \
      fail_step 10 "settings.local.php was not written"
  else
    echo "dest is remote — settings written on the far side"
  fi

  step 11 "heal"
  cmd_site_heal "$dst_p" "$dst_s" || true

  step 12 "done"
  echo "pull done  http://$host"
  if [ -n "${RUN_LOG:-}" ]; then
    echo "log   $RUN_LOG"
  fi
}

# Push a site. Local or remote source, onto a destination (local or remote).
# Same ref grammar as pull. Forward counterpart.
cmd_site_push() {
  role=${ANDROMEDA_ROLE:-devel}
  role_set=0
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; role_set=1; shift 2 ;;
      -v|--verbose) VERBOSE=1; export VERBOSE; shift ;;
      --) shift; break ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  if ! parse_site_refs "$@"; then
    echo "usage: $PROG push site [@host:]plat/site to [@host:]plat/site [hostname NAME]" >&2
    exit 2
  fi
  src_h=$SRC_HOST
  src_p=$SRC_PLAT
  src_s=$SRC_SITE
  dst_h=$DST_HOST
  dst_p=$DST_PLAT
  dst_s=$DST_SITE
  if [ "$role_set" -eq 0 ]; then
    case $dst_s in
      *.devel|*.test|*.live) role=$(stage_from_site "$dst_s") ;;
    esac
  fi
  host=$(hostname_for_site "$dst_s" "$OVERRIDE_HOST")

  echo "push @$src_h:$src_p/$src_s to @$dst_h:$dst_p/$dst_s ($role)"
  echo "hostname $host"

  need_wg=0
  if ! is_local_host "$src_h" || ! is_local_host "$dst_h"; then
    need_wg=1
  fi
  if [ "$need_wg" -eq 1 ]; then
    wg_up || return 1
    trap wg_down EXIT
  fi

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ git commit on source stage, merge into dest stage (rsync fallback)"
    echo "+ rsync files, private, config"
    echo "+ bee db-export + import on dest"
    echo "+ ensure site on dest with host $host"
    return 0
  fi

  # shellcheck disable=SC1091
  . "$LIBDIR/pull-rsync.sh"
  # Dest skeleton before any file moves.
  if is_local_host "$dst_h"; then
    cmd_ensure_stage "$dst_p" "$dst_s" --role "$role" || return 1
    stage_paths "$dst_p" "$dst_s" "$role"
    echo "dest  $STAGE_ROOT ready"
  fi
  push_site "$src_h" "$src_p" "$src_s" "$dst_h" "$dst_p" "$dst_s" "$host" "$role"
  echo "push done  http://$host"
}

# One clean settings.local.php. Never append.
_write_local() {
  root=$1
  web=$2
  product=$3
  host=$4
  role=$5
  localphp=$web/sites/$product/settings.local.php
  sitefiles="$web/sites/$product/files"
  if [ -d "$sitefiles" ] && [ ! -L "$sitefiles" ]; then
    as_root rm -rf "$sitefiles"
  fi
  as_root ln -sfn "../../../files/$product" "$sitefiles"
  echo "link  $sitefiles -> ../../../files/$product"
  settingsphp="$web/sites/$product/settings.php"
  if [ -f "$settingsphp" ] && ! grep -q "settings.local.php" "$settingsphp"; then
    printf '\n%s\n' "if (file_exists(__DIR__ . '/settings.local.php')) { include __DIR__ . '/settings.local.php'; }" | as_root tee -a "$settingsphp" >/dev/null
  fi
  cfgactive="$root/config/$product/active"
  cfgstaging="$root/config/$product/staging"
  run_root mkdir -p "$cfgstaging" 2>/dev/null || true
  # Backdrop 1.30 reads an array, not a DSN string. A missing array
  # leaves Database::getConnectionInfo() null, and bee db-import dies.
  db=$(db_name "$product" "$role")
  user=$(printf '%s' "$db" | cut -c1-32)
  pass=$(read_secret_pass "$platform" "$product" || true)
  if [ -z "$pass" ]; then
    echo "$PROG: no database password for $product — settings will not connect" >&2
  fi
  hostpat=$(printf '%s' "$host" | sed 's/[][\.*^$+?(){}|\/]/\\\\&/g')
  tmp=$(mktemp) || return 1
  {
    echo "<?php"
    echo "// Written by andromeda pull. Overwritten on each run."
    if [ -n "$pass" ]; then
      echo "\$database = array("
      echo "  'database' => '$db',"
      echo "  'username' => '$user',"
      echo "  'password' => '$pass',"
      echo "  'host'     => 'localhost',"
      echo "  'driver'   => 'mysql',"
      echo ");"
    fi
    echo "\$config_directories['active']  = '$cfgactive';"
    echo "\$config_directories['staging'] = '$cfgstaging';"
    echo "\$settings['file_public_path'] = 'sites/$product/files';"
    pats="'^${hostpat}\$'"
    if [ "${ANDROMEDA_PROOT:-0}" -eq 1 ]; then
      # single-host dev box (proot tablet): loopback names reach this site too
      pats="$pats, '^localhost\$', '^127.0.0.1\$'"
    fi
    echo "\$settings['trusted_host_patterns'] = array($pats);"
    if [ "$role" != "live" ]; then
      echo "\$settings['cache'] = FALSE;"
    fi
  } > "$tmp"
  as_root chmod 0640 "$tmp"
  if [ -f "$localphp" ]; then
    echo "heal  settings.local.php (hand edit replaced)"
  fi
  if as_root mv -f "$tmp" "$localphp"; then
    # Bee runs as deploy. The file must be readable by deploy before
    # crdir, and still readable after. A failed crdir is not ignored.
    as_root chown "$OWNER:$GROUP" "$localphp" || return 1
    as_root chmod 0640 "$localphp" || return 1
    cr=$(need_crdir)
    "$cr" -o "$OWNER" -g "$GROUP" -m 0640 "$localphp" || return 1
    if ! as_root -u "$OWNER" test -r "$localphp"; then
      echo "$PROG: $OWNER cannot read $localphp" >&2
      if command -v namei >/dev/null 2>&1; then
        namei -l "$localphp" >&2 || true
      else
        ls -ld "$(dirname "$localphp")" "$localphp" >&2 || true
      fi
      return 1
    fi
    echo "write $localphp (role $role)"
  else
    rm -f "$tmp"
    return 1
  fi
}

