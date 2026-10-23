# shellcheck shell=sh

# Pull a site from a VPS and stand it up as a devel site.
# usage: stardust site-pull VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]
cmd_site_pull() {
  vps=${1:-}
  src_p=${2:-}
  src_s=${3:-}
  dst_p=${4:-$src_p}
  dst_s=${5:-$src_s}
  if [ -z "$vps" ] || [ -z "$src_p" ] || [ -z "$src_s" ]; then
    echo "usage: $PROG site-pull VPS SRC_PLATFORM SRC_SITE [DEST_PLATFORM] [DEST_SITE]" >&2
    exit 2
  fi

  echo "pull $vps:$src_p/$src_s -> $dst_p/$dst_s (${STARDUST_ROLE:-devel})"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ ssh $vps stardust site-backup $src_p $src_s"
    echo "+ rsync snapshot"
    echo "+ site-add $dst_p $dst_s"
    echo "+ restore"
    return 0
  fi

  ssh "$vps" "stardust site-backup $src_p $src_s" || {
    echo "$PROG: remote backup failed" >&2
    exit 1
  }
  remote=$(ssh "$vps" "stardust site-backup $src_p $src_s --latest" 2>/dev/null || true)
  if [ -z "$remote" ]; then
    echo "$PROG: remote snapshot path missing" >&2
    exit 1
  fi
  local_snap="$HOME/.stardust/pull/$src_p/$src_s"
  mkdir -p "$local_snap"
  rsync -a "$vps:$remote/" "$local_snap/" || {
    echo "$PROG: rsync failed" >&2
    exit 1
  }

  host="${dst_s}.${STARDUST_ROLE:-devel}"
  cmd_site_add "$dst_p" "$dst_s" --host "$host"
  echo "pull done  http://$host"
  echo "snapshot  $local_snap"
}
