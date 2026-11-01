# Ensure stage

`andro ensure stage PLATFORM PRODUCT` builds the skeleton for one stage. It is idempotent. `pull site` calls it on a local destination before moving code.

## What it creates

- Git worktree. `devel` uses `/srv/platforms/<plat>`. `test` and `live` get `/srv/platforms/<plat>-test` and `/srv/platforms/<plat>-live`.
- Dirs: `files/<product>`, `files_private/<product>`, `config/<product>/active`, `config/<product>/staging`.
- `settings.local.php` as the Backdrop 1.30 array. Cache is FALSE unless the stage is live.
- `sites.php` host line. `sites/<product>/files` symlink.
- `.htaccess` deny in `files_private`.

## Security checks

- Config and private files are outside the docroot.
- `settings.local.php` is mode 0640 or 0600.
- `trusted_host_patterns` is set.
- Non-live stages have cache FALSE.
- No world-writable runtime dir.

## What it does not do

It does not write config JSON. A missing `system.core.json` is a note. Config arrives from `pull site`.

## Related

- [commands](commands.md)
- [repo-ensure](repo-ensure.md)
