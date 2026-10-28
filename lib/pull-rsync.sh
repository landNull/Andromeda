# shellcheck shell=sh

# pull-rsync — internal helper. Called by cmd_site_pull.
# Code by git. Image files by rsync. Database by Bee.
# settings.local.php written once.

# pull_code ROOT WEB VPS SRC_PLATFORM
# Code moves by a git bundle. The operator pulls the bundle over SSH.
# The code owner fetches from that file and checks it out. A bundle is
# one file, so there is no temp repo, no chmod of a directory, and no
# safe.directory dance on the local side.
# See git-bundle(1): bundles exist for moving objects without a live
# git server on the far side.
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
  echo "code  bundle from ssh://$remote:$port/srv/platforms/$src_p as $op"
  # landy reads a repo owned by deploy on bjorn. Mark it safe there.
  ssh_cmd "$remote" "git config --global --add safe.directory /srv/platforms/$src_p/.git" || true
  ssh_cmd "$remote" "git config --global --add safe.directory '*'" || true
  # A file in /tmp, not a 700 directory. deploy can read a 644 file in /tmp.
  bundle=$(mktemp /tmp/andromeda-code.XXXXXX.bundle)
  if ! ssh_cmd "$remote" \
      "git -c safe.directory='*' -C /srv/platforms/$src_p bundle create - --branches" \
      > "$bundle"; then
    echo "$PROG: bundle failed — code did not move" >&2
    rm -f "$bundle"
    return 1
  fi
  chmod 0644 "$bundle" 2>/dev/null || true
  if [ ! -s "$bundle" ] || ! git bundle verify "$bundle" >/dev/null 2>&1; then
    echo "$PROG: source repo is empty — no commits on $remote:/srv/platforms/$src_p" >&2
    echo "$PROG: code did not move. Commit the platform on bjorn, then pull again." >&2
    rm -f "$bundle"
    return 0
  fi
  # The code tree belongs to deploy. Fetch and reset as that user.
  run_root chown -R "$OWNER:$GROUP" "$root" 2>/dev/null || true
  if [ ! -e "$root/.git" ]; then
    as_root -u "$OWNER" git -c safe.directory='*' -C "$root" init || { rm -f "$bundle"; return 1; }
  fi
  echo "code  fetch bundle as $OWNER"
  if ! as_root -u "$OWNER" git -c safe.directory='*' -C "$root" \
      fetch "$bundle" "+refs/heads/*:refs/remotes/origin/*"; then
    echo "$PROG: fetch from bundle failed — code did not move" >&2
    rm -f "$bundle"
    return 1
  fi
  rm -f "$bundle"
  if ! as_root -u "$OWNER" git -c safe.directory='*' -C "$root" \
      rev-parse --verify "origin/$stage" >/dev/null 2>&1; then
    echo "$PROG: no $stage branch in the bundle — code did not move" >&2
    return 0
  fi
  # Source wins. clean removes the untracked Backdrop files from
  # site-add; reset --hard puts the branch on the fetched commit.
  echo "code  reset $stage as $OWNER, source wins"
  as_root -u "$OWNER" git -c safe.directory='*' -C "$root" clean -fd >/dev/null 2>&1 || true
  as_root -u "$OWNER" git -c safe.directory='*' -C "$root" checkout -B "$stage" "origin/$stage" || return 1
  as_root -u "$OWNER" git -c safe.directory='*' -C "$root" reset --hard "origin/$stage" || return 1
  echo "code  on branch $stage as $OWNER"
}

# pull_content ROOT PRODUCT VPS SRC_PLATFORM SRC_SITE
# Rsync image files only. Everything else moves by git.
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
  # Backdrop stores uploads in files/<site> or in the site directory.
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
    rsync -a "$stage/" "$root/files/$product/" || true
    echo "images landed in $root/files/$product"
  else
    echo "images none — no image tree for $src_s on $remote"
  fi
  rm -rf "$stage"
  chown_files "$root/files/$product" 2>/dev/null || true
}

