# shellcheck shell=sh
# d7 — Andromeda module: Drupal 7 / BOA -> Backdrop on knarr
# Sourced by bin/andromeda and by the portable bin/d7-migrate wrapper.
# Never bee install an imported D7 schema.

# Fallbacks when this file is sourced without common.sh (BOA prep box).
if ! command -v have >/dev/null 2>&1; then
  have() { command -v "$1" >/dev/null 2>&1; }
fi
if ! command -v note >/dev/null 2>&1; then
  note() { printf '  note  %s\n' "$1"; }
  ok()   { printf '  ok    %s\n' "$1"; }
  bad()  { printf '  FAIL  %s\n' "$1"; }
fi
if ! command -v slug >/dev/null 2>&1; then
  slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-' | sed 's/^-*//;s/-*$//'; }
fi
if ! command -v stamp >/dev/null 2>&1; then
  stamp() { date +%Y%m%d-%H%M%S; }
fi
if ! command -v run >/dev/null 2>&1; then
  DRYRUN=${DRYRUN:-0}
  run() {
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      printf '+'
      for a in "$@"; do printf ' %s' "$a"; done
      printf '\n'
      return 0
    fi
    "$@"
  }
  as_root() {
    if [ "$(id -u)" -eq 0 ]; then
      "$@"
      return $?
    fi
    if [ "${1:-}" = "-u" ]; then
      tgt=$2
      shift 2
      [ "$(id -un)" = "$tgt" ] && { "$@"; return $?; }
      sudo -n -u "$tgt" "$@" 2>/dev/null || sudo -u "$tgt" "$@"
      return $?
    fi
    sudo -n "$@" 2>/dev/null || sudo "$@"
  }
  run_root() {
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      printf '+'
      for a in "$@"; do printf ' %s' "$a"; done
      printf '\n'
      return 0
    fi
    as_root "$@"
  }
fi

D7_FROM=""
D7_OUT=""
D7_SQL=""
D7_FILES=""
D7_PRIVATE=""
D7_PLATFORM=""
D7_PRODUCT=""
D7_HOST=""
D7_TITLE=""
D7_MODULES=""
D7_ALIAS=""
D7_REPORT=""
D7_FORCE=0
D7_SKIP_DL=0
D7_KEEP_UFA=0
D7_YES=0
D7_PLAN=""
D7_STEP=""
D7_HAS_UC=0
D7_HAS_RULES=0
D7_HAS_SEARCH_API=0
D7_HAS_ENTITY=0
D7_NEED_EPLUS=0
D7_DROP_ENABLED=""
D7_CUSTOM=""
D7_THEMES_EN=""

d7_die() { echo "${PROG:-andromeda}: $*" >&2; return 1; }
d7_usage_die() { echo "${PROG:-andromeda}: $*" >&2; return 2; }

d7_find_catalog() {
  for d in \
    "${ANDROMEDA_LIB:-}" \
    "${LIBDIR:-}" \
    /usr/local/lib/andromeda \
    /srv/andromeda/lib
  do
    [ -n "$d" ] && [ -f "$d/d7-catalog.txt" ] && { echo "$d/d7-catalog.txt"; return 0; }
  done
  here=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || here=""
  for d in "$here/../lib" "$here/lib"; do
    [ -f "$d/d7-catalog.txt" ] && { echo "$d/d7-catalog.txt"; return 0; }
  done
  return 1
}

d7_catalog_line() {
  # name -> class backdrop note
  name=$1
  catf=$(d7_find_catalog) || return 1
  awk -F'	' -v n="$name" '
    $0 ~ /^#/ { next }
    NF < 2 { next }
    $1 == n { print $2 "\t" $3 "\t" $4; exit }
  ' "$catf"
}

d7_catalog_class() {
  line=$(d7_catalog_line "$1") || return 1
  printf '%s\n' "$line" | awk -F'	' '{print $1}'
}

d7_catalog_target() {
  line=$(d7_catalog_line "$1") || return 1
  printf '%s\n' "$line" | awk -F'	' '{print $2}'
}

d7_list_class() {
  want=$1
  catf=$(d7_find_catalog) || return 1
  awk -F'	' -v w="$want" '
    $0 ~ /^#/ { next }
    NF >= 2 && $2 == w { print $1 }
  ' "$catf"
}

d7_parse() {
  D7_FROM=""; D7_OUT=""; D7_SQL=""; D7_FILES=""; D7_PRIVATE=""
  D7_PLATFORM=""; D7_PRODUCT=""; D7_HOST=""; D7_TITLE=""; D7_MODULES=""
  D7_ALIAS=""; D7_REPORT=""; D7_FORCE=0; D7_SKIP_DL=0; D7_KEEP_UFA=0
  D7_YES=0; D7_PLAN=""; D7_STEP=""
  pos=""
  while [ $# -gt 0 ]; do
    case $1 in
      --force) D7_FORCE=1; shift ;;
      --yes|-y) D7_YES=1; shift ;;
      --plan) D7_PLAN=$2; shift 2 ;;
      --step) D7_STEP=$2; shift 2 ;;
      --skip-dl) D7_SKIP_DL=1; shift ;;
      --keep-update-access) D7_KEEP_UFA=1; shift ;;
      --from) D7_FROM=$2; shift 2 ;;
      --out) D7_OUT=$2; shift 2 ;;
      --sql) D7_SQL=$2; shift 2 ;;
      --files) D7_FILES=$2; shift 2 ;;
      --private) D7_PRIVATE=$2; shift 2 ;;
      --platform) D7_PLATFORM=$2; shift 2 ;;
      --product) D7_PRODUCT=$2; shift 2 ;;
      --host) D7_HOST=$2; shift 2 ;;
      --name) D7_TITLE=$2; shift 2 ;;
      --modules) D7_MODULES=$2; shift 2 ;;
      --alias) D7_ALIAS=$2; shift 2 ;;
      --report) D7_REPORT=$2; shift 2 ;;
      -n) DRYRUN=1; shift ;;
      -h|--help) d7_help; return 2 ;;
      --) shift; break ;;
      -*) echo "${PROG:-andromeda}: unknown d7 flag $1" >&2; return 2 ;;
      *) pos="$pos $1"; shift ;;
    esac
  done
  # shellcheck disable=SC2086
  set -- $pos
  [ -z "$D7_FROM" ] && [ -n "${1:-}" ] && D7_FROM=$1 && shift
  [ -z "$D7_PLATFORM" ] && [ -n "${1:-}" ] && D7_PLATFORM=$1 && shift
  [ -z "$D7_PRODUCT" ] && [ -n "${1:-}" ] && D7_PRODUCT=$1 && shift
  return 0
}

d7_help() {
  cat <<EOF
andromeda d7 — Drupal 7 / BOA to Backdrop on knarr

  andromeda [-n] d7 test    SITE_DIR|BUNDLE [--yes] [--out DIR]
  andromeda [-n] d7 apply   --plan DIR|plan.json [--step ID] [--yes]
  andromeda      d7 tutorial --plan DIR
  andromeda [-n] d7 tools
  andromeda [-n] d7 stubs [--out DIR]          # only stubs the scan said you need
  andromeda [-n] d7 toolkit PLATFORM
  andromeda [-n] d7 prep    --from SITE_DIR [--out DIR] [--alias @site]
  andromeda [-n] d7 assess  --from SITE_DIR|BUNDLE
  andromeda [-n] d7 convert --from BUNDLE --platform NAME --product NAME [--host HOST]
  andromeda [-n] d7 attach  --platform NAME --product NAME [--host HOST]
  andromeda [-n] d7 port    --from MODULE_DIR --platform NAME
  andromeda [-n] d7 all     --from SITE_DIR|BUNDLE --platform NAME --product NAME

  test     scan modules, themes, settings, files
           writes plan.json + playbook.txt + modules.tsv + steps.tsv
           Ubercart / Rules / Search API steps only if those modules are enabled
  apply    run automatable steps from plan.json / steps.tsv
           --step ID runs one; --yes skips prompts; -n prints commands

Portable wrapper (BOA VPS has no Andromeda):
  d7-migrate prep|assess|convert|attach|all|tools|stubs|toolkit|port …

Official D7-side tester
  backdrop_upgrade_status  (Drupal 7 module)
  admin/reports/updates/backdrop-upgrade
  https://www.drupal.org/project/backdrop_upgrade_status

Backdrop-side tools (d7 toolkit installs these onto a platform)
  coder_upgrade            port D7 module PHP
  default_views_config     hook_views_default_views() -> JSON
  entity_plus + entity_ui  Rules / Ubercart / Search API
  d7compatible             D7 theme base theme

Conversion is update.php / bee -y updb on the imported D7 schema.
That is Backdrop's own converter: hook_update_N in core and each
port writes the JSON config (system.core, views.view.*, field.*,
layout.layout.*, module.settings). Do not invent a second exporter
for variables / Views-in-DB / field settings — bee updb already
does that (views_update_1001 reads {views_view}+{views_display}).
After updb: bee config-export copies active JSON to staging so
git can move devel -> test -> live.
Only leftover PHP default Views (hook_views_default_views) need
default_views_config. Rules stay in DB unless you enable rules_cmi.
Do NOT bee install. Modules must sit in the tree BEFORE updb.

See lib/d7-catalog.txt for COREIN / DROP / REPLACE / STUB / CONTRIB.
EOF
}

d7_ask() {
  q=$1
  def=${2:-n}
  if [ "${D7_YES:-0}" -eq 1 ]; then
    echo "  $q -> yes (--yes)"
    return 0
  fi
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ prompt: $q [$def]"
    [ "$def" = y ] && return 0
    return 1
  fi
  if [ ! -t 0 ] || [ ! -t 2 ]; then
    [ "$def" = y ] && return 0
    echo "  $q -> $def (not a tty; pass --yes to automate)"
    return 1
  fi
  printf '  %s [%s]: ' "$q" "$def" >&2
  ans=""
  IFS= read -r ans || ans=$def
  [ -z "$ans" ] && ans=$def
  case $ans in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

d7_enabled_has() {
  file=$1
  name=$2
  [ -f "$file" ] || return 1
  awk -F'	' -v n="$name" '$1=="module" && $2==n && $3!="0" {found=1} END{exit !found}' "$file"
}

d7_enabled_prefix() {
  file=$1
  prefix=$2
  [ -f "$file" ] || return 1
  awk -F'	' -v p="$prefix" '$1=="module" && $2 ~ "^"p && $3!="0" {found=1} END{exit !found}' "$file"
}

# Sets D7_HAS_* from an enabled.txt (module<TAB>name<TAB>status).
d7_scan_features() {
  file=${1:-}
  D7_HAS_UC=0
  D7_HAS_RULES=0
  D7_HAS_SEARCH_API=0
  D7_HAS_ENTITY=0
  D7_NEED_EPLUS=0
  D7_DROP_ENABLED=""
  D7_CUSTOM=""
  D7_THEMES_EN=""
  [ -n "$file" ] && [ -f "$file" ] || return 0

  d7_enabled_has "$file" rules && D7_HAS_RULES=1
  d7_enabled_has "$file" search_api && D7_HAS_SEARCH_API=1
  d7_enabled_has "$file" entity && D7_HAS_ENTITY=1
  if d7_enabled_has "$file" ubercart \
    || d7_enabled_has "$file" uc_cart \
    || d7_enabled_has "$file" uc_product \
    || d7_enabled_has "$file" uc_order \
    || d7_enabled_has "$file" uc_store \
    || d7_enabled_prefix "$file" uc_
  then
    D7_HAS_UC=1
  fi
  if [ "$D7_HAS_UC" -eq 1 ] || [ "$D7_HAS_RULES" -eq 1 ] || [ "$D7_HAS_SEARCH_API" -eq 1 ]; then
    D7_NEED_EPLUS=1
  fi

  D7_DROP_ENABLED=$(
    awk -F'	' '$1=="module" && $3!="0" {print $2}' "$file" | while IFS= read -r n; do
      [ -n "$n" ] || continue
      cls=$(d7_catalog_class "$n" || true)
      [ "$cls" = DROP ] && printf '%s ' "$n"
      true
    done || true
  )
  D7_CUSTOM=$(
    awk -F'	' '$1=="module" && $3!="0" {print $2}' "$file" | while IFS= read -r n; do
      [ -n "$n" ] || continue
      cls=$(d7_catalog_class "$n" || true)
      [ -z "$cls" ] && printf '%s ' "$n"
      true
    done || true
  )
  D7_THEMES_EN=$(awk -F'	' '$1=="theme" && $3!="0" {printf "%s ", $2}' "$file" || true)
}

d7_stub_list() {
  # prints stub machine names required by the last scan
  [ "${D7_NEED_EPLUS:-0}" -eq 1 ] && echo entity_plus && echo entity_ui
  [ "${D7_HAS_UC:-0}" -eq 1 ] && echo ubercart
}

d7_pick_site_under() {
  root=$1
  [ -d "$root/sites" ] || return 1
  found=""
  for s in "$root/sites"/*; do
    [ -d "$s" ] || continue
    base=${s##*/}
    case $base in all|default) continue ;; esac
    d7_is_site "$s" && found="$found $s"
  done
  [ -n "$found" ] || return 1
  set -- $found
  if [ $# -eq 1 ]; then
    printf '%s\n' "$1"
    return 0
  fi
  echo "several D7 sites under $root/sites:" >&2
  i=1
  for s in "$@"; do
    echo "  $i  $s" >&2
    i=$((i + 1))
  done
  if [ "${D7_YES:-0}" -eq 1 ]; then
    printf '%s\n' "$1"
    echo "  using first site (--yes): $1" >&2
    return 0
  fi
  if [ ! -t 0 ]; then
    printf '%s\n' "$1"
    echo "  using first site (not a tty): $1" >&2
    return 0
  fi
  printf '  site number [1]: ' >&2
  num=1
  IFS= read -r num || num=1
  [ -z "$num" ] && num=1
  i=1
  for s in "$@"; do
    [ "$i" -eq "$num" ] && { printf '%s\n' "$s"; return 0; }
    i=$((i + 1))
  done
  printf '%s\n' "$1"
}

