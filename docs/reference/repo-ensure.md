# repo-ensure

`andro repo-ensure NAME` creates the bare at `/srv/git/NAME.git` and the checkout at `/srv/platforms/NAME`. It seeds one empty commit, then the `devel`, `test`, and `live` branches, and writes `/srv/andromeda/state/platforms/NAME.json`. An empty clone has no commit, so a branch created before the seed is unborn and is not a ref.

`andro add platform` calls it when no remote is given. `andro pull site` calls it before the code move.

## Ownership

The bare and the checkout are owned by the code owner from the first command. The operator never owns them.

| Step | Runs as | Door |
|---|---|---|
| Create `/srv/git` | root | `andromeda-priv mkdir` |
| Hand `/srv/git` to the code owner | root | `andromeda-priv chown-code` |
| `git init --bare` | code owner | `%www-admin ALL=(deploy) NOPASSWD: /usr/bin/git` |
| `git clone` | code owner | same |
| Stage branches | code owner | same |

The sudoers line lives in `/etc/sudoers.d/andromeda-deploy`. When it is missing, the function names the file and the line, then returns. It does not ask for a password.

## Why the clone runs as the owner

An earlier form created the bare as the operator, handed it to the code owner, then cloned it as the operator. Git refused the clone: the repo was owned by a different user. `set -eu` in the wrapper then stopped the whole pull. Creating and cloning as the owner does not open that window.

See also [WireGuard NOPASSWD](wg-nopasswd.md).
