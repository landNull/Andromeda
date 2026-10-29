# shellcheck shell=sh

# pull-rsync — internal helper. Called by cmd_site_pull.
# Tools: WireGuard, git, rsync, andro bee, andromeda-priv.
# Gaps: settings.local.php template, sites.php line.

# pull_code ROOT WEB VPS SRC_PLATFORM
# Code moves by git. A bundle is the tool when the source repo is
# owned by deploy and the operator cannot fetch over SSH directly.
# See git-bundle(1).
pull_code() {
  root=$1
  web=$2
  vps=$3
  src_p=$4
  op=$(id -un)
  remote=$(tunnel_host "$vps")
  port=$(ssh_port)
  stage=$(stage_from_site "${product:-}")
  [ -n "$stage" ] || stage=${role:-devel}
  echo "code  git from ssh://$remote:$port/srv/platforms/$src_p as $op"
  # landy reads a repo owned by deploy. Mark it safe on the source.
  ssh_cmd "$remote" "git config --global --add safe.directory /srv/platforms/$src_p/.git" || true
  ssh_cmd "$remote" "git config --global --add safe.directory '*'" || true
  bundle=$(mktemp /tmp/andromeda-code.XXXXXX.bundle)
  if ! ssh_cmd "$remote" \
      "git -c safe.directory='*' -C /srv/platforms/$src_p bundle create - --branches" \
      > "$bundle"; then
    echo "$PROG: git bundle failed — code did not move" >&2
    rm -f "$bundle"
    return 1
  fi
  chmod 0644 "$bundle" 2>/dev/null || true
  if [ ! -s "$bundle" ] || ! git bundle verify "$bundle" >/dev/null 2>&1; then
    echo "$PROG: source repo is empty — no commits on $remote:/srv/platforms/$src_p" >&2
    echo "$PROG: code did not move. Commit the platform on the source, then pull again." >&2
    rm -f "$bundle"
    return 0
  fi
  run_root chown -R "$OWNER:$GROUP" "$root" 2>/dev/null || true
  if [ ! -e "$root/.git" ]; then
    as_root -u "$OWNER" git -c safe.directory='*' -C "$root" init || { rm -f "$bundle"; return 1; }
  fi
  echo "code  git fetch bundle as $OWNER"
  if ! as_root -u "$OWNER" git -c safe.directory='*' -C "$root" \
      fetch "$bundle" "+refs/heads/*:refs/remotes/origin/*"; then
    echo "$PROG: git fetch from bundle failed — code did not move" >&2
    rm -f "$bundle"
    return 1
  fi
  rm -f "$bundle"
  src_branch=$stage
  if ! as_root -u "$OWNER" git -c safe.directory='*' -C "$root" \
      rev-parse --verify "origin/$stage" >/dev/null 2>&1; then
    src_branch=""
    for b in devel test live; do
      if as_root -u "$OWNER" git -c safe.directory='*' -C "$root" \
          rev-parse --verify "origin/$b" >/dev/null 2>&1; then
        echo "code  no $stage branch — using $b"
        src_branch=$b
        break
      fi
    done
    if [ -z "$src_branch" ]; then
      echo "$PROG: no stage branch in the bundle — code did not move" >&2
      return 0
    fi
  fi
  echo "code  git checkout $stage as $OWNER, source wins"
  as_root -u "$OWNER" git -c safe.directory='*' -C "$root" clean -fd >/dev/null 2>&1 || true
  if ! as_root -u "$OWNER" git -c safe.directory='*' -C "$root" checkout -B "$stage" "origin/$src_branch"; then
    echo "$PROG: cannot check out as $OWNER" >&2
    echo "$PROG: need NOPASSWD for $OWNER in /etc/sudoers.d/andromeda-deploy" >&2
    echo "$PROG: %www-admin ALL=($OWNER) NOPASSWD: /usr/bin/git" >&2
    return 1
  fi
  as_root -u "$OWNER" git -c safe.directory='*' -C "$root" reset --hard "origin/$src_branch" || return 1
  echo "code  on branch $stage as $OWNER"
  # A migrated platform has only the init commit. Git has nothing.
  # Fall back to rsync of the web tree. Exclude the runtime stores
  # and the local settings: those move by their own paths.
  if [ ! -d "$web/core" ]; then
    echo "code  no core — rsync web tree from $remote"
    run_root mkdir -p "$web"
    stage=$(mktemp -d)
    if ! remote_rsync \
      --exclude='sites/*/settings.local.php' \
      --exclude='files/' \
      --exclude='sites/*/files/' \
      "$remote:/srv/platforms/$src_p/web/" "$stage/"; then
      echo "$PROG: web tree did not move" >&2
      rm -rf "$stage"
      return 1
    fi
    as_root -u "$OWNER" rsync -a --no-perms --no-owner --no-group "$stage/" "$web/" || true
    rm -rf "$stage"
    echo "code  web tree from $remote as $OWNER"
  fi
}

