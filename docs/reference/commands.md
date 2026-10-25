# Stardust command surface

Stardust accepts verb-first commands. Object-first forms remain as aliases.

## Preferred form

```
stardust pull site @bjorn:ecom/kl_test to @knarr:ecom/kl_devel
stardust add platform ecom
stardust add site ecom kl_devel
stardust heal site ecom kl_devel
stardust heal all
stardust list sites
stardust list platforms
stardust promote platform ecom to test
stardust backup site ecom kl_devel
stardust restore site ecom kl_devel
stardust clone site ecom kl_test ecom kl_devel
stardust debug site ecom kl_devel
stardust check site ecom kl_devel
stardust disable site ecom kl_devel
stardust enable site ecom kl_devel
stardust delete site ecom kl_devel
stardust remove platform ecom
stardust upgrade platform ecom
```

`to` is optional and ignored when present.

## Alias form

`stardust site pull`, `stardust platform add`, `stardust site-pull`, and the other hyphen forms still dispatch to the same functions.

## Why

Captain Rocket emits natural language. Verb-first matches how a human says the action, so Capcom has less to rewrite before the call.

## test

`stardust test <command> [args…]` runs a preflight before the real command.

If the command names a platform and product, `test` runs `site-debug`. Healable failures (missing dirs, settings, trusted host, ownership) are passed to `site-heal`. The check is repeated. If it still fails, the real command is refused. If it passes, the command runs.

If no site target is present, `test` runs `doctor` and refuses on failure.

```
stardust test pull site @bjorn:ecom/kl_test to @knarr:ecom/kl_devel
stardust test site-check ecom kl_devel
```

## Logging

Every mutating command writes two records:

- A one-line journal entry in `$STARDUST_ROOT/state/tasks.log` with UTC timestamp, host, role, user, command, return code, and the path of the run log.
- A per-run log in `$STARDUST_ROOT/state/logs/YYYY-MM-DDTHH-MM-SSZ-cmd.log` that captures stdout and stderr. `$STARDUST_ROOT/state/logs/latest.log` is a symlink to the most recent. Failures are also appended to `$STARDUST_ROOT/state/errors.log`.

`stardust log` shows the latest run log and the journal tail. `stardust last` prints the path of the latest run log.

## File movement

Code and versioned config move by Git (`platform-add`, `platform-upgrade`, `promote`, `pull site`). User content (`files/`, `files_private/`, database) moves by Bee and rsync. `settings.local.php` is written once, by a single template pass, never appended. `sites.php` mappings belong in the platform repo.

`lib/pull-rsync.sh` is an internal helper. `cmd_site_pull` calls `pull_code`, `pull_content`, and `pull_db`. It is not a standalone command.

## Apache reload

Every reload runs `apache2ctl configtest` first. A failed configtest refuses the reload. heal, migrate, and platform-remove use this path. The gate also lives inside `stardust-priv apache-reload`, so no caller can skip it.

## Privileged helpers

`stardust-priv` is the only root helper. New verbs:

- `vhost-write PLATFORM HOST WEB ROOT ROLE` — writes one known-good vhost, runs configtest, enables the site only on success.
- `settings-write DEST DSN HOSTPAT ROLE` — writes `settings.local.php` in one atomic pass with trusted host and cache flag.

`ensure_vhost` and `ensure_local_php` call these first. The inline templates remain as a fallback.

## Backup format

`backup site` writes content as plain directories (`files/`, `private/`, `config-active/`) via rsync. Older tar snapshots are still restored. Database remains a Bee export.

## pull site

`pull site` prefers `git pull --ff-only` for the platform code. If the dest is not a checkout, it rsyncs the web tree excluding runtime directories. Content directories are rsynced directly. The database is a Bee export on the source, an rsync of the dump, and a Bee import on the dest. `settings.local.php` is overwritten in one pass.
