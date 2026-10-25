# cleanup-modules/30-purge-security.sh
# Sudoers, app accounts, and the groups those accounts owned.
# App homes under /home and $STARDUST/home go with userdel -r.
# The invoking login and stock daemons are left alone.

echo "STEP 30: sudoers, app accounts, groups"
echo "--------------------------------------"

purge_sudoers() {
  for slice in andromeda-deploy andromeda-admin andromeda; do
    do_rm "/etc/sudoers.d/$slice"
  done
}

# Per-user conf written by user_conf(). Do not delete the invoker's home.
strip_user_conf() {
  _name=$1
  [ -n "$_name" ] || return 0
  _home=$(getent passwd "$_name" 2>/dev/null | cut -d: -f6 || true)
  [ -n "$_home" ] || _home=/home/$_name
  if [ -f "$_home/.andromeda.conf" ]; then
    do_rm "$_home/.andromeda.conf"
  fi
}

purge_sudoers

# Invoker keeps the login; only the generated conf and extra groups go away.
if [ -n "$INVOKER" ]; then
  strip_user_conf "$INVOKER"
  if id "$INVOKER" >/dev/null 2>&1; then
    for g in "$GROUP" andromeda "$OWNER" git; do
      [ -n "$g" ] || continue
      if [ "$DRYRUN" -eq 1 ]; then
        echo "+ gpasswd -d $INVOKER $g"
      else
        as_root gpasswd -d "$INVOKER" "$g" >/dev/null 2>&1 || true
      fi
    done
  fi
fi

# App accounts the installer created (or left behind from earlier policy).
# Order: extra logins first, then owner, then git (Gitea).
if [ -n "$ADMIN" ] && [ "$ADMIN" != "$INVOKER" ]; then
  purge_login "$ADMIN"
fi
if [ -n "$OWNER" ] && [ "$OWNER" != "$INVOKER" ]; then
  purge_login "$OWNER"
fi
purge_login git

# Homes the installer used even if the passwd line is already gone.
do_rm "$STARDUST/home"
do_rm /home/git
if [ -n "$OWNER" ] && [ "$OWNER" != "$INVOKER" ]; then
  do_rm "/home/$OWNER"
fi
if [ -n "$ADMIN" ] && [ "$ADMIN" != "$INVOKER" ] && [ "$ADMIN" != www-data ]; then
  do_rm "/home/$ADMIN"
fi

# Groups after the logins are gone. www-admin is group-only by current policy.
purge_group git
purge_group andromeda
if [ -n "$OWNER" ]; then
  purge_group "$OWNER"
fi
if [ -n "$GROUP" ]; then
  purge_group "$GROUP"
fi
if [ -n "$ADMIN" ] && [ "$ADMIN" != "$GROUP" ]; then
  purge_group "$ADMIN"
fi

echo "  security identities removed"
