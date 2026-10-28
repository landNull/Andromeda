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

# Pull a site. Remote or local source, onto a destination under $PLATFORMS.
cmd_site_pull() {
  role=${ANDROMEDA_ROLE:-devel}
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; shift 2 ;;
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
  host=$(hostname_for_site "$dst_s" "$OVERRIDE_HOST")

  src_path="/srv/platforms/$src_p/web/sites/$src_s"
  dst_path="/srv/platforms/$dst_p/web/sites/$dst_s"
  echo "pull @$vps:$src_p/$src_s to @$dst_h:$dst_p/$dst_s"
  echo "hostname $host"
  echo "from $src_path  on $vps"
  echo "to   $dst_path"

  need_wg=0
  if ! is_local_host "$vps"; then
    need_wg=1
  fi
  if [ "$need_wg" -eq 1 ]; then
    wg_up || return 1
    trap wg_down EXIT
  fi

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ git pull code (or rsync web tree)"
    echo "+ rsync files, private, config"
    echo "+ bee db-export + rsync + db-import"
    echo "+ platform-add $dst_p   (if missing)"
    echo "+ site-add $dst_p $dst_s --host $host"
    echo "+ write settings.local.php once"
    return 0
  fi

  if [ ! -d "$PLATFORMS/$dst_p" ]; then
    echo "create platform $dst_p"
    cmd_platform_add "$dst_p" --no-prompt
  fi
  ANDROMEDA_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host"
  resolve_site "$dst_p" "$dst_s"
  # Local dest: ensure the platform repo exists and is on the stage branch.
  if is_local_host "$dst_h"; then
    stage=$(stage_from_site "$dst_s")
    ensure_platform_git "$dst_p" "$stage" || true
  fi

  # shellcheck disable=SC1091
  . "$LIBDIR/pull-rsync.sh"
  if is_local_host "$vps"; then
    pull_code_local "$root" "$web" "$src_p" || exit 1
    pull_content_local "$root" "$product" "$src_p" "$src_s"
    pull_db_local "$web" "$product" "$src_p" "$src_s"
  else
    pull_code "$root" "$web" "$vps" "$src_p" || exit 1
    pull_content "$root" "$product" "$vps" "$src_p" "$src_s"
    pull_db "$web" "$product" "$vps" "$src_p" "$src_s"
  fi

  _write_local "$root" "$web" "$product" "$host" "$role"
  echo "pull done  http://$host"
}

# Push a site. Local or remote source, onto a destination (local or remote).
# Same ref grammar as pull. Forward counterpart.
cmd_site_push() {
  role=${ANDROMEDA_ROLE:-devel}
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; shift 2 ;;
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
  host=$(hostname_for_site "$dst_s" "$OVERRIDE_HOST")

  echo "push @$src_h:$src_p/$src_s to @$dst_h:$dst_p/$dst_s"
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
    echo "+ rsync code, files, private, config"
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
  dsnline=$(grep -E '^\$database' "$localphp" 2>/dev/null | head -n 1 || true)
  hostpat=$(printf '%s' "$host" | sed 's/[][\.*^$+?(){}|\/]/\\\\&/g')
  tmp=$(mktemp) || return 1
  {
    echo "<?php"
    echo "// Written by andromeda pull. Overwritten on each run."
    if [ -n "$dsnline" ]; then
      echo "$dsnline"
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
  if as_root mv -f "$tmp" "$localphp"; then
    echo "write $localphp (role $role)"
  else
    rm -f "$tmp"
    return 1
  fi
}

