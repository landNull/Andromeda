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

## File movement

Code and versioned config move by Git (`platform-add`, `platform-upgrade`, `promote`, `pull site`). User content (`files/`, `files_private/`, database) moves by Bee and rsync. `settings.local.php` is written once, by a single template pass, never appended. `sites.php` mappings belong in the platform repo.

## pull site

`pull site` prefers `git pull --ff-only` for the platform code. If the dest is not a checkout, it rsyncs the web tree excluding runtime directories. Content directories are rsynced directly. The database is a Bee export on the source, an rsync of the dump, and a Bee import on the dest. `settings.local.php` is overwritten in one pass.