# ---------------------------------------------------------------------------
# tools / stubs / toolkit / port
# ---------------------------------------------------------------------------

cmd_d7_tools() {
  cat <<EOF
D7 -> Backdrop toolkit (what Andromeda wraps)

ON THE DRUPAL 7 SITE (BOA VPS, before prep)
  backdrop_upgrade_status
    D7 module written for this exact job.
    Install into sites/all/modules, enable Update Manager + this module,
    visit admin/reports/updates/backdrop-upgrade
    Status per project: Available / In development / Not ported yet.
    https://www.drupal.org/project/backdrop_upgrade_status
    https://github.com/backdrop-contrib/backdrop_upgrade_status

  D7 stubs (andromeda d7 stubs — only what d7 test found)
    entity_plus + entity_ui   if Rules or Search API are enabled
    + ubercart                only if uc_* / Ubercart is enabled
    Enable those stubs on D7, THEN take the backdrop-ready dump.
    https://github.com/backdrop-contrib/ubercart/wiki/Upgrading-Ubercart-from-Drupal-7

  Prep checklist (docs.backdropcms.org step 2)
    Update D7 core + contrib
    Backup
    Uninstall removed core: overlay php blog poll profile? help openid
      rdf shortcut toolbar tracker dashboard
    Disable To-Uninstall / To-Port / To-Replace contrib
    Do NOT uninstall modules whose data a Backdrop port will read
      (References -> entityreference, Views, Date, Features-in-core)
    Save Views that live only in code
    Special handling: Rules, Ubercart, Entity API dependents
    Second dump named backdrop-ready.sql after stubs + uninstalls

ON THE BACKDROP PLATFORM (knarr / devel)
  coder_upgrade
    admin/config/development/coder-upgrade
    Drop D7 module into files/coder_upgrade/old, Convert Files
    https://backdropcms.org/project/coder_upgrade
    https://docs.backdropcms.org/converting-modules-from-drupal

  default_views_config
    admin/structure/views/default-views-convert
    Paste hook_views_default_views() PHP, write views.view.NAME.json
    into config/<product>/staging and bee config-import

  entity_plus + entity_ui
    Must be in the codebase BEFORE bee updb when Rules/Ubercart/Search API
    are enabled in the D7 dump.
    https://github.com/backdrop-contrib/entity_plus

  bee config-export / config-import  (cex / cim)
    After updb the JSON already lives in config/PRODUCT/active.
    cex copies it to staging for git and env promote.
    This is Backdrop CMI — the same files devel/test/live share.

  d7compatible (theme)
    base theme = d7compatible in the D7 theme .info
    + backdrop = 1.x / type = theme
    https://github.com/backdrop-contrib/d7compatible

  bee -y --root=WEB --site=PRODUCT update-db
    This IS the conversion. Same path as core/update.php.
    \$update_free_access = TRUE only for that run.

  andromeda site-check PLATFORM PRODUCT
    HTTP + Bee status + Apache error log after convert.

NOT used
  Drupal 8+ Migrate API / migrate_plus / migrate_tools
    Those target D8-D11. Backdrop is a D7 fork; the upgrade path is
    drop-in codebase + update.php, not a migrate pipeline.
  bee install
    Would wipe the imported D7 schema.

andromeda d7 toolkit PLATFORM   # bee dl the Backdrop tools
andromeda d7 stubs --out DIR    # write the three D7 stub modules
EOF
}

d7_write_stub() {
  dest=$1
  name=$2
  desc=$3
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ stub $dest/$name"
    return 0
  fi
  mkdir -p "$dest/$name"
  cat > "$dest/$name/$name.info" <<EOF
name = $name (D7 stub for Backdrop upgrade)
description = $desc
core = 7.x
package = Andromeda stubs
EOF
  cat > "$dest/$name/$name.module" <<EOF
<?php
/**
 * @file
 * Empty Drupal 7 stub. Enable before the backdrop-ready dump so
 * Backdrop update.php keeps dependents enabled. Safe to delete
 * from the D7 tree after the dump is taken.
 */
EOF
  ok "stub $dest/$name"
}

cmd_d7_stubs() {
  out=${D7_OUT:-}
  [ -n "$out" ] || out=${D7_FROM:-./d7-stubs}
  enabled=""
  for c in \
    ${D7_FROM:+"$D7_FROM/enabled.txt"} \
    ${D7_OUT:+"$D7_OUT/enabled.txt"} \
    "$out/../enabled.txt"
  do
    [ -f "$c" ] && enabled=$c && break
  done
  if [ -n "$enabled" ]; then
    d7_scan_features "$enabled"
  fi
  if [ "${D7_NEED_EPLUS:-0}" -eq 0 ] && [ "${D7_HAS_UC:-0}" -eq 0 ]; then
    if [ -z "$enabled" ]; then
      note "no enabled.txt — run andromeda d7 test SITE first"
      note "writing entity_plus + entity_ui only (Ubercart stub skipped until a scan finds uc_*)"
      D7_NEED_EPLUS=1
    else
      echo "scan: no Rules / Search API / Ubercart enabled — no D7 stubs required"
      return 0
    fi
  fi
  echo "D7 stubs -> $out"
  echo "Enable these on the Drupal 7 site, then take the backdrop-ready dump."
  names=""
  if [ "$D7_NEED_EPLUS" -eq 1 ]; then
    d7_write_stub "$out" entity_plus "Stub: Backdrop Entity Plus will replace this."
    d7_write_stub "$out" entity_ui "Stub: Backdrop Entity UI will replace this."
    names="$names entity_plus entity_ui"
  fi
  if [ "$D7_HAS_UC" -eq 1 ]; then
    d7_write_stub "$out" ubercart "Stub: Backdrop Ubercart wrapper will replace this."
    names="$names ubercart"
    echo "  Ubercart detected — extra step:"
    echo "    https://github.com/backdrop-contrib/ubercart/wiki/Upgrading-Ubercart-from-Drupal-7"
  fi
  echo "next: copy $out/* into sites/all/modules on D7, then"
  echo "  drush en$names -y"
}

cmd_d7_toolkit() {
  platform=${D7_PLATFORM:-}
  [ -n "$platform" ] || platform=${D7_FROM:-}
  [ -n "$platform" ] || { echo "usage: andromeda d7 toolkit PLATFORM" >&2; return 2; }
  platform=$(slug "$platform")
  root=${PLATFORMS:-/srv/platforms}/$platform
  web=$root/web
  if [ "${DRYRUN:-0}" -eq 0 ] && [ ! -d "$web" ]; then
    echo "${PROG:-andromeda}: no platform $root — platform-add first" >&2
    return 1
  fi
  bee=bee
  if command -v bee_bin >/dev/null 2>&1; then
    bee=$(bee_bin)
  elif have bee; then
    bee=$(command -v bee)
  fi
  projects="coder_upgrade default_views_config entity_plus entity_ui d7compatible"
  [ "${D7_HAS_RULES:-0}" -eq 1 ] && projects="$projects rules_cmi"
  echo "toolkit on $platform: $projects"
  for p in $projects; do
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "+ $bee --root=$web download $p"
      continue
    fi
    as_root -u "${OWNER:-deploy}" "$bee" --root="$web" download "$p" || note "bee dl $p failed"
  done
  echo "enable coder_upgrade + default_views_config on a devel product to use the UIs"
  echo "  bee --root=$web --site=PRODUCT en coder_upgrade default_views_config"
}

cmd_d7_port() {
  src=${D7_FROM:-}
  platform=${D7_PLATFORM:-}
  [ -n "$src" ] && [ -d "$src" ] || { echo "usage: andromeda d7 port --from MODULE_DIR --platform NAME" >&2; return 2; }
  [ -n "$platform" ] || { echo "usage: andromeda d7 port --from MODULE_DIR --platform NAME" >&2; return 2; }
  platform=$(slug "$platform")
  root=${PLATFORMS:-/srv/platforms}/$platform
  web=$root/web
  dest=$root/files/coder_upgrade/old
  name=$(basename "$src")
  echo "port $src -> $dest/$name (coder_upgrade input)"
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ mkdir -p $dest"
    echo "+ cp -a $src $dest/$name"
    echo "then on a devel product with coder_upgrade enabled:"
    echo "  admin/config/development/coder-upgrade  (Directories tab)"
    return 0
  fi
  [ -d "$web" ] || { echo "${PROG:-andromeda}: no $web" >&2; return 1; }
  run_root mkdir -p "$dest"
  run_root cp -a "$src" "$dest/$name"
  if command -v chown_files >/dev/null 2>&1; then
    chown_files "$root/files/coder_upgrade" || true
  else
    run_root chown -R "${DAEMON:-www-data}:${GROUP:-www-admin}" "$root/files/coder_upgrade" || true
  fi
  ok "placed $name for coder_upgrade"
  echo "enable coder_upgrade on a devel product and Convert Files"
  echo "output: $root/files/coder_upgrade/new/$name"
  echo "copy the new tree into $web/modules/$name (or sites/PRODUCT/modules)"
}

# ---------------------------------------------------------------------------
# discover / dump (prep)
# ---------------------------------------------------------------------------

d7_is_root() { [ -f "$1/includes/bootstrap.inc" ] && [ -f "$1/modules/system/system.module" ]; }
d7_is_site() { [ -f "$1/settings.php" ] || [ -f "$1/drushrc.php" ] || [ -d "$1/files" ]; }
d7_is_bundle() {
  [ -f "$1/meta.txt" ] && { [ -f "$1/dump.sql" ] || [ -f "$1/dump.sql.gz" ] || [ -f "$1/enabled.txt" ]; }
}