# pull_content ROOT PRODUCT VPS SRC_PLATFORM SRC_SITE
# Image files by rsync. Everything else moves by git.
pull_content() {
  root=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  remote=$(tunnel_host "$vps")
  port=$(ssh_port)
  run_root mkdir -p "$root/files/$product"
  echo "images rsync from $remote port $port"
  stage=$(mktemp -d)
  got=0
  for src in \
    "/srv/platforms/$src_p/files/$src_s/" \
    "/srv/platforms/$src_p/web/sites/$src_s/files/" \
    "/srv/platforms/$src_p/web/files/"
  do
    if remote_rsync \
      --include='*/' \
      --include='*.jpg' --include='*.jpeg' --include='*.png' \
      --include='*.gif' --include='*.webp' --include='*.svg' \
      --include='*.ico' --include='*.bmp' \
      --exclude='*' \
      "$remote:$src" "$stage/" 2>/dev/null; then
      got=1
      break
    fi
  done
  if [ "$got" -eq 1 ]; then
    # The files dir is www-data:www-admin 0770. The operator cannot write it.
    as_root -u "$OWNER" rsync -a --no-perms --no-owner --no-group "$stage/" "$root/files/$product/" || true
    echo "images landed in $root/files/$product"
  else
    echo "images none — no image tree for $src_s on $remote"
  fi
  rm -rf "$stage"
  chown_files "$root/files/$product" 2>/dev/null || true
}


# pull_files ROOT PRODUCT VPS SRC_PLATFORM SRC_SITE
# User content by rsync. The whole tree, not images only.
# Staged locally, then copied as root: the store is www-data:www-admin.
pull_files() {
  root=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  remote=$(tunnel_host "$vps")
  run_root mkdir -p "$root/files/$product" "$root/files_private/$product"

  echo "files from $remote"
  stage=$(mktemp -d)
  got=0
  for src in \
    "/srv/platforms/$src_p/files/$src_s" \
    "/srv/platforms/$src_p/web/sites/$src_s/files" \
    "/srv/platforms/$src_p/web/files"
  do
    # Probe first. A missing path makes rsync exit 23, which looks
    # like success and stops the search. A migrated site has no
    # platform store; the tree is under web/files.
    if ! ssh_cmd "$remote" "test -d '$src'" 2>/dev/null; then
      continue
    fi
    if remote_rsync "$remote:$src/" "$stage/"; then
      got=1
      echo "files from $src"
      break
    fi
  done
  if [ "$got" -eq 1 ]; then
    as_root -u "$OWNER" rsync -a --no-perms --no-owner --no-group "$stage/" "$root/files/$product/" || true
    echo "files landed in $root/files/$product"
  else
    echo "files none — no files tree for $src_s on $remote"
  fi
  rm -rf "$stage"

  echo "private from $remote"
  stage=$(mktemp -d)
  got=0
  for src in \
    "/srv/platforms/$src_p/files_private/$src_s" \
    "/srv/platforms/$src_p/web/sites/$src_s/files/private" \
    "/srv/platforms/$src_p/web/files/private"
  do
    if ! ssh_cmd "$remote" "test -d '$src'" 2>/dev/null; then
      continue
    fi
    if remote_rsync "$remote:$src/" "$stage/"; then
      got=1
      echo "private from $src"
      break
    fi
  done
  if [ "$got" -eq 1 ]; then
    as_root -u "$OWNER" rsync -a --no-perms --no-owner --no-group "$stage/" "$root/files_private/$product/" || true
    echo "private landed in $root/files_private/$product"
  else
    echo "private none"
  fi
  rm -rf "$stage"
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true
}

