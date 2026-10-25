#!/bin/sh
# cleanup-andromeda.sh — Modular tear-down for Andromeda
# Default: wipe the control plane, non-apt apps (Bee, Gitea, …),
# their files, and the accounts/homes those apps created.
# -p also purges the apt packages the installer added.
# Does not delete this git checkout. Does not delete the invoking login.
set -eu

PROG=${0##*/}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

export STARDUST="${STARDUST:-/srv/andromeda}"
export PLATFORMS="${PLATFORMS:-/srv/platforms}"
export DRYRUN=0
export PURGE_ALL=0
export OWNER="${OWNER:-deploy}"
export ADMIN="${ADMIN:-www-admin}"
export GROUP="${GROUP:-www-admin}"
FORCE=0

# Who launched cleanup (sudo keeps SUDO_USER). Never userdel this login.
INVOKER="${SUDO_USER:-}"
if [ -z "$INVOKER" ]; then
  INVOKER=$(logname 2>/dev/null || true)
fi
if [ -z "$INVOKER" ] && [ "$(id -u)" -ne 0 ]; then
  INVOKER=$(id -un)
fi
export INVOKER

usage() {
  cat <<EOF
Usage: $PROG [-n] [-f] [-p]
  -n  Dry run. Print destructive actions without executing them.
  -f  Force. Skip the confirmation prompt.
  -p  Also purge apt packages the installer added (Apache, PHP, MariaDB, …).

Always (with or without -p):
  stop Andromeda services
  drop bd_* and gitea databases when MariaDB still answers
  remove non-apt apps (Bee, Gitea binary + /etc/gitea + /var/lib/gitea)
  remove /srv/andromeda and /srv/platforms
  remove shipped CLIs, drop-ins, sudoers, cron, php-fpm pool, vhosts
  userdel -r app accounts (git, $OWNER, leftover $ADMIN login) and their
    /home trees; strip Andromeda groups

Never:
  delete the invoking login (${INVOKER:-unknown}) or that account's home
  delete stock daemons (www-data, mysql, root)
  delete this Andromeda git checkout
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    -n) DRYRUN=1 ;;
    -f) FORCE=1 ;;
    -p) PURGE_ALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag $1" >&2; exit 1 ;;
  esac
  shift
done

as_root() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# Run a command, or print it under -n.
do_cmd() {
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ $*"
  else
    as_root "$@" || true
  fi
}

# Remove a file or tree if it exists.
do_rm() {
  _p=$1
  [ -n "$_p" ] || return 0
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ rm -rf $_p"
    return 0
  fi
  if [ -e "$_p" ] || [ -L "$_p" ]; then
    as_root rm -rf "$_p"
    echo "  removed $_p"
  fi
}

stop_svc() {
  _name=$1
  [ -n "$_name" ] || return 0
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ stop $_name"
    return 0
  fi
  if [ -x "/etc/init.d/$_name" ]; then
    as_root "/etc/init.d/$_name" stop >/dev/null 2>&1 || true
  elif command -v systemctl >/dev/null 2>&1; then
    as_root systemctl stop "$_name" >/dev/null 2>&1 || true
  fi
}

# Accounts the installer never created and cleanup must not touch.
protected_account() {
  _n=$1
  [ -n "$_n" ] || return 0
  case $_n in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|mysql|mariadb|_apt|sshd|messagebus|systemd-network|systemd-resolve|systemd-timesync)
      return 0
      ;;
  esac
  if [ -n "$INVOKER" ] && [ "$_n" = "$INVOKER" ]; then
    return 0
  fi
  return 1
}

# userdel -r for an app account. Leaves protected logins alone.
# Always rmdir leftover /home/NAME if the passwd entry is already gone.
purge_login() {
  _name=$1
  [ -n "$_name" ] || return 0
  if protected_account "$_name"; then
    echo "  keep protected account: $_name"
    return 0
  fi
  _home=$(getent passwd "$_name" 2>/dev/null | cut -d: -f6 || true)
  if [ -z "$_home" ]; then
    _home=/home/$_name
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ userdel -r $_name  (home=${_home}; skip if absent)"
  elif id "$_name" >/dev/null 2>&1; then
    as_root userdel -r "$_name" 2>/dev/null || as_root userdel "$_name" 2>/dev/null || true
    echo "  removed login $_name"
  fi
  # Legacy or leftover homes the installer used (git, old deploy).
  case $_home in
    /home/*|"$STARDUST"/home)
      if [ -e "$_home" ]; then
        do_rm "$_home"
      fi
      ;;
  esac
  if [ -d "/home/$_name" ] && [ "/home/$_name" != "$_home" ]; then
    do_rm "/home/$_name"
  fi
}

purge_group() {
  _g=$1
  [ -n "$_g" ] || return 0
  case $_g in
    root|daemon|bin|sys|adm|tty|disk|sudo|admin|wheel|www-data|mysql|nogroup|users)
      echo "  keep protected group: $_g"
      return 0
      ;;
  esac
  if [ -n "$INVOKER" ] && [ "$_g" = "$INVOKER" ]; then
    echo "  keep invoker group: $_g"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ groupdel $_g  (skip if absent)"
  elif getent group "$_g" >/dev/null 2>&1; then
    as_root groupdel "$_g" 2>/dev/null || true
    echo "  removed group $_g"
  fi
}

if [ "$FORCE" -ne 1 ] && [ "$DRYRUN" -ne 1 ]; then
  if [ "$PURGE_ALL" -eq 1 ]; then
    printf "CRITICAL: wipe Andromeda, non-apt apps + homes, AND apt packages. Continue? [y/N]: "
  else
    printf "WARNING: wipe Andromeda, Bee/Gitea, /srv trees, and app accounts/homes. Continue? [y/N]: "
  fi
  read -r ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Tear-down aborted."; exit 0 ;; esac
fi

echo "Initializing Andromeda removal (invoker=${INVOKER:-none} owner=$OWNER)..."

# Numeric order: stop + DB drop + apt, then non-apt apps, tuning, users, trees.
if [ -d "$HERE/cleanup-modules" ]; then
  for module_path in "$HERE/cleanup-modules/"[0-9][0-9]-*.sh; do
    [ -f "$module_path" ] || continue
    echo "Running $(basename "$module_path")"
    # shellcheck source=/dev/null
    . "$module_path" || {
      echo "Error: module $(basename "$module_path") failed." >&2
      exit 1
    }
  done
else
  echo "note: no cleanup-modules/"
fi

echo "Andromeda footprint purged. Reinstall with ./install-andromeda.sh"