# pull_db WEB PRODUCT VPS SRC_PLATFORM SRC_SITE
pull_db() {
  web=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  bee=$(bee_bin)
  dump=$(mktemp)
  remote=$(tunnel_host "$vps")
  echo "db    export on $remote port $(ssh_port)"
  ssh_cmd "$remote" "andromeda bee $src_p $src_s db-export -" > "$dump" 2>/dev/null || \
    ssh_cmd "$remote" "bee --root=/srv/platforms/$src_p/web --site=$src_s db-export -" > "$dump" || true
  if [ -s "$dump" ]; then
    echo "db    import"
    # Site directories carry ACLs from crdir/setacl that deny everyone
    # but deploy, www-admin, and www-data. Clear them so the operator
    # can read settings.local.php, then import as the operator.
    site="$web/sites/$product"
    if command -v setfacl >/dev/null 2>&1; then
      run_root setfacl -b "$web" "$web/sites" "$site" "$site/settings.local.php" 2>/dev/null || true
    fi
    run_root chmod 0755 "$web" "$web/sites" "$site" 2>/dev/null || true
    run_root chmod 0644 "$site/settings.local.php" 2>/dev/null || true
    # Recent MariaDB dumps include a sandbox line that older clients
    # reject. Bee strips it with --mariadb-compatibility.
    if ! "$bee" --root="$web" --site="$product" db-import --mariadb-compatibility "$dump"; then
      echo "$PROG: db import failed for $product" >&2
    fi
  else
    echo "db    none"
  fi
  rm -f "$dump"
}

# pull_config ROOT PRODUCT VPS SRC_PLATFORM SRC_SITE
# Backdrop stores site configuration as JSON. The designed move is
# source active into destination staging, then bee config-import.
# https://docs.backdropcms.org/documentation/versioned-staging-directory
pull_config() {
  root=$1
  product=$2
  vps=$3
  src_p=$4
  src_s=$5
  bee=$(bee_bin)
  remote=$(tunnel_host "$vps")
  staging="$root/config/$product/staging"
  run_root mkdir -p "$staging"
  if command -v setfacl >/dev/null 2>&1; then
    run_root setfacl -b "$root/config" "$root/config/$product" "$staging" 2>/dev/null || true
  fi
  run_root chmod 0775 "$staging" 2>/dev/null || true
  # Bee owns the export. It copies active to staging on the source.
  # Then we move that staging tree and let Bee import it here.
  echo "config export on $remote"
  ssh_cmd "$remote" "bee -y --root=/srv/platforms/$src_p/web --site=$src_s config-export" || \
    ssh_cmd "$remote" "andromeda bee $src_p $src_s config-export" || true
  echo "config staging from $remote port $(ssh_port)"
  got=0
  srcs=$(ssh_cmd "$remote" "for d in /srv/platforms/$src_p/config/$src_s/staging /srv/platforms/$src_p/files/$src_s/config_*/staging /srv/platforms/$src_p/web/sites/$src_s/files/config_*/staging /srv/platforms/$src_p/web/files/config_*/staging; do [ -d \"\$d\" ] && echo \"\$d\"; done" 2>/dev/null || true)
  if [ -z "$srcs" ]; then
    echo "config none — no staging directory for $src_s on $remote"
    return 0
  fi
  for src in $srcs; do
    echo "config from $src"
    if remote_rsync "$remote:${src}/" "$staging/"; then
      got=1
      break
    fi
  done
  if [ "$got" -ne 1 ]; then
    echo "config none — staging did not arrive for $src_s"
    return 0
  fi
  if ! find "$staging" -name '*.json' -print -quit | grep -q .; then
    echo "config none — staging has no JSON"
    return 0
  fi
  echo "config landed in $staging"
  echo "config import"
  if ! "$bee" -y --root="$root/web" --site="$product" config-import; then
    echo "$PROG: config import failed for $product" >&2
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
  as_root -u "$OWNER" rsync -a --delete \
    --exclude='files/' --exclude='files_private/' \
    --exclude='sites/*/settings.local.php' \
    --exclude='sites/sites.php' \
    --exclude='sites/*/files' \
    --exclude='sites/*/' \
    "$src_web/" "$web/" || {
    echo "$PROG: local rsync web tree failed" >&2
    return 1
  }
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
  bee=$(bee_bin)
  dump=$(mktemp)
  echo "db    export local"
  as_root -u "$OWNER" "$bee" --root="/srv/platforms/$src_p/web" --site="$src_s" db-export "$dump" 2>/dev/null || true
  if [ -s "$dump" ]; then
    echo "db    import"
    as_root -u "$OWNER" "$bee" --root="$web" --site="$product" db-import "$dump" || true
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