# pull_db WEB PRODUCT VPS SRC_PLATFORM SRC_SITE
# Database by andro bee. Remote export, local import.
pull_db() {
  web=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  dump=$(mktemp)
  remote=$(tunnel_host "$vps")
  echo "db    andro bee export on $remote"
  ssh_cmd "$remote" "andromeda bee $src_p $src_s db-export -" > "$dump" 2>/dev/null || \
    ssh_cmd "$remote" "bee --root=/srv/platforms/$src_p/web --site=$src_s db-export -" > "$dump" || true
  if [ -s "$dump" ]; then
    echo "db    andro bee import"
    site="$web/sites/$product"
    if command -v setfacl >/dev/null 2>&1; then
      run_root setfacl -b "$web" "$web/sites" "$site" "$site/settings.local.php" 2>/dev/null || true
    fi
    run_root chmod 0755 "$web" "$web/sites" "$site" 2>/dev/null || true
    run_root chmod 0644 "$site/settings.local.php" 2>/dev/null || true
    if ! bee_site_cmd "$web" "$product" db-import --mariadb-compatibility "$dump"; then
      echo "$PROG: andro bee db-import failed for $product" >&2
    fi
  else
    echo "db    none"
  fi
  rm -f "$dump"
}

# pull_config ROOT PRODUCT VPS SRC_PLATFORM SRC_SITE
# Configuration by andro bee. Remote config-export, rsync staging, local config-import.
# https://docs.backdropcms.org/documentation/versioned-staging-directory
pull_config() {
  root=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  remote=$(tunnel_host "$vps")
  active="$root/config/$product/active"
  staging="$root/config/$product/staging"
  run_root mkdir -p "$active" "$staging"
  if command -v setfacl >/dev/null 2>&1; then
    run_root setfacl -b "$root/config" "$root/config/$product" "$active" "$staging" 2>/dev/null || true
  fi
  run_root chmod 0775 "$active" "$staging" 2>/dev/null || true
  # Active config is what makes the site boot. A migrated site has it
  # and may have no staging. Copy it first. See docs/reference/repo-ensure.md.
  echo "config active from $remote"
  # find, not a glob. A glob in a quoted SSH command does not expand,
  # so the for-loop always returns empty. Prefer the platform store,
  # then the nested config a migrated site leaves under web/files.
  actives=$(ssh_cmd "$remote" "find /srv/platforms/$src_p -type d -name active 2>/dev/null | grep -v /staging/" 2>/dev/null || true)
  if [ -z "$actives" ]; then
    echo "config none — no active directory for $src_s on $remote"
  else
    stage=$(mktemp -d)
    for src in $actives; do
      # Skip an empty store. The real config is the one with the file.
      if ! ssh_cmd "$remote" "test -f '$src/system.core.json'" 2>/dev/null; then
        continue
      fi
      echo "config active from $src"
      if remote_rsync "$remote:${src}/" "$stage/"; then
        as_root -u "$OWNER" rsync -a --no-perms --no-owner --no-group "$stage/" "$active/" || true
        break
      fi
    done
    rm -rf "$stage"
  fi
  if [ -f "$active/system.core.json" ]; then
    echo "config active ready $active"
  else
    echo "config active has no system.core.json — site will not boot"
  fi
  chown_files "$active" 2>/dev/null || true
  echo "config andro bee export on $remote"
  ssh_cmd "$remote" "andromeda bee $src_p $src_s -y config-export" || \
    ssh_cmd "$remote" "bee -y --root=/srv/platforms/$src_p/web --site=$src_s config-export" || true
  echo "config staging from $remote port $(ssh_port)"
  got=0
  srcs=$(ssh_cmd "$remote" "find /srv/platforms/$src_p -type d -name staging 2>/dev/null" 2>/dev/null || true)
  if [ -z "$srcs" ]; then
    echo "config none — no staging directory for $src_s on $remote"
    return 0
  fi
  stage=$(mktemp -d)
  for src in $srcs; do
    if ! ssh_cmd "$remote" "find '$src' -name '*.json' -print -quit | grep -q ." 2>/dev/null; then
      continue
    fi
    echo "config from $src"
    if remote_rsync "$remote:${src}/" "$stage/"; then
      as_root -u "$OWNER" rsync -a --no-perms --no-owner --no-group "$stage/" "$staging/" || true
      got=1
      break
    fi
  done
  rm -rf "$stage"
  if [ "$got" -ne 1 ]; then
    echo "config none — staging did not arrive for $src_s"
    return 0
  fi
  if ! find "$staging" -name '*.json' -print -quit | grep -q .; then
    echo "config none — staging has no JSON"
    return 0
  fi
  echo "config landed in $staging"
  echo "config andro bee import"
  if ! bee_site_cmd "$root/web" "$product" -y config-import; then
    echo "$PROG: andro bee config-import failed for $product" >&2
  fi
}