d7_find_root() {
  start=$1
  d=$start
  i=0
  while [ "$i" -lt 8 ]; do
    d7_is_root "$d" && { printf '%s\n' "$d"; return 0; }
    [ "$d" = / ] && break
    d=$(dirname "$d")
    i=$((i + 1))
  done
  return 1
}

d7_php_string() {
  file=$1
  key=$2
  [ -f "$file" ] || return 1
  awk -v k="$key" '
    $0 ~ k {
      if (match($0, /'\''[^'\'']+'\''/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
      if (match($0, /"[^"]+"/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
    }
  ' "$file" 2>/dev/null || true
}

d7_load_creds() {
  site=$1
  DB_NAME=""; DB_USER=""; DB_PASS=""; DB_HOST="localhost"; DB_PORT="3306"
  rc=$site/drushrc.php
  if [ -f "$rc" ]; then
    DB_NAME=$(d7_php_string "$rc" db_name)
    DB_USER=$(d7_php_string "$rc" db_user)
    DB_PASS=$(d7_php_string "$rc" db_passwd)
    [ -z "$DB_PASS" ] && DB_PASS=$(d7_php_string "$rc" db_pass)
    DB_HOST=$(d7_php_string "$rc" db_host)
    [ -n "$DB_NAME" ] && [ -n "$DB_USER" ] && return 0
  fi
  for f in "$site/local.settings.php" "$site/settings.php"; do
    [ -f "$f" ] || continue
    grep -q "\$_SERVER" "$f" 2>/dev/null && ! grep -q "'database' => '[^']" "$f" && continue
    DB_NAME=$(d7_php_string "$f" "'database'")
    DB_USER=$(d7_php_string "$f" "'username'")
    DB_PASS=$(d7_php_string "$f" "'password'")
    DB_HOST=$(d7_php_string "$f" "'host'")
    [ -n "$DB_NAME" ] && [ -n "$DB_USER" ] && return 0
  done
  return 1
}

cmd_d7_prep() {
  [ -n "$D7_FROM" ] || { echo "d7 prep needs --from SITE_DIR" >&2; return 2; }
  [ -d "$D7_FROM" ] || { echo "no such directory $D7_FROM" >&2; return 1; }
  if d7_is_bundle "$D7_FROM"; then
    note "$D7_FROM is already a prep bundle"
    D7_OUT=${D7_OUT:-$D7_FROM}
    return 0
  fi
  site=$D7_FROM
  d7_is_site "$site" || { echo "$site is not a D7 site dir" >&2; return 1; }
  d7root=$(d7_find_root "$site" || true)
  [ -n "$D7_PRODUCT" ] || D7_PRODUCT=$(slug "$(basename "$site")")
  if [ -z "$D7_OUT" ]; then
    D7_OUT=$(pwd -P)/d7-${D7_PRODUCT}-$(stamp)
  fi
  echo "prep $site -> $D7_OUT  product=$D7_PRODUCT"
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ mkdir -p $D7_OUT/{files,private,modules,themes,stubs}"
    echo "+ dump SQL -> $D7_OUT/dump.sql.gz"
    echo "+ inventory enabled projects"
    return 0
  fi
  mkdir -p "$D7_OUT/files" "$D7_OUT/private" "$D7_OUT/modules" "$D7_OUT/themes" "$D7_OUT/stubs"

  dumped=0
  if [ -n "$D7_SQL" ]; then
    case $D7_SQL in
      *.gz) cp "$D7_SQL" "$D7_OUT/dump.sql.gz" ;;
      *) gzip -c "$D7_SQL" > "$D7_OUT/dump.sql.gz" ;;
    esac
    dumped=1
    ok "sql from --sql"
  fi
  if [ "$dumped" -eq 0 ] && [ -n "$D7_ALIAS" ] && have drush; then
    drush "$D7_ALIAS" sql-dump --gzip --result-file="$D7_OUT/dump.sql.gz" && dumped=1 && ok "sql from drush $D7_ALIAS"
  fi
  if [ "$dumped" -eq 0 ] && [ -n "$d7root" ] && have drush; then
    drush -r "$d7root" -l "$(basename "$site")" sql-dump --gzip --result-file="$D7_OUT/dump.sql.gz" && dumped=1 && ok "sql from drush -r"
  fi
  if [ "$dumped" -eq 0 ]; then
    d7_load_creds "$site" || { echo "could not dump SQL (pass --sql or --alias)" >&2; return 1; }
    have mysqldump || { echo "mysqldump not on PATH" >&2; return 1; }
    mysqldump --single-transaction --quick --no-tablespaces \
      -h "${DB_HOST:-localhost}" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASS" \
      "$DB_NAME" | gzip > "$D7_OUT/dump.sql.gz"
    dumped=1
    ok "sql from mysqldump $DB_NAME"
  fi

  src_files=${D7_FILES:-$site/files}
  [ -d "$src_files" ] && cp -a "$src_files/." "$D7_OUT/files/" && ok "files"
  src_priv=${D7_PRIVATE:-}
  if [ -z "$src_priv" ]; then
    for cand in "$site/private" "$site/files/private"; do
      [ -d "$cand" ] && src_priv=$cand && break
    done
  fi
  [ -n "$src_priv" ] && [ -d "$src_priv" ] && cp -a "$src_priv/." "$D7_OUT/private/" && ok "private"
  [ -d "$site/modules" ] && cp -a "$site/modules/." "$D7_OUT/modules/" 2>/dev/null || true
  [ -d "$site/themes" ] && cp -a "$site/themes/." "$D7_OUT/themes/" 2>/dev/null || true
  # BOA / Aegir convention: custom + features live under sites/all, not the site folder.
  if [ -n "${d7root:-}" ]; then
    for bucket in \
      "$d7root/sites/all/modules/custom" \
      "$d7root/sites/all/modules/features" \
      "$site/modules/custom" \
      "$site/modules/features"
    do
      [ -d "$bucket" ] || continue
      mkdir -p "$D7_OUT/modules"
      cp -a "$bucket/." "$D7_OUT/modules/" && ok "custom code $bucket"
    done
    for bucket in "$d7root/sites/all/themes" "$d7root/sites/all/libraries"; do
      [ -d "$bucket" ] || continue
      destn=${bucket##*/}
      mkdir -p "$D7_OUT/$destn"
      cp -a "$bucket/." "$D7_OUT/$destn/" && ok "$destn from sites/all"
    done
  fi

  enabled="$D7_OUT/enabled.txt"
  : > "$enabled"
  if d7_load_creds "$site" && have mysql; then
    extra=""
    [ -n "${DB_PASS:-}" ] && extra="-p${DB_PASS}"
    mysql -N -B -h "${DB_HOST:-localhost}" -P "${DB_PORT:-3306}" -u "$DB_USER" $extra "$DB_NAME" \
      -e "SELECT CONCAT(type, '	', name, '	', status, '	', schema_version) FROM system WHERE type IN ('module','theme') ORDER BY type, name;" \
      > "$enabled" || note "system table query failed"
  elif [ -n "$D7_ALIAS" ] && have drush; then
    drush "$D7_ALIAS" pml --status=enabled --format=list > "$D7_OUT/enabled-all.txt" || true
    [ -f "$D7_OUT/enabled-all.txt" ] && awk '{print "module\t"$1"\t1\t"}' "$D7_OUT/enabled-all.txt" > "$enabled"
  else
    note "no live DB — filesystem names only"
  fi

  {
    echo "product=$D7_PRODUCT"
    echo "from=$site"
    echo "d7root=${d7root:-}"
    echo "host_guess=$(basename "$site")"
    echo "dumped=$(date -Iseconds 2>/dev/null || date)"
    echo "alias=${D7_ALIAS:-}"
  } > "$D7_OUT/meta.txt"

  d7_collect_settings "$site" "$D7_OUT/settings.txt"
  d7_scan_features "$enabled"
  D7_OUT_SAVE=$D7_OUT
  D7_OUT=$D7_OUT/stubs
  cmd_d7_stubs
  D7_OUT=$D7_OUT_SAVE

  echo "install backdrop_upgrade_status on D7 and re-run test after you have used it:"
  echo "  https://www.drupal.org/project/backdrop_upgrade_status"
  if [ "$D7_NEED_EPLUS" -eq 1 ] || [ "$D7_HAS_UC" -eq 1 ]; then
    echo "enable the stubs written under $D7_OUT/stubs on D7, then take a second dump"
  else
    echo "no Entity Plus / Ubercart stubs required for this site"
  fi
  ok "bundle $D7_OUT"
}

# ---------------------------------------------------------------------------
# assess
# ---------------------------------------------------------------------------

d7_probe_contrib() {
  name=$1
  have curl || { echo UNKNOWN; return 0; }
  code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 \
    "https://github.com/backdrop-contrib/$name" 2>/dev/null || echo 000)
  case $code in
    200|301|302) echo AVAILABLE ;;
    404) echo MISSING ;;
    *) echo UNKNOWN ;;
  esac
}

cmd_d7_assess() {
  bundle=${D7_FROM:-}
  [ -n "$bundle" ] || { echo "d7 assess needs --from" >&2; return 2; }
  [ -d "$bundle" ] || { echo "no such directory $bundle" >&2; return 1; }
  if ! d7_is_bundle "$bundle"; then
    D7_OUT=${D7_OUT:-$(pwd -P)/d7-assess-$(stamp)}
    cmd_d7_prep || return $?
    bundle=$D7_OUT
  else
    D7_OUT=${D7_OUT:-$bundle}
  fi
  enabled="$bundle/enabled.txt"
  report=${D7_REPORT:-$bundle/assess.txt}
  [ -f "$enabled" ] || { echo "no $enabled — prep first" >&2; return 1; }
  echo "assess $bundle"
  missing=0
  stubs_needed=""
  available=""
  {
    echo "# andromeda d7 assess $(date -Iseconds 2>/dev/null || date)"
    echo "# source $bundle"
    echo "# catalog $(d7_find_catalog 2>/dev/null || echo missing)"
    echo
  } > "$report"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    type=$(printf '%s' "$line" | awk -F'	' '{print $1}')
    name=$(printf '%s' "$line" | awk -F'	' '{print $2}')
    status=$(printf '%s' "$line" | awk -F'	' '{print $3}')
    [ "$type" = module ] || continue
    [ -n "$name" ] || continue
    [ "$status" = 0 ] && continue

    class=$(d7_catalog_class "$name" || true)
    target=$(d7_catalog_target "$name" || true)
    case $class in
      TOOL_D7|TOOL_BD|THEME|STUB)
        printf 'TOOL    %s\n' "$name" >> "$report"
        continue
        ;;
      DROP)
        printf 'DROP    %s  (uninstall on D7 before convert)\n' "$name" >> "$report"
        continue
        ;;
      COREIN)
        printf 'CORE    %s  (Backdrop core — do not dl)\n' "$name" >> "$report"
        continue
        ;;
      CORE7)
        printf 'CORE7   %s\n' "$name" >> "$report"
        continue
        ;;
      REPLACE)
        printf 'REPLACE %s -> %s\n' "$name" "$target" >> "$report"
        [ -n "$target" ] && [ "$target" != "-" ] && available="$available $target"
        continue
        ;;
      CONTRIB)
        printf 'PORT    %s  (catalog: backdrop-contrib)\n' "$name" >> "$report"
        available="$available ${target:-$name}"
        continue
        ;;
    esac

    state=$(d7_probe_contrib "$name")
    case $state in
      AVAILABLE)
        printf 'PORT    %s  (github backdrop-contrib)\n' "$name" >> "$report"
        available="$available $name"
        ;;
      MISSING)
        printf 'MISSING %s  (no port — coder_upgrade or drop)\n' "$name" >> "$report"
        missing=$((missing + 1))
        ;;
      *)
        printf 'CHECK   %s  (no catalog, probe inconclusive)\n' "$name" >> "$report"
        available="$available $name"
        ;;
    esac
  done < "$enabled"

  d7_scan_features "$enabled"
  {
    echo
    if [ "$D7_HAS_UC" -eq 1 ]; then
      echo "SHOP    Ubercart enabled — D7 stub ubercart + Backdrop ubercart + entity_plus + entity_ui"
    else
      echo "SHOP    no Ubercart / uc_* — skip Ubercart stub and wiki"
    fi
    if [ "$D7_HAS_RULES" -eq 1 ]; then
      echo "RULES   enabled — D7 stubs entity_plus + entity_ui before dump"
    fi
    if [ "$D7_HAS_SEARCH_API" -eq 1 ]; then
      echo "SEARCH  search_api enabled — same entity_plus stubs"
    fi
    if [ "$D7_NEED_EPLUS" -eq 0 ]; then
      echo "STUBS   none required"
    else
      echo "STUBS   write: $(d7_stub_list | tr '\n' ' ')"
      echo "        enable on D7, then take the backdrop-ready dump"
      echo "        bee dl those same names on the Backdrop platform BEFORE updb"
    fi
    if [ -n "$D7_DROP_ENABLED" ]; then
      echo "UNINST  $D7_DROP_ENABLED"
    fi
  } >> "$report"

  echo "$available" | tr ' ,' '\n' | sed '/^$/d' | sort -u > "$bundle/to-download.txt"
  echo
  cat "$report"
  echo
  echo "to-download: $bundle/to-download.txt"
  if [ "$missing" -gt 0 ]; then
    bad "$missing enabled project(s) have no Backdrop port"
    echo "${PROG:-andromeda}: port with 'andromeda d7 port', replace, or --force" >&2
    [ "$D7_FORCE" -eq 1 ] && return 0
    return 1
  fi
  ok "assess clean"
}

