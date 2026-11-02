# shellcheck shell=sh
# ensure stage — idempotent skeleton for a Backdrop stage.
# Tools: git worktree, crdir, andromeda-priv, _write_local.
# Creates the dirs, the settings array, the sites.php line, and the
# stage worktree. Does not invent config JSON.

# stage_tree PLATFORM ROLE
# devel uses the main checkout. test and live get a worktree.
stage_tree() {
  plat=$1
  role=$2
  if [ "$role" = "devel" ] || [ -z "$role" ]; then
    printf '%s\n' "$PLATFORMS/$plat"
    return 0
  fi
  printf '%s\n' "$PLATFORMS/${plat}-${role}"
}

# stage_paths PLATFORM PRODUCT ROLE
# Blueprint. Sets the paths every stage needs. Other functions read these
# instead of rebuilding the layout.
stage_paths() {
  plat=$1
  product=$2
  role=$3
  STAGE_ROOT=$(stage_tree "$plat" "$role")
  STAGE_WEB=$STAGE_ROOT/web
  STAGE_SITE=$STAGE_WEB/sites/$product
  STAGE_FILES=$STAGE_ROOT/files/$product
  STAGE_PRIVATE=$STAGE_ROOT/files_private/$product
  STAGE_ACTIVE=$STAGE_ROOT/config/$product/active
  STAGE_STAGING=$STAGE_ROOT/config/$product/staging
  STAGE_LOCALPHP=$STAGE_SITE/settings.local.php
  STAGE_SYMLINK=$STAGE_SITE/files
  # Owner and mode are part of the blueprint. deploy writes the
  # skeleton. www-data is in www-admin, so Apache can still use it.
  STAGE_OWNER=${OWNER:-deploy}
  STAGE_GROUP=${GROUP:-www-admin}
  STAGE_MODE_DIR=0770
  STAGE_MODE_FILE=0640
  export STAGE_ROOT STAGE_WEB STAGE_SITE STAGE_FILES STAGE_PRIVATE
  export STAGE_ACTIVE STAGE_STAGING STAGE_LOCALPHP STAGE_SYMLINK
  export STAGE_OWNER STAGE_GROUP STAGE_MODE_DIR STAGE_MODE_FILE
}

# ensure_worktree PLATFORM ROLE
# Main checkout stays on devel. Other stages are worktrees of it.
ensure_worktree() {
  plat=$1
  role=$2
  main=$PLATFORMS/$plat
  tree=$(stage_tree "$plat" "$role")
  if [ ! -e "$main/.git" ]; then
    echo "$PROG: $main has no git repo — run repo-ensure first" >&2
    return 1
  fi
  if [ "$role" = "devel" ]; then
    echo "worktree devel $main"
    return 0
  fi
  if [ -e "$tree/.git" ]; then
    echo "worktree $role $tree"
    return 0
  fi
  echo "worktree add $role $tree"
  if ! as_root -u "$OWNER" git -c safe.directory='*' -C "$main" \
      worktree add -B "$role" "$tree" "$role"; then
    echo "$PROG: worktree add failed for $role" >&2
    return 1
  fi
  return 0
}