# Local variants — same host, no ssh. Used when the source ref is bare or local.

pull_code_local() {
  root=$1
  web=$2
  src_p=$3
  src_web="/srv/platforms/$src_p/web"
  if [ ! -d "$src_web" ]; then
    echo "$PROG: local source web missing: $src_web" >&2
    return 1
  fi
  echo "code  rsync local web tree"
  # Operator cannot utime deploy-owned dirs. Exit 23 means files arrived.
  as_root -u "$OWNER" rsync -a --delete --omit-dir-times \
    --exclude='files/' --exclude='files_private/' \
    --exclude='sites/*/settings.local.php' \
    --exclude='sites/sites.php' \
    --exclude='sites/*/files' \
    --exclude='sites/*/' \
    "$src_web/" "$web/"
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 23 ]; then
    echo "$PROG: local rsync web tree failed" >&2
    return 1
  fi
}

pull_content_local() {
  root=$1
  product=$2
  src_p=$3
  src_s=$4
  src_root="/srv/platforms/$src_p"
  run_root mkdir -p "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active"
  echo "files rsync local"
  if [ -d "$src_root/files/$src_s" ]; then
    as_root -u "$OWNER" rsync -a --delete "$src_root/files/$src_s/" "$root/files/$product/" || true
  fi
  echo "private rsync local"
  if [ -d "$src_root/files_private/$src_s" ]; then
    as_root -u "$OWNER" rsync -a --delete "$src_root/files_private/$src_s/" "$root/files_private/$product/" || true
  fi
  echo "config rsync local"
  if [ -d "$src_root/config/$src_s/active" ]; then
    as_root -u "$OWNER" rsync -a --delete "$src_root/config/$src_s/active/" "$root/config/$product/active/" || true
  fi
  chown_files "$root/files/$product" "$root/files_private/$product" 2>/dev/null || true
}