D7_TAB=$(printf '\t')

d7_json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

d7_var_unserialize() {
  # stdin: PHP serialized value -> short string
  if have php; then
    php -r '
      $v = stream_get_contents(STDIN);
      $s = @unserialize($v);
      if ($s === false && $v !== serialize(false)) { echo trim($v); exit; }
      if (is_bool($s)) { echo $s ? "1" : "0"; exit; }
      if (is_scalar($s)) { echo $s; exit; }
      echo json_encode($s);
    ' 2>/dev/null || cat
  else
    cat
  fi
}

d7_collect_settings() {
  site=$1
  dest=$2
  : > "$dest"
  {
    echo "php=$(php -v 2>/dev/null | head -n 1 | sed 's/^PHP //;s/ .*//')"
    echo "d7root=${d7root:-}"
    echo "site_dir=$site"
  } >> "$dest"
  if [ -f "$site/settings.php" ]; then
    grep -q 'base_url' "$site/settings.php" && echo "settings_has_base_url=1" >> "$dest"
    grep -q 'cookie_domain' "$site/settings.php" && echo "settings_has_cookie_domain=1" >> "$dest"
    grep -q 'reverse_proxy' "$site/settings.php" && echo "settings_has_reverse_proxy=1" >> "$dest"
    grep -q 'update_free_access' "$site/settings.php" && echo "settings_has_update_free_access=1" >> "$dest"
  fi
  [ -d "$site/files" ] && echo "files_dir=$site/files" >> "$dest"
  [ -d "$site/private" ] && echo "private_dir=$site/private" >> "$dest"
  if [ -f "$site/drushrc.php" ]; then
    echo "aegir_drushrc=1" >> "$dest"
  fi
  if d7_load_creds "$site" 2>/dev/null; then
    echo "db_name=${DB_NAME:-}" >> "$dest"
    echo "db_user=${DB_USER:-}" >> "$dest"
    echo "db_host=${DB_HOST:-localhost}" >> "$dest"
    echo "db_pass_present=$([ -n "${DB_PASS:-}" ] && echo 1 || echo 0)" >> "$dest"
    if have mysql && [ -n "${DB_NAME:-}" ]; then
      extra=""
      [ -n "${DB_PASS:-}" ] && extra="-p${DB_PASS}"
      q() {
        mysql -N -B -h "${DB_HOST:-localhost}" -P "${DB_PORT:-3306}" -u "$DB_USER" $extra "$DB_NAME" \
          -e "SELECT value FROM variable WHERE name='$1' LIMIT 1;" 2>/dev/null || true
      }
      for key in site_name theme_default file_public_path file_private_path clean_url site_frontpage preprocess_css date_default_timezone user_register; do
        raw=$(q "$key")
        if [ -n "$raw" ]; then
          val=$(printf '%s' "$raw" | d7_var_unserialize | tr '\n' ' ' | sed 's/[[:space:]]*$//')
          echo "$key=$val" >> "$dest"
        fi
      done
      ver=$(mysql -N -B -h "${DB_HOST:-localhost}" -P "${DB_PORT:-3306}" -u "$DB_USER" $extra "$DB_NAME" \
        -e "SELECT schema_version FROM system WHERE name='system' AND type='module';" 2>/dev/null || true)
      [ -n "$ver" ] && echo "system_schema=$ver" >> "$dest"
      d7_deep_inventory "$dest.inv" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME"
      if [ -f "$dest.inv" ]; then
        cat "$dest.inv" >> "$dest"
        mkdir -p "$(dirname "$dest")"
        mv "$dest.inv" "$(dirname "$dest")/inventory.txt" 2>/dev/null || true
      fi
    fi
  fi
}

d7_mysql_e() {
  host=$1; port=$2; user=$3; pass=$4; db=$5; shift 5
  extra=""
  [ -n "$pass" ] && extra="-p$pass"
  mysql -N -B -h "$host" -P "$port" -u "$user" $extra "$db" -e "$1" 2>/dev/null || true
}

d7_deep_inventory() {
  dest=$1
  host=$2; port=$3; user=$4; pass=$5; db=$6
  : > "$dest"
  q() { d7_mysql_e "$host" "$port" "$user" "$pass" "$db" "$1"; }
  echo "nodes=$(q "SELECT COUNT(*) FROM node")" >> "$dest"
  echo "nodes_published=$(q "SELECT COUNT(*) FROM node WHERE status=1")" >> "$dest"
  echo "users=$(q "SELECT COUNT(*) FROM users WHERE uid>0")" >> "$dest"
  echo "aliases=$(q "SELECT COUNT(*) FROM url_alias")" >> "$dest"
  echo "files_managed=$(q "SELECT COUNT(*) FROM file_managed")" >> "$dest"
  echo "blocks_enabled=$(q "SELECT COUNT(*) FROM block WHERE status=1")" >> "$dest"
  echo "fields=$(q "SELECT COUNT(*) FROM field_config")" >> "$dest"
  echo "views_in_db=$(q "SELECT COUNT(*) FROM views_view")" >> "$dest"
  echo "php_filters=$(q "SELECT COUNT(*) FROM filter WHERE module='php' AND status=1")" >> "$dest"
  echo "charset=$(q "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db'")" >> "$dest"
  types=$(q "SELECT CONCAT(type, ':', COUNT(*)) FROM node GROUP BY type")
  echo "node_types=$(printf '%s' "$types" | tr '\n' ' ')" >> "$dest"
  echo "has_features=$(q "SELECT COUNT(*) FROM system WHERE name='features' AND status=1")" >> "$dest"
  echo "has_commerce=$(q "SELECT COUNT(*) FROM system WHERE name='commerce' AND status=1")" >> "$dest"
  echo "has_panels=$(q "SELECT COUNT(*) FROM system WHERE name='panels' AND status=1")" >> "$dest"
}

d7_patch_themes() {
  dir=$1
  [ -d "$dir" ] || return 0
  n=0
  find "$dir" -name '*.info' -type f 2>/dev/null | while IFS= read -r f || [ -n "$f" ]; do
    grep -q '^core *= *7' "$f" 2>/dev/null || continue
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "+ patch theme $f"
      continue
    fi
    grep -q '^backdrop' "$f" || printf '\nbackdrop = 1.x\n' >> "$f"
    grep -q '^type' "$f" || printf 'type = theme\n' >> "$f"
    if ! grep -q '^base theme' "$f"; then
      printf 'base theme = d7compatible\n' >> "$f"
    fi
    n=$((n + 1))
    ok "theme .info $f"
  done
}

d7_setting() {
  file=$1
  key=$2
  [ -f "$file" ] || return 0
  sed -n "s/^$key=//p" "$file" | head -n 1
}

d7_mod_action() {
  class=$1
  status=$2
  case $status in
    0) echo skip; return ;;
  esac
  case $class in
    DROP) echo uninstall ;;
    COREIN|CORE7) echo keep ;;
    REPLACE) echo replace ;;
    CONTRIB|PORT) echo download ;;
    STUB|TOOL_D7|TOOL_BD|THEME) echo tool ;;
    *) echo review ;;
  esac
}

