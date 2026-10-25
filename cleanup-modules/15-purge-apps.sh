# cleanup-modules/15-purge-apps.sh
# Non-apt apps the installer ships: Bee (git clone) and Gitea (dl.gitea.com).
# Files, init scripts, vhosts, work trees. Accounts are removed in STEP 30.

echo "STEP 15: non-apt apps (Bee, Gitea)"
echo "---------------------------------"

purge_bee() {
  echo "  Bee..."
  do_rm /usr/local/bin/bee
  do_rm /usr/local/src/bee
}

purge_gitea_service() {
  echo "  Gitea service..."
  stop_svc gitea
  if [ "$DRYRUN" -ne 1 ] && command -v systemctl >/dev/null 2>&1; then
    as_root systemctl disable gitea >/dev/null 2>&1 || true
    as_root systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [ "$DRYRUN" -ne 1 ] && command -v update-rc.d >/dev/null 2>&1; then
    as_root update-rc.d -f gitea remove >/dev/null 2>&1 || true
  fi
  do_rm /etc/systemd/system/gitea.service
  do_rm /etc/init.d/gitea
  do_rm /var/run/gitea.pid
  do_rm /run/gitea.pid
}

purge_gitea_files() {
  echo "  Gitea files..."
  do_rm /usr/local/bin/gitea
  do_rm /usr/bin/gitea
  do_rm /etc/gitea
  do_rm /var/lib/gitea
  do_rm /home/git/gitea
  if [ "$DRYRUN" -ne 1 ] && command -v a2dissite >/dev/null 2>&1; then
    as_root a2dissite andromeda-gitea >/dev/null 2>&1 || true
  fi
  do_rm /etc/apache2/sites-available/andromeda-gitea.conf
  do_rm /etc/apache2/sites-enabled/andromeda-gitea.conf
}

purge_bee
purge_gitea_service
purge_gitea_files
echo "  non-apt app files removed (accounts in STEP 30)"