pull_db_local() {
  web=$1
  product=$2
  src_p=$3
  src_s=$4
  dump=$(mktemp)
  echo "db    andro bee export local"
  bee_site_cmd "/srv/platforms/$src_p/web" "$src_s" db-export "$dump" 2>/dev/null || true
  if [ -s "$dump" ]; then
    echo "db    andro bee import"
    bee_site_cmd "$web" "$product" db-import --mariadb-compatibility "$dump" || true
  else
    echo "db    none"
  fi
  rm -f "$dump"
}
# push_code_via_git SRC_HOST SRC_PLAT SRC_SITE DST_HOST DST_PLAT DST_SITE
# Prefer git for code. Commit on the source stage, then checkout or merge
# into the destination stage. Returns 0 if git handled the code move,
# 1 so the caller can fall back to rsync.
push_code_via_git() {
  src_h=$1
  src_p=$2
  src_s=$3
  dst_h=$4
  dst_p=$5
  dst_s=$6
  src_stage=$(stage_from_site "$src_s")
  dst_stage=$(stage_from_site "$dst_s")

  # Same platform, both ends local: commit on source stage, merge into dest.
  if is_local_host "$src_h" && is_local_host "$dst_h" && [ "$src_p" = "$dst_p" ]; then
    dest=$PLATFORMS/$src_p
    ensure_platform_git "$src_p" "$src_stage" || return 1
    echo "git   commit on $src_stage"
    as_root -u "$OWNER" git -C "$dest" add -A
    if ! as_root -u "$OWNER" git -C "$dest" diff --cached --quiet 2>/dev/null; then
      as_root -u "$OWNER" git -C "$dest" commit -m "push $src_s -> $dst_s" || return 1
    else
      echo "git   nothing new on $src_stage"
    fi
    echo "git   checkout $dst_stage and merge $src_stage"
    as_root -u "$OWNER" git -C "$dest" checkout "$dst_stage" 2>/dev/null || \
      as_root -u "$OWNER" git -C "$dest" checkout -B "$dst_stage"
    as_root -u "$OWNER" git -C "$dest" merge --no-edit "$src_stage" || return 1
    return 0
  fi

  # Local source, remote dest: commit, push the branch over ssh, merge there.
  if is_local_host "$src_h" && ! is_local_host "$dst_h"; then
    dest=$PLATFORMS/$src_p
    [ -d "$dest" ] || return 1
    ensure_platform_git "$src_p" "$src_stage" || return 1
    as_root -u "$OWNER" git -C "$dest" add -A
    if ! as_root -u "$OWNER" git -C "$dest" diff --cached --quiet 2>/dev/null; then
      as_root -u "$OWNER" git -C "$dest" commit -m "push $src_s -> $dst_s" || true
    fi
    echo "git   push $src_stage to $dst_h:$dst_p"
    if ! as_root -u "$OWNER" git -C "$dest" push "ssh://$(tunnel_host "$dst_h"):$(ssh_port)/srv/platforms/$dst_p" "$src_stage:$src_stage"; then
      echo "git   push failed — will rsync"
      return 1
    fi
    echo "git   merge $src_stage into $dst_stage on $dst_h"
    ssh_cmd "$(tunnel_host "$dst_h")" "cd /srv/platforms/$dst_p && git checkout -B $dst_stage && git merge --no-edit $src_stage" || return 1
    return 0
  fi

  return 1
}