d7_write_modules_tsv() {
  enabled=$1
  dest=$2
  printf 'name\ttype\tstatus\tclass\ttarget\taction\n' > "$dest"
  [ -f "$enabled" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    type=$(printf '%s' "$line" | awk -F'	' '{print $1}')
    name=$(printf '%s' "$line" | awk -F'	' '{print $2}')
    status=$(printf '%s' "$line" | awk -F'	' '{print $3}')
    [ -n "$name" ] || continue
    class=$(d7_catalog_class "$name" || true)
    target=$(d7_catalog_target "$name" || true)
    [ -n "$class" ] || class=UNKNOWN
    [ -n "$target" ] || target=$name
    action=$(d7_mod_action "$class" "$status")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$type" "$status" "$class" "$target" "$action" >> "$dest"
  done < "$enabled"
}

d7_step_line() {
  # id phase auto verb title command
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

d7_write_plan() {
  out=$1
  source_path=${2:-}
  enabled="$out/enabled.txt"
  settings="$out/settings.txt"
  modules="$out/modules.tsv"
  steps="$out/steps.tsv"
  statusf="$out/status.tsv"
  play="$out/playbook.txt"
  plan="$out/plan.json"
  src_site=$source_path
  if [ -f "$out/meta.txt" ]; then
    meta_from=$(sed -n 's/^from=//p' "$out/meta.txt" | head -n 1)
    [ -n "$meta_from" ] && src_site=$meta_from
  fi

  [ -f "$settings" ] || { [ -n "$src_site" ] && [ -d "$src_site" ] && d7_collect_settings "$src_site" "$settings" || : > "$settings"; }
  d7_write_modules_tsv "$enabled" "$modules"
  d7_scan_features "$enabled"

  product=$(sed -n 's/^product=//p' "$out/meta.txt" 2>/dev/null | head -n 1)
  [ -n "$product" ] || product=$(slug "$(basename "${src_site:-site}")")
  plat=${D7_PLATFORM:-PLATFORM}
  host=${D7_HOST:-${product}.${ANDROMEDA_ROLE:-devel}}
  phpv=$(d7_setting "$settings" php)
  sname=$(d7_setting "$settings" site_name)
  theme=$(d7_setting "$settings" theme_default)
  fpub=$(d7_setting "$settings" file_public_path)
  dbn=$(d7_setting "$settings" db_name)

  : > "$steps"
  d7_step_line backup d7-prep true prep "Snapshot SQL and files" \
    "andromeda d7 prep --from ${src_site:-SITE} --out $out" >> "$steps"
  d7_step_line upgrade-status d7-prep false manual "Install backdrop_upgrade_status on D7" \
    "drush dl backdrop_upgrade_status && drush en backdrop_upgrade_status update -y" >> "$steps"
  if [ -n "$D7_DROP_ENABLED" ]; then
    for m in $D7_DROP_ENABLED; do
      [ -n "$m" ] || continue
      cmd="drush pm-disable $m -y && drush pm-uninstall $m -y"
      [ "$m" = php ] && cmd="# strip PHP Filter bodies first; $cmd"
      d7_step_line "uninstall-$m" d7-prep false uninstall "Uninstall D7 module $m" "$cmd" >> "$steps"
    done
  fi
  if [ "$D7_NEED_EPLUS" -eq 1 ] || [ "$D7_HAS_UC" -eq 1 ]; then
    names=$(d7_stub_list | tr '\n' ' ')
    d7_step_line stubs d7-prep true stubs "Write and enable D7 stubs: $names" \
      "andromeda d7 stubs --from $out --out $out/stubs" >> "$steps"
    d7_step_line stubs-enable d7-prep false uninstall "Enable stubs on the live D7 site" \
      "drush en $names -y" >> "$steps"
  fi
  d7_step_line keep-corein d7-prep false manual "Leave Views/Date/Token/CTools/Pathauto enabled" \
    "# no-op; Backdrop core reads that data during updb" >> "$steps"
  if [ -n "$D7_CUSTOM" ]; then
    for m in $D7_CUSTOM; do
      [ -n "$m" ] || continue
      d7_step_line "port-$m" d7-prep false port "Port or replace custom/uncatalogued module $m" \
        "andromeda d7 port --from MODULE_DIR/$m --platform $plat" >> "$steps"
    done
  fi
  d7_step_line dump-ready d7-prep true prep "Take backdrop-ready dump after uninstalls/stubs" \
    "andromeda d7 prep --from ${src_site:-SITE} --out $out" >> "$steps"
  d7_step_line toolkit knarr true toolkit "Download Backdrop conversion tools onto the platform" \
    "andromeda d7 toolkit $plat" >> "$steps"
  d7_step_line convert knarr true convert "Import dump, utf8mb4, wipe cache_*, bee -y update-db (writes JSON config)" \
    "andromeda d7 convert --from $out --platform $plat --product $product --host $host" >> "$steps"
  d7_step_line theme-patch knarr true theme "Patch copied D7 themes: backdrop=1.x + base theme d7compatible" \
    "andromeda d7 theme-patch --platform $plat --product $product" >> "$steps"
  d7_step_line config-export knarr true cex "bee config-export: copy active JSON into staging for git / env promote" \
    "bee --root=WEB --site=$product config-export" >> "$steps"
  d7_step_line views-code knarr false views "Code-provided D7 Views only: default_views_config UI -> views.view.NAME.json" \
    "bee --root=WEB --site=$product en default_views_config; open admin/structure/views/default-views-convert" >> "$steps"
  if [ "$D7_HAS_RULES" -eq 1 ]; then
    d7_step_line rules-cmi knarr false rules "Optional: rules_cmi transfers Rules tables to CMI JSON after updb" \
      "bee --root=WEB --site=$product en rules_cmi; visit admin/config/workflow/Rules_cmi" >> "$steps"
  fi
  d7_step_line layout-review knarr false manual "Review Layouts: D7 blocks/Panels/Context land in Default + Admin only" \
    "# admin/structure/layouts — recreate region placement Backdrop does not guess" >> "$steps"
  d7_step_line search-reindex knarr false manual "Rebuild Search / Search API indexes after convert" \
    "bee --root=WEB --site=$product cron" >> "$steps"
  d7_step_line attach knarr true attach "Apache alias + site-check" \
    "andromeda d7 attach --platform $plat --product $product --host $host" >> "$steps"
  d7_step_line check knarr true check "andromeda site-check after convert" \
    "andromeda site-check $plat $product --host $host" >> "$steps"

  if [ ! -f "$statusf" ]; then
    awk -F'	' 'NF>=1 && $1!=""{print $1"\ttodo"}' "$steps" > "$statusf"
  fi

  # playbook from the same rows
  {
    echo "# D7 -> Backdrop playbook"
    echo "# machine plan: $plan"
    echo "# apply with: andromeda d7 apply --plan $out"
    echo "# written $(date -Iseconds 2>/dev/null || date)"
    echo
    echo "## Site"
    echo "- source: $src_site"
    echo "- product: $product"
    echo "- php: ${phpv:-unknown}"
    echo "- site_name: ${sname:-unknown}"
    echo "- theme_default: ${theme:-unknown}"
    echo "- file_public_path: ${fpub:-}"
    echo "- db: ${dbn:-unknown}@$(d7_setting "$settings" db_host)"
    echo "- system_schema: $(d7_setting "$settings" system_schema)"
    echo
    echo "## Features"
    echo "- Ubercart: $([ "$D7_HAS_UC" -eq 1 ] && echo YES || echo no)"
    echo "- Rules: $([ "$D7_HAS_RULES" -eq 1 ] && echo YES || echo no)"
    echo "- Search API: $([ "$D7_HAS_SEARCH_API" -eq 1 ] && echo YES || echo no)"
    echo "- Entity Plus stubs: $([ "$D7_NEED_EPLUS" -eq 1 ] && echo required || echo not required)"
    echo "- uninstall: ${D7_DROP_ENABLED:-none}"
    echo "- uncatalogued: ${D7_CUSTOM:-none}"
    echo "- themes: ${D7_THEMES_EN:-unknown}"
    echo
    if [ -f "$out/inventory.txt" ] || [ -f "$settings" ]; then
      echo "## Inventory"
      for k in nodes nodes_published users aliases files_managed blocks_enabled fields views_in_db php_filters charset node_types has_features has_commerce has_panels system_schema; do
        val=$(d7_setting "$settings" "$k")
        [ -z "$val" ] && [ -f "$out/inventory.txt" ] && val=$(d7_setting "$out/inventory.txt" "$k")
        [ -n "$val" ] && echo "- $k: $val"
      done
      echo
    fi
    echo "## Modules (enabled)"
    if [ -f "$modules" ]; then
      awk -F'	' 'NR>1 && $2=="module" && $3!="0" {printf "- %-28s %-8s -> %-16s %s\n", $1, $4, $5, $6}' "$modules"
    fi
    echo
    echo "## Steps (andromeda d7 apply --plan $out)"
    i=1
    while IFS="$D7_TAB" read -r id phase auto verb title command || [ -n "$id" ]; do
      [ -n "$id" ] || continue
      st=$(awk -F'	' -v i="$id" '$1==i{print $2; exit}' "$statusf")
      [ -n "$st" ] || st=todo
      printf '%2d. [%s] %s\n' "$i" "$st" "$title"
      echo "    id=$id phase=$phase auto=$auto verb=$verb"
      echo "    $command"
      i=$((i + 1))
    done < "$steps"
    echo
    echo "## Apply"
    echo "  andromeda -n d7 apply --plan $out"
    echo "  andromeda    d7 apply --plan $out --yes"
    echo "  andromeda    d7 apply --plan $out --step stubs"
    if [ "$D7_HAS_UC" -eq 0 ]; then
      echo
      echo "## Not this site"
      echo "- skip Ubercart stub, wiki, and bee dl ubercart"
    fi
  } > "$play"

  # plan.json
  {
    echo '{'
    echo "  \"version\": 1,"
    echo "  \"kind\": \"andromeda-d7-plan\","
    echo "  \"scanned_at\": \"$(date -Iseconds 2>/dev/null || date)\","
    echo "  \"source\": \"$(d7_json_esc "$src_site")\","
    echo "  \"out\": \"$(d7_json_esc "$out")\","
    echo "  \"product\": \"$(d7_json_esc "$product")\","
    echo "  \"platform\": \"$(d7_json_esc "$plat")\","
    echo "  \"host\": \"$(d7_json_esc "$host")\","
    echo '  "features": {'
    echo "    \"ubercart\": $([ "$D7_HAS_UC" -eq 1 ] && echo true || echo false),"
    echo "    \"rules\": $([ "$D7_HAS_RULES" -eq 1 ] && echo true || echo false),"
    echo "    \"search_api\": $([ "$D7_HAS_SEARCH_API" -eq 1 ] && echo true || echo false),"
    echo "    \"entity\": $([ "$D7_HAS_ENTITY" -eq 1 ] && echo true || echo false),"
    echo "    \"entity_plus_stubs\": $([ "$D7_NEED_EPLUS" -eq 1 ] && echo true || echo false)"
    echo '  },'
    echo '  "site": {'
    echo "    \"php\": \"$(d7_json_esc "$phpv")\","
    echo "    \"site_name\": \"$(d7_json_esc "$sname")\","
    echo "    \"theme_default\": \"$(d7_json_esc "$theme")\","
    echo "    \"file_public_path\": \"$(d7_json_esc "$fpub")\","
    echo "    \"db_name\": \"$(d7_json_esc "$dbn")\","
    echo "    \"db_host\": \"$(d7_json_esc "$(d7_setting "$settings" db_host)")\","
    echo "    \"system_schema\": \"$(d7_json_esc "$(d7_setting "$settings" system_schema)")\""
    echo '  },'
    echo '  "modules": ['
    first=1
    if [ -f "$modules" ]; then
      tail -n +2 "$modules" | while IFS="$D7_TAB" read -r name type status class target action || [ -n "$name" ]; do
        [ -n "$name" ] || continue
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {"name":"%s","type":"%s","status":"%s","class":"%s","target":"%s","action":"%s"}' \
          "$(d7_json_esc "$name")" "$(d7_json_esc "$type")" "$(d7_json_esc "$status")" \
          "$(d7_json_esc "$class")" "$(d7_json_esc "$target")" "$(d7_json_esc "$action")"
      done
    fi
    echo
    echo '  ],'
    echo '  "steps": ['
    first=1
    while IFS="$D7_TAB" read -r id phase auto verb title command || [ -n "$id" ]; do
      [ -n "$id" ] || continue
      st=$(awk -F'	' -v i="$id" '$1==i{print $2; exit}' "$statusf")
      [ -n "$st" ] || st=todo
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    {"id":"%s","phase":"%s","auto":%s,"verb":"%s","status":"%s","title":"%s","command":"%s"}' \
        "$(d7_json_esc "$id")" "$(d7_json_esc "$phase")" \
        "$([ "$auto" = true ] && echo true || echo false)" \
        "$(d7_json_esc "$verb")" "$(d7_json_esc "$st")" \
        "$(d7_json_esc "$title")" "$(d7_json_esc "$command")"
    done < "$steps"
    echo
    echo '  ]'
    echo '}'
  } > "$plan"

  d7_write_sysadmin_tutorial "$out" "$src_site"
}

d7_find_static_tutorial() {
  for d in \
    "${ANDROMEDA_LIB:-}/../docs" \
    "${LIBDIR:-}/../docs" \
    /usr/local/share/andromeda \
    /usr/local/share/andromeda/docs \
    /usr/local/lib/andromeda/../docs \
    /srv/andromeda/docs
  do
    [ -n "$d" ] && [ -f "$d/d7-migration.txt" ] && { echo "$d/d7-migration.txt"; return 0; }
  done
  here=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || here=""
  for d in "$here/../docs" "$here/docs"; do
    [ -f "$d/d7-migration.txt" ] && { echo "$d/d7-migration.txt"; return 0; }
  done
  return 1
}

d7_write_sysadmin_tutorial() {
  out=$1
  src=${2:-}
  dest=$out/TUTORIAL.txt
  product=$(sed -n 's/^product=//p' "$out/meta.txt" 2>/dev/null | head -n 1)
  [ -n "$product" ] || product=${D7_PRODUCT:-PRODUCT}
  plat=${D7_PLATFORM:-PLATFORM}
  host=${D7_HOST:-$product.devel}
  web=/srv/platforms/$plat/web
  steps=$out/steps.tsv
  statusf=$out/status.tsv
  static=$(d7_find_static_tutorial || true)

  {
    echo "# Site tutorial — $product"
    echo "# written $(date -Iseconds 2>/dev/null || date)"
    echo "# full handbook: ${static:-docs/d7-migration.txt}"
    echo
    echo "system: os: Devuan (sysvinit) hostname: starhq.knarr"
    echo
    echo "platform  $plat"
    echo "product   $product"
    echo "host      $host"
    echo "web       $web"
    echo "source    $src"
    echo "plan      $out"
    echo
    echo "Do not type sudo andromeda. Do not bee install."
    echo
    echo "## Done (automated)"
    if [ -f "$steps" ] && [ -f "$statusf" ]; then
      while IFS="$D7_TAB" read -r id phase auto verb title command || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        st=$(awk -F'	' -v i="$id" '$1==i{print $2; exit}' "$statusf")
        [ "$st" = done ] || [ "$st" = skip ] || continue
        echo "  [$st] $id — $title"
      done < "$steps"
    fi
    echo
    echo "## Your remaining steps"
    echo
    echo "  1. Log in"
    echo "       http://$host/user"
    echo "       bee --root=$web --site=$product user-password 1 --password NEW"
    echo
    echo "  2. Layouts — D7 blocks/Panels/Context are NOT rebuilt 1:1"
    echo "       http://$host/admin/structure/layouts"
    echo
    echo "  3. Theme — look at the front page; edit"
    echo "       $web/sites/$product/themes"
    echo "       andromeda d7 theme-patch --platform $plat --product $product"
    echo
    echo "  4. Code-only Views (hook_views_default_views)"
    echo "       bee --root=$web --site=$product en default_views_config"
    echo "       http://$host/admin/structure/views/default-views-convert"
    echo "       bee --root=$web --site=$product config-export"
    echo
    if [ "${D7_HAS_RULES:-0}" -eq 1 ]; then
      echo "  5. Rules (this site has Rules enabled)"
      echo "       bee --root=$web --site=$product en rules_cmi"
      echo "       http://$host/admin/config/workflow/Rules_cmi"
      echo
    fi
    if [ "${D7_HAS_UC:-0}" -eq 1 ]; then
      echo "  6. Ubercart (this site has a shop)"
      echo "       https://github.com/backdrop-contrib/ubercart/wiki/Upgrading-Ubercart-from-Drupal-7"
      echo "       re-enter payment keys; test a cart on $host"
      echo
    fi
    echo "  7. Search / cron"
    echo "       bee --root=$web --site=$product cron"
    echo
    if [ -n "${D7_CUSTOM:-}" ]; then
      echo "  8. Uncatalogued modules — port or drop"
      echo "       $D7_CUSTOM"
      echo "       andromeda d7 port --from MODULE_DIR --platform $plat"
      echo
    fi
    echo "  9. Commit CMI + backup"
    echo "       cd /srv/platforms/$plat"
    echo "       git add web/sites/$product config/$product"
    echo "       git commit -m \"$product: D7 convert\""
    echo "       andromeda site-check $plat $product --host $host"
    echo "       andromeda site-backup $plat $product"
    echo
    echo "  10. Promote (on the VPS, not on devel)"
    echo "       andromeda promote $plat --to test"
    echo "       andromeda promote $plat --to live"
    echo
    echo "## Still open on the plan"
    if [ -f "$steps" ]; then
      open=0
      while IFS="$D7_TAB" read -r id phase auto verb title command || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        st=$(awk -F'	' -v i="$id" '$1==i{print $2; exit}' "$statusf")
        [ -n "$st" ] || st=todo
        case $st in
          done|skip) continue ;;
        esac
        open=1
        echo "  [$st] $id — $title"
        echo "         $command"
        echo "         andromeda d7 apply --plan $out --step $id"
      done < "$steps"
      [ "$open" -eq 1 ] || echo "  (none — every recorded step is done or skipped)"
    fi
    echo
    echo "Reprint:  andromeda d7 tutorial --plan $out"
    echo "Handbook: ${static:-docs/d7-migration.txt}"
  } > "$dest"
  echo "tutorial $dest"
}

cmd_d7_tutorial() {
  plan=${D7_PLAN:-}
  [ -n "$plan" ] || plan=${D7_FROM:-}
  [ -n "$plan" ] || { echo "usage: andromeda d7 tutorial --plan DIR" >&2; return 2; }
  dir=$plan
  [ -f "$plan" ] && dir=$(dirname "$plan")
  [ -d "$dir" ] || { echo "no plan dir $dir" >&2; return 1; }
  src=$(sed -n 's/^from=//p' "$dir/meta.txt" 2>/dev/null | head -n 1)
  d7_write_sysadmin_tutorial "$dir" "$src"
  if [ -f "$dir/TUTORIAL.txt" ]; then
    cat "$dir/TUTORIAL.txt"
  fi
  static=$(d7_find_static_tutorial || true)
  if [ -n "$static" ] && [ "${D7_YES:-0}" -eq 0 ]; then
    echo
    echo "full handbook: $static"
  fi
}

d7_status_set() {
  file=$1
  id=$2
  st=$3
  tmp=$file.tmp
  awk -F'	' -v i="$id" -v s="$st" 'BEGIN{OFS="\t"} $1==i{$2=s} {print}' "$file" > "$tmp" && mv "$tmp" "$file"
}

cmd_d7_apply() {
  plan=${D7_PLAN:-}
  [ -n "$plan" ] || plan=${D7_FROM:-}
  [ -n "$plan" ] || { echo "usage: andromeda d7 apply --plan DIR|plan.json [--step ID]" >&2; return 2; }
  dir=$plan
  [ -f "$plan" ] && dir=$(dirname "$plan")
  [ -d "$dir" ] || { echo "no plan dir $dir" >&2; return 1; }
  steps=$dir/steps.tsv
  statusf=$dir/status.tsv
  [ -f "$steps" ] || { echo "no $steps — run andromeda d7 test first" >&2; return 1; }
  [ -f "$statusf" ] || awk -F'	' '{print $1"\ttodo"}' "$steps" > "$statusf"

  echo "apply plan $dir"
  fail=0
  while IFS="$D7_TAB" read -r id phase auto verb title command || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    if [ -n "${D7_STEP:-}" ] && [ "$D7_STEP" != "$id" ]; then
      continue
    fi
    st=$(awk -F'	' -v i="$id" '$1==i{print $2; exit}' "$statusf")
    [ -n "$st" ] || st=todo
    case $st in
      done|skip) echo "  skip $id ($st)"; continue ;;
    esac
    echo "  step $id [$st] $title"
    echo "    $command"
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "+ $command"
      continue
    fi
    if [ "$auto" != true ]; then
      if d7_ask "mark $id done after you run it by hand?" n; then
        d7_status_set "$statusf" "$id" done
      else
        echo "    blocked (not auto; rerun with --step $id after you finish it)"
        d7_status_set "$statusf" "$id" blocked
        fail=1
      fi
      continue
    fi
    if ! d7_ask "run $id now?" y; then
      echo "    skipped"
      continue
    fi
    case $verb in
      prep)
        D7_FROM=$(sed -n 's/^from=//p' "$dir/meta.txt" | head -n 1)
        D7_OUT=$dir
        if cmd_d7_prep; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        ;;
      stubs)
        D7_FROM=$dir
        save=$D7_OUT
        D7_OUT=$dir/stubs
        if cmd_d7_stubs; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        D7_OUT=$save
        ;;
      toolkit)
        D7_PLATFORM=${D7_PLATFORM:-}
        [ -n "$D7_PLATFORM" ] || D7_PLATFORM=$(sed -n 's/^  "platform": "//p' "$dir/plan.json" | head -n 1 | sed 's/",\?$//')
        if cmd_d7_toolkit; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        ;;
      convert)
        D7_FROM=$dir
        D7_OUT=$dir
        if cmd_d7_convert; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        ;;
      attach)
        if cmd_d7_attach; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        ;;
      check)
        if have andromeda && [ -n "${D7_PLATFORM:-}" ] && [ -n "${D7_PRODUCT:-}" ]; then
          andromeda site-check "$D7_PLATFORM" "$D7_PRODUCT" --host "${D7_HOST:-}" || fail=1
        fi
        d7_status_set "$statusf" "$id" done
        ;;
      cex)
        if cmd_d7_cex "$dir"; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        ;;
      theme)
        if cmd_d7_theme_patch; then d7_status_set "$statusf" "$id" done; else d7_status_set "$statusf" "$id" blocked; fail=1; fi
        ;;
      *)
        echo "    unknown verb $verb — mark by hand"
        fail=1
        ;;
    esac
  done < "$steps"
  d7_write_plan "$dir" "$(sed -n 's/^from=//p' "$dir/meta.txt" | head -n 1)"
  echo "status:   $statusf"
  echo "plan:     $dir/plan.json"
  echo "tutorial: $dir/TUTORIAL.txt"
  echo "handbook: $(d7_find_static_tutorial 2>/dev/null || echo docs/d7-migration.txt)"
  return $fail
}

