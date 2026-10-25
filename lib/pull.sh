# shellcheck shell=sh

# Pull a site from a VPS and stand it up as a devel site.
# usage: stardust site-pull VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]
cmd_site_pull() {
  role=${STARDUST_ROLE:-devel}
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; shift 2 ;;
      --) shift; break ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  # @host:plat/site + @host:plat/site
  if [ "${2:-}" = "+" ] && printf '%s' "${1:-}" | grep -q '^@'; then
    left=${1#@}
    right=${3#@}
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
  STARDUST_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host"
  resolve_site "$dst_p" "$dst_s"

  # Code: prefer git. Fall back to rsync of the web tree, excluding runtime.
  if [ -e "$root/.git" ]; then
    echo "code  git pull"
    if ! as_root -u "$OWNER" git -C "$root" pull --ff-only 2>/dev/null; then
      echo "code  git pull skipped — rsync web tree"
      rsync -a --delete \
        --exclude='files/' --exclude='files_private/' \
        --exclude='sites/*/settings.local.php' \
        --exclude='sites/*/files' \
        "$vps:/srv/platforms/$src_p/web/" "$web/" || {
        echo "$PROG: rsync web tree failed" >&2
        exit 1
      }
    fi
  else
    echo "code  rsync web tree"
    rsync -a --delete \
      --exclude='files/' --exclude='files_private/' \
      --exclude='sites/*/settings.local.php' \
      --exclude='sites/*/files' \
      "$vps:/srv/platforms/$src_p/web/" "$web/" || {
      echo "$PROG: rsync web tree failed" >&2
      exit 1
    }
  fi

  # Content: rsync the current tree. No tar roundtrip.
  run_root mkdir -p "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active"
  echo "files rsync"
  rsync -a --delete "$vps:/srv/platforms/$src_p/files/$src_s/" "$root/files/$product/" 2>/dev/null || \
    rsync -a --delete "$vps:/srv/platforms/$src_p/web/files/" "$root/files/$product/" || true
  echo "private rsync"
  rsync -a --delete "$vps:/srv/platforms/$src_p/files_private/$src_s/" "$root/files_private/$product/" 2>/dev/null || true
  echo "config rsync"
  rsync -a --delete "$vps:/srv/platforms/$src_p/config/$src_s/active/" "$root/config/$product/active/" 2>/dev/null || true
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true

  # Database: Bee on the remote, rsync the dump, Bee import locally.
  bee=$(bee_bin)
  dump=$(mktemp)
  echo "db    export on $vps"
  ssh "$vps" "stardust bee $src_p $src_s db-export -" > "$dump" 2>/dev/null || \
    ssh "$vps" "bee --root=/srv/platforms/$src_p/web --site=$src_s db-export -" > "$dump" || true
  if [ -s "$dump" ]; then
    echo "db    import"
    as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump" || true
  else
    echo "db    none"
  fi
  rm -f "$dump"

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
    echo "// Written by stardust pull. Overwritten on each run."
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

