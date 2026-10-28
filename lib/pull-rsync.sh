# shellcheck shell=sh

# pull-rsync — internal helper. Called by cmd_site_pull.
# Code by git. Image files by rsync. Database by Bee.
# settings.local.php written once.

# pull_code ROOT WEB VPS SRC_PLATFORM
# Code moves by git. Images move by rsync in pull_content.
pull_code() {
  root=$1
  web=$2
  vps=$3
  src_p=$4
  # The person running andro. On knarr this is landy. Not deploy.
  op=$(id -un)
  remote=$(tunnel_host "$vps")
  port=$(ssh_port)
  url="ssh://$remote:$port/srv/platforms/$src_p"
  echo "code  git from $url as $op"
  # The platform repo is owned by deploy. Git refuses it as dubious
  # ownership unless the SSH user has marked it safe.
  echo "code  mark safe.directory on $remote"
  ssh_cmd "$remote" "git config --global --add safe.directory /srv/platforms/$src_p/.git" || true
  ssh_cmd "$remote" "git config --global --add safe.directory '*'" || true
  # Fetch as the operator. Deploy is nologin and has no key.
  bare=$(mktemp -d)
  export GIT_SSH_COMMAND="ssh -p $port -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  if ! git -c safe.directory='*' clone --bare "$url" "$bare/src.git"; then
    echo "$PROG: git fetch failed — code did not move" >&2
    rm -rf "$bare"
    return 1
  fi
  unset GIT_SSH_COMMAND
  # Hand the platform tree to the operator so checkout can write.
  run_root chown -R "$op:$GROUP" "$root" 2>/dev/null || true
  if [ ! -e "$root/.git" ]; then
    git -c safe.directory='*' -C "$root" init || { rm -rf "$bare"; return 1; }
  fi
  if ! git -c safe.directory='*' -C "$root" fetch "$bare/src.git" "+refs/heads/*:refs/remotes/origin/*"; then
    echo "$PROG: local fetch from staged repo failed" >&2
    rm -rf "$bare"
    return 1
  fi
  # An empty source repo has no commits. Do not invent a branch from
  # FETCH_HEAD. Code cannot move until bjorn has a commit on this platform.
  if ! git -c safe.directory='*' --git-dir="$bare/src.git" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "$PROG: source repo is empty — no commits on $remote:/srv/platforms/$src_p" >&2
    echo "$PROG: code did not move. Commit the platform on bjorn, then pull again." >&2
    rm -rf "$bare"
    return 0
  fi
  rm -rf "$bare"
  stage=${role:-devel}
  if git -c safe.directory='*' -C "$root" rev-parse --verify "origin/$stage" >/dev/null 2>&1; then
    git -c safe.directory='*' -C "$root" checkout -B "$stage" "origin/$stage" || return 1
  elif git -c safe.directory='*' -C "$root" rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
    git -c safe.directory='*' -C "$root" checkout -B "$stage" FETCH_HEAD || return 1
  else
    echo "$PROG: no $stage branch on source — code did not move" >&2
    return 0
  fi
  echo "code  on branch $stage as $op"
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
    # The tree was handed to the operator. Bee as deploy cannot read
    # settings.local.php through landy-owned directories. Import as
    # the operator, who can.
    op=$(id -un)
    chmod 0755 "$web/sites" "$web/sites/$product" 2>/dev/null || true
    chmod 0644 "$web/sites/$product/settings.local.php" 2>/dev/null || true
    if ! "$bee" --root="$web" --site="$product" db-import "$dump"; then
      echo "$PROG: db import failed for $product" >&2
    fi
  else
    echo "db    none"
  fi
  rm -f "$dump"
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