cmd_d7_theme_patch() {
  plat=${D7_PLATFORM:-}
  prod=${D7_PRODUCT:-}
  [ -n "$plat" ] || plat=${D7_FROM:-}
  [ -n "$plat" ] && [ -n "$prod" ] || { echo "usage: andromeda d7 theme-patch --platform NAME --product NAME" >&2; return 2; }
  web=${PLATFORMS:-/srv/platforms}/$(slug "$plat")/web
  echo "theme-patch $web/sites/$(slug "$prod")/themes"
  d7_patch_themes "$web/sites/$(slug "$prod")/themes"
}

cmd_d7_cex() {
  dir=${1:-}
  plat=${D7_PLATFORM:-}
  prod=${D7_PRODUCT:-}
  if [ -z "$plat" ] && [ -f "${dir:-}/plan.json" ]; then
    plat=$(sed -n 's/^  "platform": "//p' "$dir/plan.json" | head -n 1 | sed 's/",\?$//')
    prod=$(sed -n 's/^  "product": "//p' "$dir/plan.json" | head -n 1 | sed 's/",\?$//')
  fi
  [ -n "$plat" ] && [ -n "$prod" ] || { echo "cex needs --platform and --product" >&2; return 2; }
  web=${PLATFORMS:-/srv/platforms}/$plat/web
  bee=$(d7_bee) || return 1
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ $bee --root=$web --site=$prod config-export"
    return 0
  fi
  as_root -u "${OWNER:-deploy}" "$bee" --root="$web" --site="$prod" config-export
}

