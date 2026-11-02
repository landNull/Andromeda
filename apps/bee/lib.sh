# shellcheck shell=sh
# apps/bee — runtime Bee helpers. Sourced after lib/common.sh.
# All Backdrop work goes through here so site/platform/d7 do not grow
# one-off `bee --root=... --site=...` variants.
#
# Usage from the dispatcher:
#   andromeda bee PLATFORM PRODUCT [bee-args...]
#   andromeda bee PLATFORM PRODUCT status
#   andromeda bee PLATFORM PRODUCT -y update-db
#   andromeda bee PLATFORM --root-only dl-core web

bee_site_cmd() {
  # bee_site_cmd WEB PRODUCT [args...]  — always passes --root and --site
  web=$1
  product=$2
  shift 2
  bee=$(bee_bin)
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ $bee --root=$web --site=$product $*"
    return 0
  fi
  as_root -u "$OWNER" "$bee" --root="$web" --site="$product" "$@"
}

bee_root_cmd() {
  # bee_root_cmd WEB [args...]  — no --site (dl-core, download)
  web=$1
  shift
  bee=$(bee_bin)
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ $bee --root=$web $*"
    return 0
  fi
  as_root -u "$OWNER" "$bee" --root="$web" "$@"
}

cmd_bee() {
  # andromeda bee PLATFORM PRODUCT [bee-args]
  # andromeda bee PLATFORM --root-only [bee-args]
  platform=${1:-}
  shift || true
  # @host:plat/site or plat/site, the same form pull and push use.
  if printf '%s' "$platform" | grep -q '/'; then
    parse_one_ref "$platform" || {
      echo "usage: $PROG bee @host:plat/site [bee-verb...]" >&2
      return 2
    }
    platform=$REF_PLAT
    set -- "$REF_SITE" "$@"
  fi
  if [ -z "$platform" ]; then
    echo "usage: $PROG bee PLATFORM PRODUCT [bee-verb...]" >&2
    echo "       $PROG bee PLATFORM --root-only [bee-verb...]" >&2
    echo "  example: $PROG bee mysite www status" >&2
    echo "  example: $PROG -n bee mysite www cache-rebuild" >&2
    echo "  Bee binary: \$BEE (default bee on PATH)" >&2
    return 2
  fi
  if [ "${1:-}" = "--root-only" ]; then
    shift
    platform=$(slug "$platform")
    root=$PLATFORMS/$platform
    web=$root/web
    if [ ! -d "$root" ]; then
      echo "$PROG: no platform $root" >&2
      return 1
    fi
    [ -d "$web" ] || web=$root
    if [ $# -eq 0 ]; then
      echo "usage: $PROG bee PLATFORM --root-only BEE_VERB" >&2
      return 2
    fi
    bee_root_cmd "$web" "$@"
    return $?
  fi
  product=${1:-}
  shift || true
  if [ -z "$product" ]; then
    echo "usage: $PROG bee PLATFORM PRODUCT [bee-verb...]" >&2
    return 2
  fi
  resolve_site "$platform" "$product"
  if [ $# -eq 0 ]; then
    set -- status
  fi
  bee_site_cmd "$web" "$product" "$@"
}

# andromeda theme list|enable|default REF [NAME]
# Bee stays inside. The user names the site and the theme.
cmd_theme() {
  act=${1:-}
  shift || true
  ref=${1:-}
  shift || true
  name=${1:-}
  if [ -z "$act" ] || [ -z "$ref" ]; then
    echo "usage: $PROG theme list @host:plat/site" >&2
    echo "       $PROG theme enable @host:plat/site THEME" >&2
    echo "       $PROG theme default @host:plat/site THEME" >&2
    return 2
  fi
  parse_one_ref "$ref" || {
    echo "$PROG: bad ref $ref" >&2
    return 2
  }
  resolve_site "$REF_PLAT" "$REF_SITE"
  case $act in
    list) bee_site_cmd "$web" "$product" themes ;;
    enable)
      [ -n "$name" ] || { echo "$PROG: theme enable needs a name" >&2; return 2; }
      bee_yes --root="$web" --site="$product" theme-enable "$name" || return 1
      ;;
    default)
      [ -n "$name" ] || { echo "$PROG: theme default needs a name" >&2; return 2; }
      bee_yes --root="$web" --site="$product" theme-default "$name" || return 1
      bee_yes --root="$web" --site="$product" cache-clear all || return 1
      ;;
    *) echo "$PROG: theme $act — use list, enable, or default" >&2; return 2 ;;
  esac
}