# stage_security ROOT WEB PRODUCT
# Checks that do not change files. Prints FAIL lines. Returns 1 on any fail.
stage_security() {
  root=$1
  web=$2
  product=$3
  role=$4
  fail=0
  localphp=$web/sites/$product/settings.local.php
  private=$root/files_private/$product
  active=$root/config/$product/active

  # Config and private files stay outside the docroot.
  case $active in
    "$web"/*) echo "FAIL  config active is inside the docroot: $active" >&2; fail=1 ;;
  esac
  case $private in
    "$web"/*) echo "FAIL  files_private is inside the docroot: $private" >&2; fail=1 ;;
  esac

  if [ -f "$localphp" ]; then
    mode=$(stat -c '%a' "$localphp" 2>/dev/null || stat -f '%OLp' "$localphp" 2>/dev/null || echo "")
    case $mode in
      640|0640|600|0600) ;;
      "") ;;
      *) echo "FAIL  $localphp mode $mode — want 0640" >&2; fail=1 ;;
    esac
    if ! grep -q 'trusted_host_patterns' "$localphp"; then
      echo "FAIL  trusted_host_patterns missing in $localphp" >&2
      fail=1
    fi
    if [ "$role" != "live" ] && ! grep -q "cache.*= *FALSE" "$localphp"; then
      echo "FAIL  cache is not FALSE on $role" >&2
      fail=1
    fi
  else
    echo "FAIL  missing $localphp" >&2
    fail=1
  fi

  # No world-writable runtime dirs.
  for d in "$root/files/$product" "$private" "$active"; do
    [ -d "$d" ] || continue
    mode=$(stat -c '%a' "$d" 2>/dev/null || echo "")
    case $mode in
      *7) echo "FAIL  $d is world-writable ($mode)" >&2; fail=1 ;;
    esac
  done

  # Private dir gets a deny file even though it is outside the docroot.
  if [ -d "$private" ] && [ ! -f "$private/.htaccess" ]; then
    echo "note  no .htaccess in $private — writing deny"
    printf '%s\n' 'Require all denied' 'Deny from all' | as_root -u "$OWNER" tee "$private/.htaccess" >/dev/null || {
      echo "$PROG: cannot write $private/.htaccess as $OWNER" >&2
      fail=1
    }
  fi

  [ "$fail" -eq 0 ]
}



# stage_apply
# The one landing pad. Reads the blueprint and makes the tree match it.
# deploy runs crdir. Call this before a function writes, and again after
# it lands files, so no caller keeps its own mode.
stage_apply() {
  cr=$(need_crdir)
  echo "skeleton as $STAGE_OWNER"
  as_root -u "$STAGE_OWNER" "$cr" -s -o "$STAGE_OWNER" -g "$STAGE_GROUP" -m "$STAGE_MODE_DIR" \
    "$STAGE_FILES" "$STAGE_PRIVATE" "$STAGE_ACTIVE" \
    "$STAGE_STAGING" "$STAGE_SITE" || return 1
  if [ -f "$STAGE_LOCALPHP" ]; then
    as_root -u "$STAGE_OWNER" "$cr" -o "$STAGE_OWNER" -g "$STAGE_GROUP" -m "$STAGE_MODE_FILE" \
      "$STAGE_LOCALPHP" || return 1
  fi
}

# stage_health
# Verify the blueprint after crdir. deploy must own and be able to
# write every skeleton path. Prints OK or FAIL per path. Returns 1
# on any miss. Does not change files.
stage_health() {
  fail=0
  echo "health skeleton $STAGE_OWNER:$STAGE_GROUP"
  for d in "$STAGE_FILES" "$STAGE_PRIVATE" "$STAGE_ACTIVE" "$STAGE_STAGING" "$STAGE_SITE"; do
    if [ ! -d "$d" ]; then
      echo "FAIL  missing $d" >&2
      fail=1
      continue
    fi
    own=$(stat -c '%U:%G' "$d" 2>/dev/null || echo "?:?")
    mode=$(stat -c '%a' "$d" 2>/dev/null || echo "")
    if [ "$own" != "$STAGE_OWNER:$STAGE_GROUP" ]; then
      echo "FAIL  $d owner $own — want $STAGE_OWNER:$STAGE_GROUP" >&2
      fail=1
    fi
    case $mode in
      2770|2775) ;;
      *) echo "FAIL  $d mode $mode — want 2770 (0770 setgid)" >&2; fail=1 ;;
    esac
    if ! as_root -u "$STAGE_OWNER" test -w "$d"; then
      echo "FAIL  $STAGE_OWNER cannot write $d" >&2
      fail=1
    else
      echo "OK    $d $own $mode"
    fi
  done
  case $STAGE_ACTIVE in
    "$STAGE_WEB"/*) echo "FAIL  config active is inside the docroot" >&2; fail=1 ;;
  esac
  case $STAGE_PRIVATE in
    "$STAGE_WEB"/*) echo "FAIL  files_private is inside the docroot" >&2; fail=1 ;;
  esac
  if [ -f "$STAGE_LOCALPHP" ]; then
    own=$(stat -c '%U:%G' "$STAGE_LOCALPHP" 2>/dev/null || echo "?:?")
    mode=$(stat -c '%a' "$STAGE_LOCALPHP" 2>/dev/null || echo "")
    if [ "$own" != "$STAGE_OWNER:$STAGE_GROUP" ]; then
      echo "FAIL  $STAGE_LOCALPHP owner $own" >&2
      fail=1
    fi
    case $mode in
      640|0640|670|0670) echo "OK    $STAGE_LOCALPHP $own $mode" ;;
      *) echo "FAIL  $STAGE_LOCALPHP mode $mode — want 0640" >&2; fail=1 ;;
    esac
    if ! as_root -u "$STAGE_OWNER" test -r "$STAGE_LOCALPHP"; then
      echo "FAIL  $STAGE_OWNER cannot read $STAGE_LOCALPHP" >&2
      fail=1
    fi
  fi
  [ "$fail" -eq 0 ]
}

# cmd_ensure_stage PLATFORM PRODUCT
# Idempotent. Safe to call at the start of pull and push.
cmd_ensure_stage() {
  role=${ANDROMEDA_ROLE:-}
  while [ $# -gt 0 ]; do
    case $1 in
      --role) role=$2; shift 2 ;;
      -v|--verbose) VERBOSE=1; export VERBOSE; shift ;;
      --) shift; break ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  plat=${1:-}
  product=${2:-}
  plat=$(slug "$plat")
  product=$(slug "$product")
  if [ -z "$plat" ] || [ -z "$product" ]; then
    echo "usage: $PROG ensure stage PLATFORM PRODUCT [--role devel|test|live]" >&2
    exit 2
  fi
  if [ -z "$role" ]; then
    role=$(stage_from_site "$product")
  fi
  host=$(hostname_for_site "$product" "")
  platform=$plat
  echo "ensure stage $plat/$product ($role)"

  if [ ! -d "$PLATFORMS/$plat/.git" ] && [ ! -f "$PLATFORMS/$plat/.git" ]; then
    echo "repo missing — repo-ensure $plat"
    cmd_repo_ensure "$plat" || return 1
  fi
  ensure_worktree "$plat" "$role" || return 1
  stage_paths "$plat" "$product" "$role"
  root=$STAGE_ROOT
  web=$STAGE_WEB
  as_root -u "$OWNER" mkdir -p "$STAGE_SITE" || return 1

  cr=$(need_crdir)
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ worktree $role at $root"
    echo "+ dirs files files_private config/active config/staging"
    echo "+ settings.local.php array + sites.php + files symlink"
    echo "+ security checks"
    return 0
  fi
  # Blueprint: deploy owns every skeleton path. Group www-admin.
  # setgid so a file deploy writes stays in the group. Apache is
  # in that group.
  stage_apply || return 1
  stage_health || {
    echo "$PROG: skeleton health failed — pull stopped" >&2
    return 1
  }

  # Settings array, symlink, sites.php. _write_local is the one template.
  # A first pull has no secret yet. site-add writes it. Do not fail here.
  pass=$(read_secret_pass "$platform" "$product" || true)
  if [ -n "$pass" ]; then
    _write_local "$root" "$web" "$product" "$host" "$role" || return 1
    ensure_sites_php "$web" "$host" "$product" || return 1
    stage_health || {
      echo "$PROG: skeleton health failed after settings" >&2
      return 1
    }
    stage_security "$root" "$web" "$product" "$role" || {
      echo "$PROG: stage $plat/$product failed security checks" >&2
      return 1
    }
  else
    echo "note  no secret yet — settings written after site-add"
  fi
  if [ ! -f "$root/config/$product/active/system.core.json" ]; then
    echo "note  no system.core.json in active — stage skeleton is ready, config comes from pull"
  else
    echo "config active ready"
  fi
  echo "stage ready $plat/$product ($role) at $root"
}