cmd_d7_test() {
  path=${D7_FROM:-}
  if [ -z "$path" ]; then
    if [ -t 0 ]; then
      printf '  D7 site dir / bundle / platform root: ' >&2
      IFS= read -r path || true
      D7_FROM=$path
    fi
  fi
  [ -n "$path" ] || { echo "usage: andromeda d7 test SITE_DIR|BUNDLE" >&2; return 2; }
  [ -d "$path" ] || { echo "no such directory $path" >&2; return 1; }

  # Allow a platform docroot that contains several sites.
  if ! d7_is_site "$path" && ! d7_is_bundle "$path"; then
    picked=$(d7_pick_site_under "$path" || true)
    if [ -n "$picked" ]; then
      path=$picked
      D7_FROM=$picked
    fi
  fi
  d7_is_site "$path" || d7_is_bundle "$path" || {
    echo "$path is not a D7 site, platform with sites/, or prep bundle" >&2
    return 1
  }

  echo "d7 test $path"
  echo "  php=$(php -v 2>/dev/null | head -n 1 | sed 's/^PHP //;s/ .*//')"
  d7root=$(d7_find_root "$path" 2>/dev/null || true)
  [ -n "$d7root" ] && echo "  d7root=$d7root"

  if ! d7_is_bundle "$path"; then
    if d7_ask "snapshot this site into a prep bundle (sql + files + inventory)?" n; then
      D7_OUT=${D7_OUT:-$(pwd -P)/d7-$(slug "$(basename "$path")")-$(stamp)}
      cmd_d7_prep || return $?
      path=$D7_OUT
      D7_FROM=$D7_OUT
    else
      # live inventory only — enough to write a playbook
      D7_OUT=${D7_OUT:-$(pwd -P)/d7-test-$(slug "$(basename "$path")")-$(stamp)}
      if [ "${DRYRUN:-0}" -eq 1 ]; then
        echo "+ mkdir -p $D7_OUT"
      else
        mkdir -p "$D7_OUT"
        enabled="$D7_OUT/enabled.txt"
        : > "$enabled"
        if d7_load_creds "$path" && have mysql; then
          extra=""
          [ -n "${DB_PASS:-}" ] && extra="-p${DB_PASS}"
          mysql -N -B -h "${DB_HOST:-localhost}" -P "${DB_PORT:-3306}" -u "$DB_USER" $extra "$DB_NAME" \
            -e "SELECT CONCAT(type, '	', name, '	', status, '	', schema_version) FROM system WHERE type IN ('module','theme') ORDER BY type, name;" \
            > "$enabled" || note "system table query failed"
        elif [ -n "$D7_ALIAS" ] && have drush; then
          drush "$D7_ALIAS" pml --status=enabled --format=list 2>/dev/null | awk '{print "module\t"$1"\t1\t"}' > "$enabled"
        else
          note "no DB creds — filesystem module names only (status unknown)"
          d7root=${d7root:-}
          for bucket in ${d7root:+"$d7root/sites/all/modules"} "$path/modules"; do
            [ -d "$bucket" ] || continue
            for m in "$bucket"/*; do
              [ -d "$m" ] || continue
              printf 'module\t%s\t?\t\n' "$(basename "$m")" >> "$enabled"
            done
          done
        fi
        {
          echo "product=$(slug "$(basename "$path")")"
          echo "from=$path"
          echo "d7root=${d7root:-}"
          echo "test_only=1"
        } > "$D7_OUT/meta.txt"
      fi
      path=$D7_OUT
      D7_FROM=$D7_OUT
    fi
  else
    D7_OUT=${D7_OUT:-$path}
  fi

  # Classify. Do not fail the whole test on MISSING ports — playbook lists them.
  save_force=$D7_FORCE
  D7_FORCE=1
  cmd_d7_assess
  rc=$?
  D7_FORCE=$save_force

  enabled="${D7_OUT:-$path}/enabled.txt"
  [ -f "$enabled" ] && d7_scan_features "$enabled"
  src_live=$(sed -n 's/^from=//p' "${D7_OUT:-$path}/meta.txt" 2>/dev/null | head -n 1)
  [ -n "$src_live" ] || src_live=$path
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ write ${D7_OUT:-$path}/plan.json playbook.txt modules.tsv steps.tsv"
  else
    if [ -d "$src_live" ] && ! d7_is_bundle "$src_live"; then
      d7_collect_settings "$src_live" "${D7_OUT:-$path}/settings.txt"
    elif [ -f "${D7_OUT:-$path}/settings.txt" ]; then
      :
    else
      : > "${D7_OUT:-$path}/settings.txt"
    fi
    d7_write_plan "${D7_OUT:-$path}" "$src_live"
    echo
    echo "-------- playbook ${D7_OUT:-$path}/playbook.txt --------"
    cat "${D7_OUT:-$path}/playbook.txt"
    echo "--------"
    echo "plan: ${D7_OUT:-$path}/plan.json"
  fi

  if [ "$D7_NEED_EPLUS" -eq 1 ] || [ "$D7_HAS_UC" -eq 1 ]; then
    if d7_ask "write the D7 stubs this scan requires into ${D7_OUT:-.}/stubs?" y; then
      save=$D7_OUT
      D7_OUT=${D7_OUT:-.}/stubs
      cmd_d7_stubs
      D7_OUT=$save
    fi
  else
    echo "  no D7 stubs to write (no Rules / Search API / Ubercart)"
  fi

  if [ -n "$D7_CUSTOM" ]; then
    echo "  uncatalogued modules: $D7_CUSTOM"
    echo "  next: andromeda d7 port --from MODULE_DIR --platform NAME"
    echo "        (coder_upgrade) or replace / uninstall on D7"
  fi

  echo
  echo "next:"
  echo "  andromeda -n d7 apply --plan ${D7_OUT:-$path}"
  echo "  andromeda    d7 apply --plan ${D7_OUT:-$path} --yes"
  echo "  # or one step: andromeda d7 apply --plan ${D7_OUT:-$path} --step stubs"
  if [ "$rc" -ne 0 ] && [ "$D7_FORCE" -eq 0 ]; then
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# convert / attach
# ---------------------------------------------------------------------------

d7_refuse_root() {
  [ "${DRYRUN:-0}" -eq 1 ] && return 0
  if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
    echo "${PROG:-andromeda}: do not run d7 convert/attach as root or under sudo" >&2
    return 2
  fi
  return 0
}

d7_bee() {
  if have bee; then
    command -v bee
  elif [ "${DRYRUN:-0}" -eq 1 ]; then
    echo bee
  elif command -v bee_bin >/dev/null 2>&1; then
    bee_bin
  else
    echo "${PROG:-andromeda}: bee not on PATH" >&2
    return 1
  fi
}

d7_crdir() {
  if have crdir; then
    command -v crdir
  elif [ "${DRYRUN:-0}" -eq 1 ]; then
    echo crdir
  elif command -v need_crdir >/dev/null 2>&1; then
    need_crdir
  else
    echo "${PROG:-andromeda}: crdir not on PATH" >&2
    return 1
  fi
}

d7_dbname() {
  if command -v db_name >/dev/null 2>&1; then
    db_name "$1" "${2:-${ANDROMEDA_ROLE:-devel}}"
  else
    printf '%s' "bd_$1_${2:-${ANDROMEDA_ROLE:-devel}}" | tr -c 'a-z0-9_' '_' | cut -c1-64
  fi
}

cmd_d7_convert() {
  d7_refuse_root || return $?
  [ -n "$D7_FROM" ] || { echo "d7 convert needs --from BUNDLE" >&2; return 2; }
  [ -n "$D7_PLATFORM" ] || { echo "d7 convert needs --platform" >&2; return 2; }
  [ -n "$D7_PRODUCT" ] || { echo "d7 convert needs --product" >&2; return 2; }
  D7_PLATFORM=$(slug "$D7_PLATFORM")
  D7_PRODUCT=$(slug "$D7_PRODUCT")
  bundle=$D7_FROM
  d7_is_bundle "$bundle" || { echo "$bundle is not a prep bundle" >&2; return 1; }
  dump=""
  if [ -n "$D7_SQL" ]; then
    dump=$D7_SQL
  elif [ -f "$bundle/dump.sql.gz" ]; then
    dump=$bundle/dump.sql.gz
  elif [ -f "$bundle/dump.sql" ]; then
    dump=$bundle/dump.sql
  else
    echo "no dump in $bundle" >&2
    return 1
  fi
  [ -n "$D7_HOST" ] || D7_HOST="${D7_PRODUCT}.${ANDROMEDA_ROLE:-devel}"
  role=${ANDROMEDA_ROLE:-devel}
  plats=${PLATFORMS:-/srv/platforms}
  root=$plats/$D7_PLATFORM
  web=$root/web
  db=$(d7_dbname "$D7_PRODUCT" "$role")
  user=$(printf '%s' "$db" | cut -c1-32)
  pass=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
  if command -v read_secret_pass >/dev/null 2>&1; then
    existing=$(read_secret_pass "$D7_PLATFORM" "$D7_PRODUCT" || true)
    [ -n "$existing" ] && pass=$existing
  fi
  dsn="mysql://${user}:${pass}@localhost/${db}"
  owner=${OWNER:-deploy}
  group=${GROUP:-www-admin}
  daemon=${DAEMON:-www-data}

  echo "convert $bundle -> $D7_PLATFORM/$D7_PRODUCT host=$D7_HOST db=$db"

  if command -v run_hooks >/dev/null 2>&1; then
    run_hooks d7-pre-convert "$D7_PLATFORM" "$D7_PRODUCT" || true
  fi

  if [ ! -d "$web" ]; then
    if have andromeda && [ "${PROG:-}" != andromeda ]; then
      [ "${DRYRUN:-0}" -eq 1 ] && echo "+ andromeda platform-add $D7_PLATFORM --no-prompt"
      [ "${DRYRUN:-0}" -eq 0 ] && andromeda platform-add "$D7_PLATFORM" --no-prompt
    elif command -v cmd_platform_add >/dev/null 2>&1; then
      cmd_platform_add "$D7_PLATFORM" --no-prompt
    else
      bee=$(d7_bee) || return 1
      echo "platform-add via bee dl-core $root"
      run_root mkdir -p "$root"
      run_root chown "$owner:$group" "$root"
      if [ "${DRYRUN:-0}" -eq 1 ]; then
        echo "+ $bee --root=$root dl-core web"
      else
        as_root -u "$owner" "$bee" --root="$root" dl-core web
      fi
    fi
  else
    ok "platform $root"
  fi

  cr=$(d7_crdir) || return 1
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ $cr -s -o $daemon -g $group $root/files/$D7_PRODUCT $root/files_private/$D7_PRODUCT $root/config/$D7_PRODUCT/active"
    echo "+ $cr -o $owner -g $group $root/config/$D7_PRODUCT/staging"
  else
    as_root -u "$owner" "$cr" -s -o "$daemon" -g "$group" \
      "$root/files/$D7_PRODUCT" "$root/files_private/$D7_PRODUCT" "$root/config/$D7_PRODUCT/active"
    as_root -u "$owner" "$cr" -o "$owner" -g "$group" "$root/config/$D7_PRODUCT/staging"
    run_root mkdir -p "$web/sites/$D7_PRODUCT"
    run_root chown "$owner:$group" "$web/sites/$D7_PRODUCT"
  fi

  if command -v write_secret >/dev/null 2>&1; then
    write_secret "$D7_PLATFORM" "$D7_PRODUCT" "$user" "$pass" "$db"
  fi
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ CREATE DATABASE $db / USER $user@localhost"
  else
    cnf=""
    if command -v secret_file >/dev/null 2>&1; then
      cnf=$(secret_file "$D7_PLATFORM" "$D7_PRODUCT").cnf
    fi
    if [ -x /usr/local/sbin/andromeda-priv ] && [ -n "$cnf" ]; then
      as_root /usr/local/sbin/andromeda-priv mysql-create "$db" "$user" "$cnf" || true
    fi
    as_root mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    as_root mysql -e "CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED BY '$pass';"
    as_root mysql -e "GRANT ALL ON \`$db\`.* TO '$user'@'localhost'; FLUSH PRIVILEGES;"
  fi

  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ import $dump -> $db"
  else
    case $dump in
      *.gz) gzip -dc "$dump" | as_root mysql --force "$db" ;;
      *) as_root mysql --force "$db" < "$dump" ;;
    esac
  fi

  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ cp files/private/modules/themes into $root"
  else
    [ -d "$bundle/files" ] && run_root cp -a "$bundle/files/." "$root/files/$D7_PRODUCT/"
    [ -d "$bundle/private" ] && run_root cp -a "$bundle/private/." "$root/files_private/$D7_PRODUCT/"
    if [ -d "$bundle/modules" ]; then
      run_root mkdir -p "$web/sites/$D7_PRODUCT/modules"
      run_root cp -a "$bundle/modules/." "$web/sites/$D7_PRODUCT/modules/"
    fi
    if [ -d "$bundle/themes" ]; then
      run_root mkdir -p "$web/sites/$D7_PRODUCT/themes"
      run_root cp -a "$bundle/themes/." "$web/sites/$D7_PRODUCT/themes/"
    fi
    if [ -d "$bundle/libraries" ]; then
      run_root mkdir -p "$web/sites/$D7_PRODUCT/libraries"
      run_root cp -a "$bundle/libraries/." "$web/sites/$D7_PRODUCT/libraries/"
    fi
    run_root chown -R "$daemon:$group" "$root/files/$D7_PRODUCT" "$root/files_private/$D7_PRODUCT"
    d7_patch_themes "$web/sites/$D7_PRODUCT/themes"
  fi

  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ TRUNCATE cache* ; ALTER DATABASE $db utf8mb4"
  else
    as_root mysql "$db" -N -e "SHOW TABLES LIKE 'cache%'" 2>/dev/null | while IFS= read -r t || [ -n "$t" ]; do
      [ -n "$t" ] || continue
      as_root mysql "$db" -e "TRUNCATE TABLE \`$t\`" || true
    done
    as_root mysql -e "ALTER DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true
  fi

  dest=$web/sites/$D7_PRODUCT/settings.php
  localp=$web/sites/$D7_PRODUCT/settings.local.php
  sites=$web/sites/sites.php
  hostpat=$(printf '%s' "$D7_HOST" | sed 's/\./\\\\./g')
  pre="FALSE"
  [ "$role" = live ] && pre="TRUE"
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ write $dest $localp $sites  update_free_access=TRUE"
  else
    [ -f "$web/settings.php" ] && [ ! -f "$dest" ] && run_root cp "$web/settings.php" "$dest"
    [ -f "$dest" ] || as_root tee "$dest" >/dev/null <<'EOF'
<?php
EOF
    if ! grep -q "config/$D7_PRODUCT/active" "$dest" 2>/dev/null; then
      as_root tee -a "$dest" >/dev/null <<EOF

\$config_directories['active']  = '../../config/$D7_PRODUCT/active';
\$config_directories['staging'] = '../../config/$D7_PRODUCT/staging';
\$config['system.core']['file_private_path'] = '../../files_private/$D7_PRODUCT';
\$settings['file_public_path'] = '../../files/$D7_PRODUCT';
\$update_free_access = TRUE;
if (file_exists(__DIR__ . '/settings.local.php')) {
  include __DIR__ . '/settings.local.php';
}
EOF
    fi
    if [ ! -f "$localp" ]; then
      as_root tee "$localp" >/dev/null <<EOF
<?php
\$database = '$dsn';
\$settings['trusted_host_patterns'] = array('^${hostpat}$');
\$config['system.core']['preprocess_css'] = $pre;
\$config['system.core']['preprocess_js']  = $pre;
EOF
      run_root chmod 0640 "$localp"
    fi
    [ -f "$sites" ] || as_root tee "$sites" >/dev/null <<'EOF'
<?php
EOF
    grep -q "sites\['$D7_HOST'\]" "$sites" 2>/dev/null || \
      as_root tee -a "$sites" >/dev/null <<EOF
\$sites['$D7_HOST'] = '$D7_PRODUCT';
EOF
    run_root chown "$owner:$group" "$dest" "$localp" "$sites"
  fi

  extra=$D7_MODULES
  [ -f "$bundle/to-download.txt" ] && extra="$extra $(tr '\n' ' ' < "$bundle/to-download.txt")"
  if [ -f "$bundle/enabled.txt" ]; then
    d7_scan_features "$bundle/enabled.txt"
  fi
  if [ "${D7_NEED_EPLUS:-0}" -eq 1 ]; then
    extra="$extra entity_plus entity_ui"
  fi
  if [ "${D7_HAS_UC:-0}" -eq 1 ]; then
    extra="$extra ubercart"
  fi
  bee=$(d7_bee) || return 1
  if [ "$D7_SKIP_DL" -eq 1 ]; then
    note "--skip-dl"
  else
    uniq=$(printf '%s\n' $extra | tr ',' ' ' | tr ' ' '\n' | sed '/^$/d' | sort -u)
    echo "bee dl: $uniq"
    for p in $uniq; do
      [ "$p" = "-" ] && continue
      cls=$(d7_catalog_class "$p" || true)
      [ "$cls" = COREIN ] && continue
      [ "$cls" = CORE7 ] && continue
      [ "$cls" = DROP ] && continue
      if [ "${DRYRUN:-0}" -eq 1 ]; then
        echo "+ $bee --root=$web download $p"
        continue
      fi
      as_root -u "$owner" "$bee" --root="$web" download "$p" || note "bee dl $p failed"
    done
  fi

  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ $bee -y --root=$web --site=$D7_PRODUCT update-db"
  else
    echo "bee update-db — D7 schema becomes Backdrop"
    if command -v bee_yes >/dev/null 2>&1; then
      bee_yes --root="$web" --site="$D7_PRODUCT" update-db || {
        echo "update-db failed — leave update_free_access TRUE and inspect core/update.php" >&2
        return 1
      }
    else
      as_root -u "$owner" "$bee" -y --root="$web" --site="$D7_PRODUCT" update-db || \
        printf 'y\n' | as_root -u "$owner" "$bee" --root="$web" --site="$D7_PRODUCT" update-db || return 1
    fi
    if [ "$D7_KEEP_UFA" -eq 0 ]; then
      run_root sed -i "s/\$update_free_access = TRUE;/\$update_free_access = FALSE;/" "$dest" || true
    fi
    as_root touch "$web/sites/$D7_PRODUCT/.andromeda-imported"
    as_root touch "$web/sites/$D7_PRODUCT/.andromeda-installed"
    run_root chown "$owner:$group" "$web/sites/$D7_PRODUCT/.andromeda-imported" "$web/sites/$D7_PRODUCT/.andromeda-installed"
    as_root -u "$owner" "$bee" --root="$web" --site="$D7_PRODUCT" status || true
    as_root -u "$owner" "$bee" --root="$web" --site="$D7_PRODUCT" cache-rebuild 2>/dev/null \
      || as_root -u "$owner" "$bee" --root="$web" --site="$D7_PRODUCT" cc all 2>/dev/null \
      || true
  fi

  if command -v run_hooks >/dev/null 2>&1; then
    run_hooks d7-post-convert "$D7_PLATFORM" "$D7_PRODUCT" || true
  fi
  echo "converted http://$D7_HOST  db=$db"
}

cmd_d7_attach() {
  d7_refuse_root || return $?
  [ -n "$D7_PLATFORM" ] || { echo "d7 attach needs --platform" >&2; return 2; }
  [ -n "$D7_PRODUCT" ] || { echo "d7 attach needs --product" >&2; return 2; }
  D7_PLATFORM=$(slug "$D7_PLATFORM")
  D7_PRODUCT=$(slug "$D7_PRODUCT")
  [ -n "$D7_HOST" ] || D7_HOST="${D7_PRODUCT}.${ANDROMEDA_ROLE:-devel}"
  role=${ANDROMEDA_ROLE:-devel}
  plats=${PLATFORMS:-/srv/platforms}
  root=$plats/$D7_PLATFORM
  web=$root/web
  if [ "${DRYRUN:-0}" -eq 0 ]; then
    [ -d "$web" ] || { echo "no platform $root" >&2; return 1; }
    [ -f "$web/sites/$D7_PRODUCT/settings.php" ] || { echo "run d7 convert first" >&2; return 1; }
  fi
  conf=/etc/apache2/sites-available/${D7_PLATFORM}-${role}.conf
  echo "attach $D7_PLATFORM/$D7_PRODUCT host=$D7_HOST"
  if [ -d /etc/apache2/sites-available ]; then
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "+ vhost $conf ServerName/Alias $D7_HOST DocumentRoot $web"
    else
      if [ ! -f "$conf" ]; then
        as_root tee "$conf" >/dev/null <<EOF
<VirtualHost *:80>
  ServerName $D7_HOST
  DocumentRoot $web
  <Directory $web>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  <Directory $root/config>
    Require all denied
  </Directory>
  <Directory $root/files_private>
    Require all denied
  </Directory>
</VirtualHost>
EOF
      elif ! grep -q "$D7_HOST" "$conf"; then
        as_root sed -i "s/^\\([[:space:]]*ServerName .*\\)/\\1\\n    ServerAlias $D7_HOST/" "$conf"
      fi
      have a2ensite && run_root a2ensite "${D7_PLATFORM}-${role}.conf" >/dev/null 2>&1 || true
      [ -x /etc/init.d/apache2 ] && run_root /etc/init.d/apache2 reload || true
    fi
  else
    note "no Apache sites-available"
  fi
  if command -v cmd_site_check >/dev/null 2>&1 && [ "${DRYRUN:-0}" -eq 0 ]; then
    cmd_site_check "$D7_PLATFORM" "$D7_PRODUCT" --host "$D7_HOST" || note "site-check problems"
  elif have andromeda && [ "${DRYRUN:-0}" -eq 0 ]; then
    andromeda site-check "$D7_PLATFORM" "$D7_PRODUCT" --host "$D7_HOST" || true
  elif [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ andromeda site-check $D7_PLATFORM $D7_PRODUCT --host $D7_HOST"
  fi
  ok "attached $D7_PRODUCT on $D7_PLATFORM -> http://$D7_HOST"
}

cmd_d7_all() {
  [ -n "$D7_FROM" ] || { echo "d7 all needs --from" >&2; return 2; }
  [ -n "$D7_PLATFORM" ] || { echo "d7 all needs --platform" >&2; return 2; }
  if [ -z "$D7_PRODUCT" ]; then
    if d7_is_bundle "$D7_FROM" && [ -f "$D7_FROM/meta.txt" ]; then
      D7_PRODUCT=$(sed -n 's/^product=//p' "$D7_FROM/meta.txt" | head -n 1)
    fi
    [ -n "$D7_PRODUCT" ] || D7_PRODUCT=$(slug "$(basename "$D7_FROM")")
  fi
  if [ -z "$D7_OUT" ]; then
    if d7_is_bundle "$D7_FROM"; then
      D7_OUT=$D7_FROM
    else
      D7_OUT=$(pwd -P)/d7-${D7_PRODUCT}-$(stamp)
    fi
  fi
  if ! d7_is_bundle "$D7_FROM"; then
    cmd_d7_prep || return $?
    D7_FROM=$D7_OUT
  fi
  cmd_d7_assess || return $?
  cmd_d7_convert || return $?
  cmd_d7_attach || return $?
}

cmd_d7() {
  while [ "${1:-}" = "-n" ]; do
    DRYRUN=1
    shift
  done
  sub=${1:-help}
  # andromeda d7 /path/to/site  ==  andromeda d7 test /path/to/site
  if [ -n "$sub" ] && [ -d "$sub" ]; then
    D7_FROM=$sub
    shift
    d7_parse "$@" || true
    [ -z "$D7_FROM" ] && D7_FROM=$sub
    cmd_d7_test
    return $?
  fi
  [ $# -gt 0 ] && shift
  d7_parse "$@" || {
    rc=$?
    [ "$rc" -eq 2 ] && return 0
    return $rc
  }
  case $sub in
    help|-h|--help) d7_help ;;
    tools|tool) cmd_d7_tools ;;
    stubs|stub) cmd_d7_stubs ;;
    toolkit) cmd_d7_toolkit ;;
    port) cmd_d7_port ;;
    prep) cmd_d7_prep ;;
    assess) cmd_d7_assess ;;
    test|scan) cmd_d7_test ;;
    apply) cmd_d7_apply ;;
    tutorial|guide) cmd_d7_tutorial ;;
    cex|config-export) cmd_d7_cex "${D7_FROM:-}" ;;
    theme-patch|theme) cmd_d7_theme_patch ;;
    convert) cmd_d7_convert ;;
    attach) cmd_d7_attach ;;
    all|migrate) cmd_d7_all ;;
    *)
      echo "${PROG:-andromeda}: unknown d7 verb $sub (try: andromeda d7 help)" >&2
      return 2
      ;;
  esac
}
