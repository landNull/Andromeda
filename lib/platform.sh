# shellcheck shell=sh

write_gitignore() {
  # local name: dest is the platform path in the caller
  target=$1
  if [ -f "$target" ]; then
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $target"
    return 0
  fi
  cat > "$target" <<'EOF'
web/sites/*/settings.local.php
files/
files_private/
config/*/active/
*.sql
.DS_Store
EOF
}


cmd_repo_ensure() {
  name=${1:-}
  name=$(slug "$name")
  if [ -z "$name" ]; then
    echo "usage: $PROG repo-ensure NAME" >&2
    exit 2
  fi
  bare=/srv/git/$name.git
  work=$PLATFORMS/$name
  echo "repo $name"
  if [ ! -d "$bare" ]; then
    echo "bare $bare"
    mkdir -p /srv/git
    git init --bare "$bare"
    chown -R "$OWNER:$OWNER" "$bare" 2>/dev/null || true
  fi
  if [ ! -d "$work/.git" ]; then
    echo "checkout $work"
    git clone "$bare" "$work"
    chown -R "$OWNER:$GROUP" "$work" 2>/dev/null || true
  fi
  for b in devel test live; do
    git -C "$work" show-ref --verify --quiet "refs/heads/$b" || git -C "$work" checkout -B "$b"
  done
  git -C "$work" checkout devel
  state=/srv/andromeda/state/platforms
  mkdir -p "$state"
  cat > "$state/$name.json" << JSON
{
  "platform": "$name",
  "bare": "$bare",
  "checkout": "$work",
  "remote": "deploy@10.8.0.1:$bare"
}
JSON
  echo "repo ready $name"
}

cmd_platform_add() {
  name=${1:-}
  shift || true
  giturl=""
  branch=""
  while [ $# -gt 0 ]; do
    case $1 in
      --git) giturl=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --no-prompt) ANDROMEDA_NOPROMPT=1; shift ;;
      *) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
    esac
  done
  name=$(slug "$name")
  if [ -z "$name" ]; then
    echo "usage: $PROG platform-add NAME [--git URL] [--branch BRANCH] [--no-prompt]" >&2
    echo "  default: clone ANDROMEDA_GIT_TEMPLATE (use %s for NAME) onto branch $(branch_for_role)" >&2
    echo "  --branch overrides BRANCH_DEVEL / BRANCH_TEST / BRANCH_LIVE / ANDROMEDA_BRANCH" >&2
    exit 2
  fi
  if [ -z "$branch" ]; then
    branch=$(branch_for_role)
  fi
  if [ -z "$giturl" ] && [ -d /srv/git -o "$(id -u)" -eq 0 ]; then
    cmd_repo_ensure "$name"
    giturl=/srv/git/$name.git
  fi
  if [ -z "$giturl" ] && git_template_ok "${ANDROMEDA_GIT_TEMPLATE:-}"; then
    giturl=$(printf '%s' "$ANDROMEDA_GIT_TEMPLATE" | sed "s|%s|$name|g")
  fi
  if [ -z "$giturl" ] && [ "${ANDROMEDA_NOPROMPT:-0}" != 1 ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ prompt Git SSH host / owner if this is a terminal (skip with --no-prompt)"
    else
      prompted=$(ask_git_remote "$name" || true)
      if [ -n "$prompted" ]; then
        giturl=$prompted
      fi
    fi
  fi

  dest=$PLATFORMS/$name
  if [ -e "$dest" ] && [ "$DRYRUN" -eq 0 ]; then
    echo "$PROG: $dest already exists — not touching it"
    echo "Add a product with: $PROG site-add $name PRODUCT"
    return 0
  fi

  run_root mkdir -p "$PLATFORMS"
  if [ -n "$giturl" ]; then
    echo "clone $giturl branch $branch -> $dest"
    run_root git clone --branch "$branch" "$giturl" "$dest" || run_root git clone "$giturl" "$dest"
  else
    run_root mkdir -p "$dest"
    run_root chown "$OWNER:$GROUP" "$dest"
    bee=$(bee_bin)
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ cd $dest && $bee dl-core web"
    else
      # dl-core creates the dest relative to cwd, not --root.
      # Do not use sh -c: sudoers allows /usr/local/bin/bee, not /bin/sh.
      ( cd "$dest" && as_root -u "$OWNER" "$bee" dl-core web )
    fi
  fi

  run_root chown -R "$OWNER:$GROUP" "$dest"
  write_gitignore "$dest/.gitignore"

  if [ "$DRYRUN" -eq 0 ] && [ ! -e "$dest/.git" ]; then
    as_root -u "$OWNER" git -C "$dest" init
    as_root -u "$OWNER" git -C "$dest" checkout -B "$branch" 2>/dev/null || true
  fi

  echo "platform $name ready at $dest"
  echo "next: $PROG site-add $name <product> [--host host.example]"
}

list_products() {
  web=$1
  if [ ! -d "$web/sites" ]; then
    return 0
  fi
  for s in "$web/sites"/*; do
    [ -d "$s" ] || continue
    base=${s##*/}
    case $base in default|all) continue ;; esac
    if [ -f "$s/settings.php" ] || [ -f "$s/settings.local.php" ]; then
      printf '%s\n' "$base"
    fi
  done
}

