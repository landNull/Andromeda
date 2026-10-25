# cleanup-modules/40-purge-deployment.sh
# Control-plane trees, shipped CLIs, man pages, host conf.

echo "STEP 40: control plane and shipped tools"
echo "---------------------------------------"

do_rm /etc/cron.d/andromeda
do_rm /etc/andromeda.conf

echo "  shipped CLIs..."
do_rm /usr/local/bin/crdir
do_rm /usr/local/bin/newfeature
do_rm /usr/local/bin/d7-migrate
do_rm /usr/local/bin/andromeda
do_rm /usr/local/bin/andromeda-menu
do_rm /usr/local/bin/andromeda-tui
do_rm /usr/local/sbin/andromeda-priv
do_rm /usr/local/sbin/install-andromeda.sh
do_rm /usr/local/sbin/andromeda-install.sh
do_rm /usr/local/lib/andromeda
do_rm /usr/local/share/andromeda
do_rm /usr/local/share/man/man1/crdir.1
do_rm /usr/local/share/man/man1/andromeda.1
do_rm /usr/local/share/man/man1/d7-migrate.1

echo "  /srv trees..."
do_rm "$STARDUST"
do_rm "$PLATFORMS"

echo "  control plane removed"
