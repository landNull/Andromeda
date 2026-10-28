# Andromeda command surface

andro (Andromeda) accepts verb-first commands. Object-first forms remain as aliases.

## Preferred form

```
andro pull site @bjorn:ecom/keslerlumber.live to @knarr:ecom/keslerlumber.devel
andro push site ecom/keslerlumber.devel to ecom/keslerlumber.test
andro push site @knarr:ecom/keslerlumber.test to @bjorn:ecom/keslerlumber.live
andro push site @knarr:ecom/keslerlumber.test to @bjorn:ecom/keslerlumber.live hostname keslerlumber.net
andro add platform ecom
andro add site ecom kl_devel
andro heal site ecom kl_devel
andro heal all
andro list sites
andro list platforms
andro promote platform ecom to test
andro backup site ecom kl_devel
andro restore site ecom kl_devel
andro clone site ecom kl_test ecom kl_devel
andro debug site ecom kl_devel
andro check site ecom kl_devel
andro disable site ecom kl_devel
andro enable site ecom kl_devel
andro delete site ecom kl_devel
andro lock platform ecom
andro unlock platform ecom
andro verify site ecom kl_devel
andro verify platform ecom
andro verify all
andro login-reset site ecom kl_devel
andro install site ecom kl_devel          # alias of add site
andro remove platform ecom
andro upgrade platform ecom
```

`to` is optional and ignored when present.

## Alias form

`andromeda site pull`, `andromeda platform add`, `andromeda site-pull`, and the other hyphen forms still dispatch to the same functions.

## Why

Captain Rocket emits natural language. Verb-first matches how a human says the action, so Capcom has less to rewrite before the call.

## test

`andromeda test <command> [args…]` runs a preflight before the real command.

If the command names a platform and product, `test` runs `site-debug`. Healable failures (missing dirs, settings, trusted host, ownership) are passed to `site-heal`. The check is repeated. If it still fails, the real command is refused. If it passes, the command runs.

If no site target is present, `test` runs `doctor` and refuses on failure.

```
andro test pull site @bjorn:ecom/kl_test to @knarr:ecom/kl_devel
andro test site-check ecom kl_devel
```

## Logging

Every mutating command writes two records:

- A one-line journal entry in `$ANDROMEDA_ROOT/state/tasks.log` with UTC timestamp, host, role, user, command, return code, and the path of the run log.
- A per-run log in `$ANDROMEDA_ROOT/state/logs/YYYY-MM-DDTHH-MM-SSZ-cmd.log` that captures stdout and stderr. `$ANDROMEDA_ROOT/state/logs/latest.log` is a symlink to the most recent. Failures are also appended to `$ANDROMEDA_ROOT/state/errors.log`.

`andromeda log` shows the latest run log and the journal tail. `andromeda last` prints the path of the latest run log.

## File movement

Code and versioned config move by Git (`platform-add`, `platform-upgrade`, `promote`, `pull site`). User content (`files/`, `files_private/`, database) moves by Bee and rsync. `settings.local.php` is written once, by a single template pass, never appended. `sites.php` mappings belong in the platform repo.

`lib/pull-rsync.sh` is an internal helper. `cmd_site_pull` calls `pull_code`, `pull_content`, and `pull_db`. It is not a standalone command.

## Apache reload

Every reload runs `apache2ctl configtest` first. A failed configtest refuses the reload. heal, migrate, and platform-remove use this path. The gate also lives inside `andromeda-priv apache-reload`, so no caller can skip it.

## Privileged helpers

`andromeda-priv` is the only root helper. New verbs:

- `vhost-write PLATFORM HOST WEB ROOT ROLE` — writes one known-good vhost, runs configtest, enables the site only on success.
- `settings-write DEST DSN HOSTPAT ROLE` — writes `settings.local.php` in one atomic pass with trusted host and cache flag.

`ensure_vhost` and `ensure_local_php` call these first. The inline templates remain as a fallback.

## Backup format

`backup site` writes content as plain directories (`files/`, `private/`, `config-active/`) via rsync. Older tar snapshots are still restored. Database remains a Bee export.

## pull site

`pull site` prefers `git pull --ff-only` for the platform code. If the dest is not a checkout, it rsyncs the web tree excluding runtime directories. Content directories are rsynced directly. The database is a Bee export on the source, an rsync of the dump, and a Bee import on the dest. `settings.local.php` is overwritten in one pass.

## Aegir-aligned verbs

Andromeda is not bound to the Drupal stack. These verbs exist where the Aegir meaning still fits:

- `verify site|platform|all` — checks configuration, rebuilds vhosts (configtest gated), and enforces ownership on site directories. Safe, idempotent.
- `lock platform NAME` / `unlock platform NAME` — prevents (or allows) new site provisioning on a platform. A locked platform refuses `add site` / `install site`.
- `login-reset site PLATFORM PRODUCT` — asks Bee for a one-time admin login link when the installed Bee supports `user-login`/`uli`; otherwise points at the secret file.
- `install site` — alias of `add site`. The Backdrop install path remains the same.

