# shellcheck shell=sh
# Shared helpers. Sourced by /usr/local/bin/stardust — not run alone.

load_conf() {
  for f in \
    "${STARDUST_CONF:-}" \
    "$HOME/.stardust.conf" \
    /etc/stardust.conf
  do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      return 0
    fi
  done
  return 0
}

load_conf

STARDUST_ROOT=${STARDUST_ROOT:-/srv/stardust}
PLATFORMS=${PLATFORMS:-/srv/platforms}
OWNER=${OWNER:-deploy}
HUMAN=${HUMAN:-}
DAEMON=${DAEMON:-www-data}
GROUP=${GROUP:-www-admin}
# Optional extra login. Same string as GROUP means group-only (legacy conf).
ADMIN=${ADMIN:-}
if [ -n "$ADMIN" ] && [ "$ADMIN" = "$GROUP" ]; then
  ADMIN=""
fi
DIR_MODE=${DIR_MODE:-0770}

PRIV=${PRIV:-/usr/local/sbin/stardust-priv}

priv() {
  if [ -x "$PRIV" ]; then
    as_root "$PRIV" "$@"
  else
    return 1
  fi
}

# PHP-writable trees: www-data:www-admin + setgid + default ACL
chown_files() {
  if priv chown-files "$@"; then
    priv setacl "$@" || true
    return 0
  fi
  run_root chown -R "$DAEMON:$GROUP" "$@"
}

# code / backups / control plane: deploy:www-admin
chown_code() {
  if priv chown-code "$@"; then
    priv setacl "$@" || true
    return 0
  fi
  run_root chown -R "$OWNER:$GROUP" "$@"
}

chown_secret() {
  if priv chown-secret "$@"; then
    priv setacl-secret "$@" || true
    return 0
  fi
  run_root chown -R "$OWNER:stardust" "$@"
  run_root chmod 0640 "$@"
}
BEE=${BEE:-bee}
APACHE_RELOAD=${APACHE_RELOAD:-/etc/init.d/apache2 reload}
STARDUST_ROLE=${STARDUST_ROLE:-devel}
# Git branch for this role. Override per role in /etc/stardust.conf
#   BRANCH_DEVEL=main BRANCH_TEST=staging BRANCH_LIVE=production
# Or pin one name on this host: STARDUST_BRANCH=main
branch_for_role() {
  role=${1:-$STARDUST_ROLE}
  if [ -n "${STARDUST_BRANCH:-}" ]; then
    printf '%s\n' "$STARDUST_BRANCH"
    return 0
  fi
  case $role in
    devel) printf '%s\n' "${BRANCH_DEVEL:-devel}" ;;
    test)  printf '%s\n' "${BRANCH_TEST:-test}" ;;
    live)  printf '%s\n' "${BRANCH_LIVE:-live}" ;;
    *)     printf '%s\n' "$role" ;;
  esac
}

is_tty() {
  [ -t 0 ] && [ -t 2 ]
}

# Placeholders from docs are not a real template.
git_template_ok() {
  t=${1:-}
  [ -n "$t" ] || return 1
  case $t in
    *YOURORG*|*git.example*|*example.com*) return 1 ;;
  esac
  return 0
}

show_help_pager() {
  # apt-listchanges style: pager, then q returns to the prompt.
  text=$1
  [ -n "$text" ] || return 0
  pager=${PAGER:-}
  if [ -z "$pager" ] && command -v sensible-pager >/dev/null 2>&1; then
    pager=sensible-pager
  fi
  if [ -z "$pager" ] && command -v less >/dev/null 2>&1; then
    pager="less -F -X -E"
  fi
  if [ -z "$pager" ] && command -v more >/dev/null 2>&1; then
    pager=more
  fi
  if [ -n "$pager" ]; then
    printf '%s\n' "$text" | $pager
  else
    printf '%s\n' "$text" >&2
    printf 'Press Enter to continue... ' >&2
    IFS= read -r _ || true
  fi
}

prompt_line() {
  # prompt_line "Question" "default" [help_text] [needed]
  # Type ? or help to open the pager. Empty keeps the default.
  q=$1
  def=${2:-}
  help=${3:-}
  needed=${4:-}
  while :; do
    if [ -n "$help" ]; then
      printf '%s  (? help)\n' "$q" >&2
    else
      printf '%s\n' "$q" >&2
    fi
    if [ -n "$needed" ]; then
      printf '%s\n' "$needed" >&2
    fi
    if [ -n "$def" ]; then
      printf '> [%s]: ' "$def" >&2
    else
      printf '> ' >&2
    fi
    IFS= read -r ans || ans=
    case $ans in
      \?|help|HELP)
        if [ -n "$help" ]; then
          show_help_pager "$help"
        else
          echo "(no extra help for this question)" >&2
        fi
        continue
        ;;
    esac
    if [ -z "$ans" ]; then
      ans=$def
    fi
    printf '%s\n' "$ans"
    return 0
  done
}