# push_site SRC_HOST SRC_PLAT SRC_SITE DST_HOST DST_PLAT DST_SITE HOSTNAME ROLE
# Moves code, content, and db. Ensures the destination site exists with the
# computed hostname. Local ends use the filesystem; remote ends use ssh/rsync.
push_site() {
  src_h=$1
  src_p=$2
  src_s=$3
  dst_h=$4
  dst_p=$5
  dst_s=$6
  host=$7
  role=$8

  # Resolve source root
  if is_local_host "$src_h"; then
    src_root="/srv/platforms/$src_p"
  else
    src_root="$src_h:/srv/platforms/$src_p"
  fi

  # Ensure destination platform and site
  if is_local_host "$dst_h"; then
    if [ ! -d "$PLATFORMS/$dst_p" ]; then
      echo "create platform $dst_p"
      cmd_platform_add "$dst_p" --no-prompt
    fi
    ANDROMEDA_ROLE=$role cmd_site_add "$dst_p" "$dst_s" --host "$host" || true
    # First local push between stages inits the platform repo and
    # checks out the destination stage branch.
    stage=$(stage_from_site "$dst_s")
    ensure_platform_git "$dst_p" "$stage" || true
    dst_root="/srv/platforms/$dst_p"
    dst_web="$dst_root/web"
  else
    echo "ensure dest site on $dst_h"
    ssh_cmd "$(tunnel_host "$dst_h")" "andromeda add platform $dst_p --no-prompt" 2>/dev/null || true
    ssh_cmd "$(tunnel_host "$dst_h")" "andromeda add site $dst_p $dst_s --host $host" || true
    stage=$(stage_from_site "$dst_s")
    # Remote dest: init the platform repo and checkout the stage branch
    # if the remote Andromeda supports ensure. Fall back to a direct init.
    ssh_cmd "$(tunnel_host "$dst_h")" "cd /srv/platforms/$dst_p &&       if [ ! -e .git ]; then git init && git add -A && git commit -m 'init platform $dst_p' --allow-empty || true;       for b in devel test live; do git branch \$b 2>/dev/null || true; done; fi &&       git checkout -B $stage" 2>/dev/null || true
    dst_root="$dst_h:/srv/platforms/$dst_p"
    dst_web="$dst_h:/srv/platforms/$dst_p/web"
  fi

  echo "code  git"
  if ! push_code_via_git "$src_h" "$src_p" "$src_s" "$dst_h" "$dst_p" "$dst_s"; then
    echo "code  git skipped — rsync web tree"
    if is_local_host "$src_h" && is_local_host "$dst_h"; then
      as_root -u "$OWNER" rsync -a --delete \
        --exclude='files/' --exclude='files_private/' \
        --exclude='sites/*/settings.local.php' \
        --exclude='sites/sites.php' \
        --exclude='sites/*/files' \
        --exclude='sites/*/' \
        "/srv/platforms/$src_p/web/" "$dst_web/" || true
    else
      as_root -u "$OWNER" rsync -a --delete \
        --exclude='files/' --exclude='files_private/' \
        --exclude='sites/*/settings.local.php' \
        --exclude='sites/sites.php' \
        --exclude='sites/*/files' \
        --exclude='sites/*/' \
        "$src_root/web/" "$dst_web/" || true
    fi
  fi

  echo "files rsync"
  if is_local_host "$src_h" && is_local_host "$dst_h"; then
    run_root mkdir -p "$dst_root/files/$dst_s" "$dst_root/files_private/$dst_s" "$dst_root/config/$dst_s/active"
    [ -d "/srv/platforms/$src_p/files/$src_s" ] && \
      as_root -u "$OWNER" rsync -a --delete "/srv/platforms/$src_p/files/$src_s/" "$dst_root/files/$dst_s/" || true
    [ -d "/srv/platforms/$src_p/files_private/$src_s" ] && \
      as_root -u "$OWNER" rsync -a --delete "/srv/platforms/$src_p/files_private/$src_s/" "$dst_root/files_private/$dst_s/" || true
    [ -d "/srv/platforms/$src_p/config/$src_s/active" ] && \
      as_root -u "$OWNER" rsync -a --delete "/srv/platforms/$src_p/config/$src_s/active/" "$dst_root/config/$dst_s/active/" || true
  else
    as_root -u "$OWNER" rsync -a --delete "$src_root/files/$src_s/" "$dst_root/files/$dst_s/" || true
    as_root -u "$OWNER" rsync -a --delete "$src_root/files_private/$src_s/" "$dst_root/files_private/$dst_s/" || true
    as_root -u "$OWNER" rsync -a --delete "$src_root/config/$src_s/active/" "$dst_root/config/$dst_s/active/" || true
  fi

  echo "db    export/import"
  bee=$(bee_bin)
  dump=$(mktemp)
  if is_local_host "$src_h"; then
    as_root -u "$OWNER" "$bee" --root="/srv/platforms/$src_p/web" --site="$src_s" db-export "$dump" 2>/dev/null || true
  else
    ssh_cmd "$(tunnel_host "$src_h")" "andromeda bee $src_p $src_s db-export -" > "$dump" 2>/dev/null || true
  fi
  if [ -s "$dump" ]; then
    if is_local_host "$dst_h"; then
      as_root -u "$OWNER" "$bee" --root="/srv/platforms/$dst_p/web" --site="$dst_s" db-import "$dump" || true
    else
      ssh_cmd "$(tunnel_host "$dst_h")" "andromeda bee $dst_p $dst_s db-import -" < "$dump" || true
    fi
  else
    echo "db    none"
  fi
  rm -f "$dump"

  if is_local_host "$dst_h"; then
    resolve_site "$dst_p" "$dst_s"
    _write_local "$root" "$web" "$product" "$host" "$role"
  fi
}
