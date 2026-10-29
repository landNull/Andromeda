#!/bin/sh
# modules/10-core-prereqs.sh — packages, identities, sudoers, control-plane dirs
# Sourced by install-andromeda.sh. Uses helpers from the orchestrator.

echo "STEP 10: packages, users, groups, sudoers, /srv layout"

# --- packages ----------------------------------------------------------
PKGS=$(pkg_list_for | tr '\n' ' ')
need=""
for p in $PKGS; do
  if [ "$DRYRUN" -eq 1 ]; then
    need="$need $p"
    continue
  fi
  if pkg_ok "$p"; then
    echo "package ok: $p"
  else
    need="$need $p"
  fi
done

if [ -n "$need" ]; then
  echo "packages to consider:$need"
  # shellcheck disable=SC2086
  pkg_install $need || {
    echo "$PROG: some packages are not in this distro; install the rest by hand" >&2
  }
fi

# --- users / groups ----------------------------------------------------
# Defined here so this phase works even if the orchestrator is older.
ensure_log_group() {
  name=$1
  [ -n "$name" ] || return 0
  [ "$name" = "$OWNER" ] && return 0
  if ! getent group adm >/dev/null 2>&1; then
    return 0
  fi
  if ! id "$name" >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ usermod -aG adm $name"
    return 0
  fi
  usermod_bin=$(find_admin_bin usermod || true)
  if [ -n "$usermod_bin" ]; then
    run_root "$usermod_bin" -aG adm "$name" 2>/dev/null || true
  fi
  echo "log group: $name in adm (read /var/log, not sudo)"
}

ensure_group "$GROUP"
ensure_group "$OWNER"
ensure_group andromeda
ensure_owner
if [ -n "$ADMIN" ]; then
  ensure_user "$ADMIN" "Andromeda web admin"
  ensure_andromeda_groups "$ADMIN"
  ensure_log_group "$ADMIN"
fi
# Invoking login (or -H NAME): groups only. Never useradd. Never group sudo.
if [ -n "$HUMAN" ]; then
  ensure_andromeda_groups "$HUMAN"
  ensure_log_group "$HUMAN"
fi
if id "$DAEMON" >/dev/null 2>&1; then
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ usermod -aG $GROUP $DAEMON"
  else
    run_root usermod -aG "$GROUP" "$DAEMON" 2>/dev/null || true
  fi
fi

# --- sudoers (limited; same on every host) -------------------------
# User binaries refuse sudo. Only andromeda-priv is the root helper.
# Humans get rights via group $GROUP, not via usermod -aG sudo and
# not via a per-user sudoers line.
SUDO_PRIV="# Andromeda — priv helper on $HOSTN
# $OWNER is the service account. Humans are in group $GROUP.
Defaults:$OWNER !requiretty
Defaults:%$GROUP !requiretty
$OWNER ALL=(root) NOPASSWD: /usr/local/sbin/andromeda-priv
$OWNER ALL=(root) NOPASSWD: /usr/sbin/a2ensite, /usr/sbin/a2dissite, /usr/sbin/a2enmod
%$GROUP ALL=(root) NOPASSWD: /usr/local/sbin/andromeda-priv
%$GROUP ALL=($OWNER) NOPASSWD: /usr/local/bin/bee, /usr/bin/git, /usr/bin/rsync, /usr/local/bin/crdir
"

if [ -d /etc/sudoers.d ]; then
  write_sudoers /etc/sudoers.d/andromeda-deploy "$SUDO_PRIV"
else
  echo "note: /etc/sudoers.d missing; add the limited sudo rules by hand"
fi

PROFILE=/etc/profile.d/andromeda.sh
PROFILE_BODY="# Andromeda: PATH + group-writable files for members of $GROUP
export PATH=\"/usr/local/bin:/srv/andromeda/bin:\$PATH\"
case \" \$(id -nG 2>/dev/null) \" in
  *\" $GROUP \"*)
    umask 002
    ;;
esac
"
if [ "$DRYRUN" -eq 1 ]; then
  echo "+ write $PROFILE"
else
  tmp=$(mktemp)
  printf '%s\n' "$PROFILE_BODY" > "$tmp"
  as_root install -m 0644 "$tmp" "$PROFILE"
  rm -f "$tmp"
  echo "profile: $PROFILE"
fi

# --- dirs --------------------------------------------------------------
run_root mkdir -p \
  "$STARDUST/backups" \
  "$STARDUST/bin" \
  "$STARDUST/state" \
  "$STARDUST/state/locks" \
  "$STARDUST/state/secrets" \
  "$STARDUST/hooks" \
  "$STARDUST/hooks/pre-upgrade.d" \
  "$STARDUST/hooks/post-check.d" \
  "$PLATFORMS"

run_root chown "$OWNER:$GROUP" "$STARDUST" "$STARDUST/backups" "$STARDUST/bin" "$STARDUST/state"
run_root chmod 2770 "$STARDUST" "$STARDUST/backups" "$STARDUST/bin" "$STARDUST/state"
run_root chown "$OWNER:andromeda" "$STARDUST/state/secrets"
run_root chmod 0750 "$STARDUST/state/secrets"
if have setfacl; then
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ setfacl default u:$OWNER g:$GROUP u:$DAEMON on $PLATFORMS $STARDUST"
  else
    as_root setfacl -m "u:${OWNER}:rwx,g:${GROUP}:rwx,u:${DAEMON}:rwx,o::---" \
      "$PLATFORMS" "$STARDUST" "$STARDUST/backups" 2>/dev/null || true
    as_root setfacl -d -m "u:${OWNER}:rwx,g:${GROUP}:rwx,u:${DAEMON}:rwx,o::---" \
      "$PLATFORMS" "$STARDUST" "$STARDUST/backups" 2>/dev/null || true
    as_root setfacl -b "$STARDUST/state/secrets" 2>/dev/null || true
    as_root setfacl -m "u:${OWNER}:rwx,g:andromeda:r-x,o::---" "$STARDUST/state/secrets" 2>/dev/null || true
    as_root setfacl -d -m "u:${OWNER}:rw,g:andromeda:r,o::---" "$STARDUST/state/secrets" 2>/dev/null || true
    echo "ACL default on $PLATFORMS and $STARDUST (secrets: deploy:andromeda only)"
  fi
else
  echo "note: setfacl missing — install the acl package"
fi

# HOME for $OWNER sits under $STARDUST but must not inherit www-admin/www-data.
ensure_owner_home

if [ "$DRYRUN" -eq 1 ]; then
  echo "+ # leave $PLATFORMS contents untouched"
elif [ -d "$PLATFORMS" ]; then
  echo "platforms root exists: $PLATFORMS (contents not changed)"
fi
