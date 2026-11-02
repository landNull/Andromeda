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
      bee_yes --root="$web" --site="$product" enable "$name" || return 1
      ;;
    default)
      [ -n "$name" ] || { echo "$PROG: theme default needs a name" >&2; return 2; }
      bee_yes --root="$web" --site="$product" theme-default "$name" || return 1
      bee_yes --root="$web" --site="$product" cache-clear all || return 1
      ;;
    *) echo "$PROG: theme $act — use list, enable, or default" >&2; return 2 ;;
  esac
}


# andromeda run @host:plat/site VERB [args]
# One door for every Bee command. The user does not type bee.
cmd_run() {
  ref=${1:-}
  shift || true
  if [ -z "$ref" ] || [ $# -eq 0 ]; then
    echo "usage: $PROG run @host:plat/site VERB [args]" >&2
    return 2
  fi
  parse_one_ref "$ref" || {
    echo "$PROG: bad ref $ref" >&2
    return 2
  }
  resolve_site "$REF_PLAT" "$REF_SITE"
  bee_yes --root="$web" --site="$product" "$@"
}


# andromeda VERB NOUN @ref [args]
# enable theme, list themes, clear cache, update database, and the rest.
# The map is the Bee verb. The user does not type bee.
bee_verb_map() {
  case "$1 $2" in
    "list themes")        printf '%s\n' themes ;;
    "enable theme")       printf '%s\n' enable ;;
    "disable theme")      printf '%s\n' theme-disable ;;
    "default theme")      printf '%s\n' theme-default ;;
    "list modules")       printf '%s\n' modules ;;
    "enable module")      printf '%s\n' enable ;;
    "disable module")     printf '%s\n' module-disable ;;
    "clear cache")        printf '%s\n' cache-clear ;;
    "update database")    printf '%s\n' updb ;;
    "import config")      printf '%s\n' config-import ;;
    "export config")      printf '%s\n' config-export ;;
    "get config")         printf '%s\n' config-get ;;
    "set config")         printf '%s\n' config-set ;;
    "status site")        printf '%s\n' status ;;
    "cron site")          printf '%s\n' cron ;;
    "maintenance site")   printf '%s\n' maintenance-mode ;;
    "export database")    printf '%s\n' db-export ;;
    "import database")    printf '%s\n' db-import ;;
    *) return 1 ;;
  esac
}

# Called when the first word is a Bee verb and the second is its noun.
cmd_bee_verb() {
  verb=$1
  noun=$2
  shift 2
  bee=$(bee_verb_map "$verb" "$noun") || return 1
  ref=${1:-}
  shift || true
  if [ -z "$ref" ]; then
    echo "usage: $PROG $verb $noun @host:plat/site [args]" >&2
    return 2
  fi
  parse_one_ref "$ref" || {
    echo "$PROG: bad ref $ref" >&2
    return 2
  }
  resolve_site "$REF_PLAT" "$REF_SITE"
  case $bee in
    cache-clear|updb|config-import)
      bee_yes --root="$web" --site="$product" "$bee" all "$@" ||       bee_yes --root="$web" --site="$product" "$bee" "$@"
      ;;
    *)
      bee_yes --root="$web" --site="$product" "$bee" "$@"
      ;;
  esac
}


# andromeda apply theme @ref [name]
# Sets the default theme and the default layout template.
# Writes the config files. Does not touch admin layouts.
cmd_apply_theme() {
  ref=${1:-}
  name=${2:-tabler}
  if [ -z "$ref" ]; then
    echo "usage: $PROG apply theme @host:plat/site [name]" >&2
    return 2
  fi
  parse_one_ref "$ref" || {
    echo "$PROG: bad ref $ref" >&2
    return 2
  }
  resolve_site "$REF_PLAT" "$REF_SITE"
  bee_yes --root="$web" --site="$product" config-set system.core theme_default "$name" || return 1
  bee_yes --root="$web" --site="$product" config-set layout.layout.default layout_template "$name" || return 1
  bee_yes --root="$web" --site="$product" config-set layout.layout.home layout_template "$name" || true
  bee_yes --root="$web" --site="$product" config-set layout.layout.admin_default layout_template "$name" || true
  bee_yes --root="$web" --site="$product" cache-clear all || return 1
  echo "applied $name to system.core, default, home, and admin layouts"
}