save_git_template() {
  tpl=$1
  dest=${STARDUST_USER_CONF:-$HOME/.stardust.conf}
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ append STARDUST_GIT_TEMPLATE=$tpl -> $dest" >&2
    return 0
  fi
  if [ -f "$dest" ] && grep -q '^STARDUST_GIT_TEMPLATE=' "$dest" 2>/dev/null; then
    tmp=$dest.tmp
    sed "s|^STARDUST_GIT_TEMPLATE=.*|STARDUST_GIT_TEMPLATE=$tpl|" "$dest" > "$tmp" && mv "$tmp" "$dest"
  else
    printf '\nSTARDUST_GIT_TEMPLATE=%s\n' "$tpl" >> "$dest"
  fi
  STARDUST_GIT_TEMPLATE=$tpl
  echo "saved STARDUST_GIT_TEMPLATE in $dest" >&2
}

# Scan this login for a likely git SSH host / owner. Best-effort, never fatal.
detect_git_host() {
  if [ -n "${GIT_HOST:-}" ]; then
    printf '%s\n' "$GIT_HOST"
    return 0
  fi
  # ~/.ssh/config Host lines that look like a git forge
  if [ -f "$HOME/.ssh/config" ]; then
    hit=$(awk 'tolower($1)=="host" {
      for (i=2;i<=NF;i++) {
        h=$i
        if (h ~ /[*?]/) next
        if (h ~ /gitea|github|gitlab|gitbucket|codeberg|sr.ht|git\./) { print h; exit }
      }
    }' "$HOME/.ssh/config" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
    hit=$(awk 'tolower($1)=="host" && $2 !~ /[*?]/ { print $2; exit }' "$HOME/.ssh/config" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
  fi
  # remotes already on this box
  for root in "$PLATFORMS" "$HOME" /srv/platforms; do
    [ -d "$root" ] || continue
    hit=$(find "$root" -maxdepth 4 -type d -name .git 2>/dev/null | head -n 20 | while read -r g; do
      git --git-dir="$g" remote get-url origin 2>/dev/null || true
    done | sed -n 's/^git@\([^:]*\):.*/\1/p; s|^ssh://git@\([^/]*\)/.*|\1|p' | head -n 1)
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
  done
  # insteadOf / url.*.insteadof
  if have git; then
    hit=$(git config --global --get-regexp '^url\..*\.insteadof' 2>/dev/null | sed -n 's/^url\.git@\([^:/]*\).*/\1/p' | head -n 1)
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
  fi
}

detect_git_owner() {
  if [ -n "${GIT_OWNER:-}" ]; then
    printf '%s\n' "$GIT_OWNER"
    return 0
  fi
  for root in "$PLATFORMS" "$HOME" /srv/platforms; do
    [ -d "$root" ] || continue
    hit=$(find "$root" -maxdepth 4 -type d -name .git 2>/dev/null | head -n 20 | while read -r g; do
      git --git-dir="$g" remote get-url origin 2>/dev/null || true
    done | sed -n 's/^git@[^:]*:\([^/]*\)\/.*/\1/p; s|^https://[^/]*/\([^/]*\)/.*|\1|p' | head -n 1)
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
  done
  if have git; then
    hit=$(git config --global github.user 2>/dev/null || true)
    [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  fi
}

# Interactive only when stdin is a terminal and --git / usable template missing.
ask_git_remote() {
  name=$1
  if ! is_tty; then
    return 1
  fi
  scan_host=$(detect_git_host || true)
  scan_owner=$(detect_git_owner || true)
  echo "No git URL yet. platform-add clones a repo (site-add does not)." >&2
  use=$(prompt_line "Use an existing git repo?" "Y" "" \
    "Y clones git@HOST:OWNER/NAME.git. n skips git and uses Bee to download Backdrop core.")
  case $use in
    n|N|no|NO)
      echo "Skipping git repo, using Bee to download Backdrop core into web/." >&2
      return 1
      ;;
  esac
  if [ -n "$scan_host" ] || [ -n "$scan_owner" ]; then
    echo "scanned this login: host=${scan_host:-?} owner=${scan_owner:-?}" >&2
  fi
  help_host="Git SSH host

This is the name your machine uses in git@HOST:org/repo.git
It is often a Host line in ~/.ssh/config (example: gitforge),
not necessarily a public DNS name.

Stardust scanned this login for SSH config and existing remotes.
Accept the default with Enter. Clear the line to skip git and let
Bee download a fresh Backdrop tree instead.

q in the pager returns here. Type your answer after that."
  help_owner="Git owner / org

This is the first path component after the colon:
  git@HOST:OWNER/%s.git

On Gitea it is the organization or your username.
On GitHub it is example or an org name.
%s becomes the platform name (myapp, wiki, …).

q in the pager returns here."
  host=$(prompt_line "Git SSH host — machine name in git@HOST:…" "${scan_host}" "$help_host" \
    "Needed: the HOST in git@HOST:org/repo.git — usually an SSH alias like gitforge.")
  if [ -z "$host" ]; then
    return 1
  fi
  owner=$(prompt_line "Git owner/org — first path after the colon" "${scan_owner}" "$help_owner" \
    "Needed: the org or username after the colon (acme in git@HOST:acme/myapp.git).")
  if [ -z "$owner" ]; then
    echo "$PROG: owner/org required for a template" >&2
    return 1
  fi
  tpl="git@${host}:${owner}/%s.git"
  url=$(printf '%s' "$tpl" | sed "s|%s|$name|g")
  echo "template: $tpl" >&2
  echo "this platform: $url" >&2
  save=$(prompt_line "Save template to ~/.stardust.conf for next time?" "Y")
  case $save in
    Y|y|yes|YES) save_git_template "$tpl" ;;
  esac
  printf '%s\n' "$url"
}

