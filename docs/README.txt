# Andromeda documentation

  outline.md         Full map of this folder.

  tutorial.txt       Install the host, then day-to-day CLI
                     (platform-add, site-add, backup, promote).

  d7-migration.txt   Drupal 7 / BOA -> Backdrop on knarr.
                     New sysadmin walkthrough. Read this before
                     the first live convert.

On a machine after andromeda-install.sh:

  man andromeda
  man d7-migrate
  man crdir
  less /usr/local/share/andromeda/docs/d7-migration.txt
  andromeda d7 help
  andromeda d7 tools
  andromeda d7 tutorial --plan DIR

Site-specific leftover steps are written next to the plan:

  DIR/playbook.txt
  DIR/plan.json
  DIR/TUTORIAL.txt
}