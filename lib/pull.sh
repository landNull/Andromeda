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
# Tools: WireGuard, andro add platform, andro add site, andro repo-ensure,
# git, rsync, andro bee, andromeda-priv, andro heal site.
# Gaps: settings.local.php template, sites.php line.
cmd_site_pull() {
  role=${ANDROMEDA_ROLE:-devel}
  role_set=0
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; role_set=1; shift 2 ;;
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
  # Site suffix is the stage unless --role was given.
  if [ "$role_set" -eq 0 ]; then
    case $dst_s in
      *.devel|*.test|*.live) role=$(stage_from_site "$dst_s") ;;
    esac
  fi
  host=$(hostname_for_site "$dst_s" "$OVERRIDE_HOST")

  src_path="/srv/platforms/$src_p/web/sites/$src_s"
  dst_path="/srv/platforms/$dst_p/web/sites/$dst_s"
  echo "pull @$vps:$src_p/$src_s + @$dst_h:$dst_p/$dst_s ($role)"
  echo "hostname $host"
  echo "tunnel $(tunnel_host "$vps") port $(ssh_port)"
  echo "from $src_path  on $vps"
  echo "to   $dst_path"
  # 1. WireGuard for the tunnel.
  wg_up || return 1
  trap wg_down EXIT
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ andro add platform $dst_p   (if missing)"
    echo "+ andro add site $dst_p $dst_s --host $host"
    echo "+ andro repo-ensure $dst_p"
    echo "+ git checkout branch $role"
    echo "+ rsync image files"
    echo "+ write settings.local.php once"
    echo "+ andromeda-priv mysql-create"
    echo "+ andro bee $src_p $src_s db-export"
    echo "+ andro bee $dst_p $dst_s db-import"
    echo "+ andro bee $src_p $src_s config-export"
    echo "+ andro bee $dst_p $dst_s config-import"
    echo "+ andro heal site $dst_p $dst_s"
    return 0
  fi

  # 2. Platform. andro add platform.
  if [ ! -d "$PLATFORMS/$dst_p" ] || [ ! -d "$PLATFORMS/$dst_p/web" ]; then
    echo "create platform $dst_p"
    cmd_platform_add "$dst_p" --no-prompt
  fi
  # 3. Adopt a hand rename before site-add, so site-add does not
  # create an empty directory and hide the renamed one.
  resolve_site "$dst_p" "$dst_s"
  heal_renamed_site "$web" "$root" "$product" "$host"
  # Site. andro add site creates dirs, sites.php, settings, db user.
  if ! ANDROMEDA_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host" --no-install; then
    echo "$PROG: site-add failed — continuing with pull" >&2
  fi
  resolve_site "$dst_p" "$dst_s"
  # 4. Git repo. andro repo-ensure seeds the bare and the stage branches.
  cmd_repo_ensure "$dst_p" || true
  ensure_platform_git "$dst_p" "$role" || true

  # shellcheck disable=SC1091
  . "$LIBDIR/pull-rsync.sh"
  # 5. Code by git.
  pull_code "$root" "$web" "$vps" "$src_p" || exit 1
  # The checkout restores the source sites.php. That file does not
  # know this site. Bee refuses the site without the line.
  ensure_sites_php "$web" "$host" "$product"
  # 6. Images by rsync.
  pull_content "$root" "$product" "$vps" "$src_p" "$src_s"
  # 7. settings.local.php — the gap. One template write.
  # Bee reads it to learn the database. Writing it after the import is too late.
  _write_local "$root" "$web" "$product" "$host" "$role"
  # 8. Database user by andromeda-priv. site-add already tried; retry.
  platform=$dst_p product=$dst_s
  db=$(db_name "$product" "$role")
  user=$(printf '%s' "$db" | cut -c1-32)
  pass=$(read_secret_pass "$platform" "$product" || true)
  if [ -n "$pass" ]; then
    ensure_db "$db" "$user" "$pass" || echo "$PROG: database not ready — import will fail" >&2
  fi
  # 9. Database by andro bee.
  pull_db "$web" "$product" "$vps" "$src_p" "$src_s"
  # 10. Configuration by andro bee.
  pull_config "$root" "$product" "$vps" "$src_p" "$src_s"
  # 11. Vhost and permissions by andro heal site.
  cmd_site_heal "$dst_p" "$dst_s" || true

  echo "pull done  http://$host"
}

# Push a site. Local or remote source, onto a destination (local or remote).
# Same ref grammar as pull. Forward counterpart.
cmd_site_push() {
  role=${ANDROMEDA_ROLE:-devel}
  role_set=0
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; role_set=1; shift 2 ;;
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
    echo "\$settings['trusted_host_patterns'] = array('^${hostpat}\$');"
    if [ "$role" != "live" ]; then
      echo "\$settings['cache'] = FALSE;"
    fi
  } > "$tmp"
  as_root chmod 0640 "$tmp"
  if [ -f "$localphp" ]; then
    echo "heal  settings.local.php (hand edit replaced)"
  fi
  if as_root mv -f "$tmp" "$localphp"; then
    echo "write $localphp (role $role)"
  else
    rm -f "$tmp"
    return 1
  fi
}