cmd_platform_upgrade() {
  nopull=0
  name=""
  while [ $# -gt 0 ]; do
    case $1 in
      --no-pull) nopull=1; shift ;;
      *)
        if [ -z "$name" ]; then name=$1; shift; else
          echo "$PROG: unknown arg $1" >&2; exit 2
        fi
        ;;
    esac
  done
  name=$(slug "$name")
  if [ -z "$name" ]; then
    echo "usage: $PROG platform-upgrade PLATFORM [--no-pull]" >&2
    exit 2
  fi
  root=$PLATFORMS/$name
  web=$root/web
  if [ ! -d "$web" ]; then
    echo "$PROG: no platform $root" >&2
    exit 1
  fi

  products=$(list_products "$web")
  if [ -z "$products" ]; then
    echo "$PROG: no products under $web/sites" >&2
    exit 1
  fi

  echo "upgrade $name — backup every product first"
  run_hooks pre-upgrade "$name"
  for product in $products; do
    cmd_site_backup "$name" "$product" || {
      echo "$PROG: backup failed for $product — upgrade aborted" >&2
      exit 1
    }
  done

  if [ "$ANDROMEDA_ROLE" = live ] || [ "$ANDROMEDA_ROLE" = test ]; then
    for product in $products; do
      mm_set "$web" "$product" 1
    done
  fi

  if [ "$nopull" -eq 1 ]; then
    echo "upgrade $name --no-pull"
  elif [ "$DRYRUN" -eq 1 ]; then
    echo "+ git -C $root pull --ff-only"
  else
    if [ -e "$root/.git" ]; then
      as_root -u "$OWNER" git -C "$root" pull --ff-only
    else
      note "$root is not a git checkout — skip pull"
    fi
  fi

  fail=0
  for product in $products; do
    bee_yes --root="$web" --site="$product" updb
    bee_yes --root="$web" --site="$product" config-import || true
    cmd_site_check "$name" "$product" || {
      echo "$PROG: site-check failed for $product after upgrade" >&2
      echo "$PROG: site was NOT auto-restored" >&2
      fail=1
    }
    mm_set "$web" "$product" 0
    chown_files "$root/files/$product" "$root/files_private/$product" "$root/config/$product/active" 2>/dev/null || true
  done
  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  echo "upgrade $name done"
}


cmd_platform_remove() {
  name=${1:-}
  name=$(slug "$name")
  if [ -z "$name" ]; then
    echo "usage: $PROG platform remove NAME" >&2
    exit 2
  fi
  dest=$PLATFORMS/$name
  if [ ! -d "$dest" ]; then
    echo "$PROG: no platform $name" >&2
    exit 1
  fi

  printf "ARE YOU SURE YOU WANT TO DELETE %s?!? [y/N] " "$name"
  read -r ok
  [ "$ok" = "y" ] || { echo "stopped"; return 0; }
  echo "deleting $name in 5 seconds. Ctrl-C to stop."
  i=5
  while [ "$i" -gt 0 ]; do
    printf "  %s\r" "$i"
    sleep 1
    i=$((i - 1))
  done
  echo
  echo "backup $name"
  stamp=$(date +%Y%m%d-%H%M%S)
  snap=/srv/andromeda/backups/$name/platform/$stamp
  sudo mkdir -p "$snap"
  sudo tar -C "$PLATFORMS" -czf "$snap/tree.tgz" "$name" || {
    echo "$PROG: backup failed, not removing" >&2
    exit 1
  }
  echo "snap  $snap/tree.tgz"

  echo "remove $name"
  for role in devel test live; do
    sudo a2dissite "$name-$role" >/dev/null 2>&1 || true
    sudo rm -f "/etc/apache2/sites-available/$name-$role.conf"
  done
  sudo rm -rf "$dest"
  sudo rm -rf "/srv/git/$name.git"
  sudo rm -f "/srv/andromeda/state/platforms/$name.json"
  sudo rm -f "/srv/andromeda/state/migrate/$name"
  apache_reload || true
  echo "removed $name"
  echo "backup  $snap/tree.tgz"
}


# Platform lock — Aegir-style: prevent new site provisioning.
# Stored as a flag file next to the platform json.

platform_lock_file() {
  name=$1
  echo "/srv/andromeda/state/platforms/${name}.lock"
}

platform_is_locked() {
  name=$1
  [ -f "$(platform_lock_file "$name")" ]
}

cmd_platform_lock() {
  name=${1:-}
  name=$(slug "$name")
  if [ -z "$name" ]; then
    echo "usage: $PROG lock platform NAME" >&2
    exit 2
  fi
  dest=$PLATFORMS/$name
  if [ ! -d "$dest" ]; then
    echo "$PROG: platform $name not found" >&2
    exit 1
  fi
  lock=$(platform_lock_file "$name")
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ touch $lock"
    return 0
  fi
  mkdir -p "$(dirname "$lock")" 2>/dev/null || run_root mkdir -p "$(dirname "$lock")"
  touch "$lock" 2>/dev/null || run_root touch "$lock"
  echo "locked platform $name (no new sites)"
}

cmd_platform_unlock() {
  name=${1:-}
  name=$(slug "$name")
  if [ -z "$name" ]; then
    echo "usage: $PROG unlock platform NAME" >&2
    exit 2
  fi
  lock=$(platform_lock_file "$name")
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ rm -f $lock"
    return 0
  fi
  rm -f "$lock" 2>/dev/null || run_root rm -f "$lock"
  echo "unlocked platform $name"
}
