# shellcheck shell=sh

# Pull a site from a VPS and stand it up as a devel site.
# usage: andromeda site-pull VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]
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
  # @host:plat/site [+ | to] @host:plat/site
  # verb-first already stripped "to", so two consecutive @refs is the common case
  if printf '%s' "${1:-}" | grep -q '^@'; then
    left=${1#@}
    if [ "${2:-}" = "+" ]; then
      right=${3#@}
    else
      right=${2#@}
    fi
    if printf '%s' "$right" | grep -q ':'; then
      vps=${left%%:*}
      src_p=${left#*:}; src_p=${src_p%%/*}
      src_s=${left##*/}
      dst_h=${right%%:*}
      dst_p=${right#*:}; dst_p=${dst_p%%/*}
      dst_s=${right##*/}
    else
      vps=${1:-}
      src_p=${2:-}
      src_s=${3:-}
      dst_h=local
      dst_p=${4:-$src_p}
      dst_s=${5:-$src_s}
    fi
  else
    vps=${1:-}
    src_p=${2:-}
    src_s=${3:-}
    dst_h=local
    dst_p=${4:-$src_p}
    dst_s=${5:-$src_s}
  fi
  if [ -z "$vps" ] || [ -z "$src_p" ] || [ -z "$src_s" ]; then
    echo "usage: $PROG site pull @host:plat/site + @host:plat/site" >&2
    exit 2
  fi

  src_path="/srv/platforms/$src_p/web/sites/$src_s"
  dst_path="/srv/platforms/$dst_p/web/sites/$dst_s"
  echo "pull @$vps:$src_p/$src_s + @$dst_h:$dst_p/$dst_s ($role)"
  echo "from $src_path  on $vps"
  echo "to   $dst_path"
  wg_up || return 1
  trap wg_down EXIT
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ git pull code (or rsync web tree)"
    echo "+ rsync files, private, config"
    echo "+ bee db-export + rsync + db-import"
    echo "+ platform-add $dst_p   (if missing)"
    echo "+ site-add $dst_p $dst_s"
    echo "+ write settings.local.php once"
    return 0
  fi

  if [ ! -d "$PLATFORMS/$dst_p" ]; then
    echo "create platform $dst_p"
    cmd_platform_add "$dst_p" --no-prompt
  fi
  host="${dst_s}.${role}"
  ANDROMEDA_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host"
  resolve_site "$dst_p" "$dst_s"

  # shellcheck disable=SC1091
  . "$LIBDIR/pull-rsync.sh"
  pull_code "$root" "$web" "$vps" "$src_p" || exit 1
  pull_content "$root" "$product" "$vps" "$src_p" "$src_s"
  pull_db "$web" "$product" "$vps" "$src_p" "$src_s"

  _write_local "$root" "$web" "$product" "$host" "$role"
  echo "pull done  http://$host"
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