DB_HOST=${DB_HOST:-127.0.0.1}
DB_PREFIX=${DB_PREFIX:-bd_}
KEEP_BACKUPS=${KEEP_BACKUPS:-7}
NOTIFY=${NOTIFY:-}
HOOKS=${HOOKS:-$STARDUST_ROOT/hooks}

run_hooks() {
  hook_name=$1
  shift
  dir=$HOOKS/${hook_name}.d
  [ -d "$dir" ] || return 0
  for h in "$dir"/*; do
    [ -x "$h" ] || continue
    if [ "${DRYRUN:-0}" -eq 1 ]; then
      echo "+ hook $h $*"
    else
      echo "hook $h"
      "$h" "$@" || note "hook $h exited $?"
    fi
  done
}

bee_yes() {
  bee=$(bee_bin)
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ $bee -y $*"
    return 0
  fi
  if as_root -u "$OWNER" "$bee" -y "$@"; then
    return 0
  fi
  printf 'y\n' | as_root -u "$OWNER" "$bee" "$@"
}

notify_fail() {
  msg=$1
  if have logger; then
    logger -t stardust -- "$msg" || true
  fi
  if [ -n "$NOTIFY" ] && have mail; then
    printf '%s\n' "$msg" | mail -s "stardust: $msg" "$NOTIFY" || true
  fi
}

in_group() {
  echo " $(id -nG 2>/dev/null) " | grep -q " $1 "
}

# Missing required groups -> return 1 and print usermod for self or admin.
check_operator_groups() {
  me=$(id -un)
  need="$GROUP stardust"
  nice="adm $OWNER"
  miss_need=""
  miss_nice=""
  for g in $need; do
    [ -n "$g" ] || continue
    if ! getent group "$g" >/dev/null 2>&1; then
      miss_need="$miss_need $g"
      continue
    fi
    in_group "$g" || miss_need="$miss_need $g"
  done
  for g in $nice; do
    [ -n "$g" ] || continue
    getent group "$g" >/dev/null 2>&1 || continue
    in_group "$g" || miss_nice="$miss_nice $g"
  done
  if [ -z "$miss_need" ] && [ -z "$miss_nice" ]; then
    return 0
  fi
  echo "$PROG: user $me is missing group membership" >&2
  if [ -n "$miss_need" ]; then
    echo "$PROG: required:$miss_need" >&2
  fi
  if [ -n "$miss_nice" ]; then
    echo "$PROG: recommended:$miss_nice" >&2
  fi
  all=$(echo "$miss_need $miss_nice" | tr -s ' ' | sed 's/^ //;s/ $//')
  echo "$PROG: add yourself (if you have sudo):" >&2
  echo "  sudo usermod -aG $(echo "$all" | tr ' ' ',') $me" >&2
  echo "  then a new login shell (exec bash / exec zsh do NOT refresh groups):" >&2
  echo "    exec su - $me" >&2
  echo "    # or: newgrp $GROUP" >&2
  echo "    # or log out and back in" >&2
  echo "$PROG: or ask an admin to run that usermod for $me" >&2
  [ -n "$miss_need" ] && return 1
  return 0
}

have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  for d in /usr/sbin /sbin /usr/bin /bin; do
    [ -x "$d/$1" ] && return 0
  done
  return 1
}
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; }
note() { printf '  note  %s\n' "$1"; }

# Root only when needed. Prefer sudo -n (NOPASSWD).
# Capcom mode (STARDUST_SPEAK or STARDUST_JSON) never prompts.
# deploy is a system account: never authenticate as deploy.
as_root() {
  capcom=0
  if [ -n "${STARDUST_SPEAK:-}" ] || [ -n "${STARDUST_JSON:-}" ]; then
    capcom=1
  fi
  refuse() {
    printf 'SPEAK: sudo needs a password. Capcom cannot type one. Add NOPASSWD for stardust-priv bee git crdir.\n' >&2
    printf '%s\n' '{"module":"sudo","status":"fail","what":"NOPASSWD missing"}' >&2
    return 1
  }
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  if [ "${1:-}" = "-u" ]; then
    tgt=$2
    shift 2
    if [ "$(id -un)" = "$tgt" ]; then
      "$@"
      return $?
    fi
    if have sudo && sudo -n -u "$tgt" true >/dev/null 2>&1; then
      sudo -n -u "$tgt" "$@"
      return $?
    fi
    if [ "$capcom" -eq 1 ]; then
      refuse
      return 1
    fi
    if [ -n "${STARDUST_SUDO_ASKPASS:-}" ] && [ -x "$STARDUST_SUDO_ASKPASS" ]; then
      echo "sudo -A -u $tgt $*" >&2
      SUDO_ASKPASS=$STARDUST_SUDO_ASKPASS sudo -A -u "$tgt" "$@"
      return $?
    fi
    sudo -u "$tgt" "$@"
    return $?
  fi
  priv=${PRIV:-/usr/local/sbin/stardust-priv}
  # Capcom: group writes stay with the operator. Root verbs go through the helper.
  if [ "$capcom" -eq 1 ]; then
    case $1 in
      mkdir|chmod)
        sudo -n "$priv" "$@" 2>/dev/null || "$@"
        return $?
        ;;
      chown)
        shift
        sudo -n "$priv" chown-files "$@" 2>/dev/null || true
        return 0
        ;;
      sed|tee|cp)
        "$@"
        return $?
        ;;
    esac
    if [ "$1" = "sh" ]; then
      sudo -n "$priv" apache-reload 2>/dev/null || true
      return 0
    fi
  fi
  if have sudo && sudo -n -l "$priv" >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi
  if [ "$capcom" -eq 1 ]; then
    refuse
    return 1
  fi
  if [ -n "${STARDUST_SUDO_ASKPASS:-}" ] && [ -x "$STARDUST_SUDO_ASKPASS" ]; then
    echo "sudo -A (askpass) $*" >&2
    SUDO_ASKPASS=$STARDUST_SUDO_ASKPASS sudo -A "$@"
    return $?
  fi
  sudo "$@"
}

run() {
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    printf '+'
    for a in "$@"; do
      printf ' %s' "$a"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

run_root() {
  if [ "${DRYRUN:-0}" -eq 1 ]; then
    printf '+'
    for a in "$@"; do
      printf ' %s' "$a"
    done
    printf '\n'
    return 0
  fi
  as_root "$@"
}

bee_bin() {
  if have "$BEE"; then
    command -v "$BEE"
  elif have bee; then
    command -v bee
  else
    echo "$PROG: bee not on PATH" >&2
    exit 1
  fi
}

need_crdir() {
  if have crdir; then
    command -v crdir
  else
    echo "$PROG: crdir not on PATH" >&2
    exit 1
  fi
}

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/^-*//;s/-*$//'
}

db_name() {
  product=$1
  role=${2:-$STARDUST_ROLE}
  n="${DB_PREFIX}${product}_${role}"
  printf '%s' "$n" | tr -c 'a-z0-9_' '_' | cut -c1-64
}

resolve_site() {
  # sets root web platform product or exits
  platform=$(slug "${1:-}")
  product=$(slug "${2:-}")
  if [ -z "$platform" ] || [ -z "$product" ]; then
    echo "usage: $PROG $cmd PLATFORM PRODUCT" >&2
    exit 2
  fi
  root=$PLATFORMS/$platform
  web=$root/web
  if [ ! -d "$root" ]; then
    echo "$PROG: no platform $root" >&2
    exit 1
  fi
  if [ ! -d "$web" ]; then
    echo "$PROG: $web missing" >&2
    exit 1
  fi
}

stamp() {
  date +%Y%m%d-%H%M%S
}

backup_dir() {
  platform=$1
  product=$2
  role=${3:-$STARDUST_ROLE}
  echo "$STARDUST_ROOT/backups/$platform/$product/$role"
}
