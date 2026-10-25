# Andromeda command surface

Andromeda accepts verb-first commands. Object-first forms remain as aliases.

## Preferred form

```
andromeda pull site @bjorn:ecom/kl_test to @knarr:ecom/kl_devel
andromeda add platform ecom
andromeda add site ecom kl_devel
andromeda heal site ecom kl_devel
andromeda heal all
andromeda list sites
andromeda list platforms
andromeda promote platform ecom to test
andromeda backup site ecom kl_devel
andromeda restore site ecom kl_devel
andromeda clone site ecom kl_test ecom kl_devel
andromeda debug site ecom kl_devel
andromeda check site ecom kl_devel
andromeda disable site ecom kl_devel
andromeda enable site ecom kl_devel
andromeda delete site ecom kl_devel
andromeda remove platform ecom
andromeda upgrade platform ecom
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
andromeda test pull site @bjorn:ecom/kl_test to @knarr:ecom/kl_devel
andromeda test site-check ecom kl_devel
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