Existing verbs already cover the rest of the Aegir set:

| Aegir     | Andromeda                          |
|-----------|------------------------------------|
| verify    | `verify` (new)                     |
| lock      | `lock platform` (new)              |
| unlock    | `unlock platform` (new)            |
| install   | `add site` / `install site`        |
| disable   | `disable site`                     |
| enable    | `enable site`                      |
| backup    | `backup site`                      |
| restore   | `restore site`                     |
| clone     | `clone site`                       |
| migrate   | `migrate site` (between platforms) / `migrate www` (from /var/www) |
| delete    | `delete site` / `remove platform`  |
| login-reset | `login-reset site` (new)         |

## migrate

Two commands. They do not overlap.

`migrate www` (and the hyphen form `migrate-www`) is the only command that reads `/var/www`. It lists standalone Backdrop docroots, asks for a new platform name, copies the tree into `/srv/platforms/<name>/web`, converts the hashed config store, and updates a chosen vhost. `migrate www heal` (or `migrate-www heal`) re-scans and repairs an already-migrated platform.

`migrate site SRC_PLATFORM SRC_PRODUCT DEST_PLATFORM DEST_PRODUCT` moves a site that already lives under `/srv/platforms` from one platform to another. Both platforms must already exist. It reuses the clone path (backup, add, restore) and then deletes the source site. Pass `--keep` to leave the source in place. It never touches `/var/www`.

```
andro migrate www
andro migrate-www
andro migrate site ecom kl_test ecom kl_devel
andro migrate site ecom kl_test otherplat kl_copy --keep
```

## pull and push

Both accept the same ref grammar.

Full form (canonical, works everywhere):

```
andro pull site @bjorn:ecom/keslerlumber.live to @knarr:ecom/keslerlumber.devel
andro push site @knarr:ecom/keslerlumber.test to @bjorn:ecom/keslerlumber.live
```

Short form (local only, both ends on this host):

```
andro push site ecom/keslerlumber.devel to ecom/keslerlumber.test
```

A bare `plat/site` means this host. Mixed forms are allowed.

`to` and `+` are both accepted between the two refs.

## hostname rule

The site directory name encodes the stage. Hostname is derived from it:

- `keslerlumber.devel` → hostname `keslerlumber.devel`
- `keslerlumber.test` → hostname `keslerlumber.test`
- `keslerlumber.live` → hostname `keslerlumber.com` (strip `.live`, append `.com`)

Override with `hostname NAME` or `--host NAME`:

```
andro push site @knarr:ecom/keslerlumber.test to @bjorn:ecom/keslerlumber.live hostname keslerlumber.net
```

`push` is the forward counterpart of `pull`: code, content, and database move. `promote` remains the git-only fast-forward on a target host.

## platform git and stage branches

The site directory suffix is the stage and the default git branch:

- `keslerlumber.devel` → branch `devel`
- `keslerlumber.test` → branch `test`
- `keslerlumber.live` → branch `live`

On the first local push between stages (for example `push site ecom/keslerlumber.devel to ecom/keslerlumber.test`), Andromeda creates the platform repo at `/srv/platforms/<plat>` if it does not exist, seeds the `devel`, `test`, and `live` branches, and checks out the destination stage. The same init runs on a local pull destination and on a remote push destination. `platform-add` also seeds the three branches when it creates a new platform.

## push prefers git for code

Local push between stages on the same platform (`push site ecom/keslerlumber.devel to ecom/keslerlumber.test`):

1. Commit any changes on the source stage branch (`devel`).
2. Check out the destination stage branch (`test`).
3. Merge the source stage into it.
4. Rsync site content (`files/`, `files_private/`, `config/`) and move the database with Bee. Those paths are gitignored.

Remote push (`push site @knarr:ecom/keslerlumber.test to @bjorn:ecom/keslerlumber.live`):

1. WireGuard comes up if either end is not local.
2. Commit on the source stage, push that branch over ssh to the destination platform repo, and merge it into the destination stage (`live`) on the far side.
3. If the git push fails, the web tree is rsynced as a fallback.
4. Content and database move by rsync and Bee, as on a pull.
5. Hostname for a `.live` site is `project.com` unless `hostname NAME` or `--host NAME` is given.

## Stage from the site name

On pull and push, the destination folder suffix is the stage unless `--role` is given:

- `keslerlumber.devel` → role and branch `devel`, hostname `keslerlumber.devel`
- `keslerlumber.test` → role and branch `test`, hostname `keslerlumber.test`
- `keslerlumber.live` → role and branch `live`, hostname `keslerlumber.com`

`hostname NAME` or `--host NAME` overrides the hostname. A failed `site-add` no longer aborts the pull; code, content, and the database still move. The web-tree rsync excludes `sites.php` so the destination host mapping survives.

## Tunnel addresses

SSH is only open on the WireGuard net. Named hosts resolve before ssh and rsync:

- `bjorn` → `10.8.0.1`
- `knarr` → `10.8.0.2`

Override in `/etc/andromeda.conf` with `TUNNEL_BJORN` and `TUNNEL_KNARR`.
