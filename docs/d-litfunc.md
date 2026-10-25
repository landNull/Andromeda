# d-LitFunc

d-LitFunc is the build and documentation standard for applications in this set.

It has two halves. The first half is how a document is written. The second half is how an application is built. Both halves exist so the finished system is smaller, faster, safer, and easier to explain than a system written from scratch.

## What d-LitFunc currently is

d-LitFunc is three words joined by a hyphen.

**Diátaxis.** Every document is one of four kinds and nothing else.

| Kind | Question it answers | Shape |
|---|---|---|
| Tutorial | How do I learn this? | Linear, from a bare terminal to a first success |
| How-to | How do I do this one task? | Recipe, assumes the reader already knows the system |
| Reference | What is the exact contract? | Dry, complete, no teaching |
| Explanation | Why is it this way? | Context, trade-offs, boundaries |

A document does not mix kinds. A how-to does not teach. A reference does not argue. An explanation does not list flags.

**Literal.** Names and documents say exactly what the code does. A function named `pull_code` pulls code. A command named `stardust site-heal` heals a site. A document titled `flight-director-capcom-boundary` describes that boundary and nothing else. There is no metaphor in a name.

**Functional.** The core is pure. A function takes values and returns values. It does not open sockets, write files, or prompt. The shell around the core does the side effects. Comments explain why, or a non-obvious contract. They do not restate the next line.

That is the documentation half. It is already in use. Captain Rocket docs are split into `tutorials/`, `how-to/`, `reference/`, and `explanation/`. Stardust docs follow the same split. Comments in both codebases follow the same rule.

## How an application is built

The build half is the process that produced Stardust, Captain Rocket, and the helpers between them. It has three stages. Do not skip one.

### 1. Prototype the functionality

Write the smallest thing that does the job. Do not design the final architecture first. Do not pick the tools first. Get a working path from input to result.

Examples from this set:

- Site pull was first a shell sequence that copied a site from a VPS and stood it up as a devel site. The sequence worked before it was a module.
- Site heal was first a list of the common Backdrop failures and a script that fixed the safe ones.
- Capcom was first a coordinator that preferred a local tool over a model call.

The prototype is allowed to be rough. It is not allowed to be abstract. If it does not run, it is not a prototype.

### 2. Research existing tools

Once the prototype works, look for tools that already do parts of the job. Prefer a tool that reduces friction, reduces errors, improves security, or improves speed. Prefer an existing standard over a new one.

Tools that were adopted after the prototypes worked:

| Need | Tool adopted | Why |
|---|---|---|
| Move versioned code | Git (`git pull --ff-only`) | Fast, verifiable, no custom copy logic |
| Move user content | rsync | Incremental, preserves permissions, standard |
| Backdrop site commands | Bee | Official CLI, already knows the site layout |
| Remote access behind CGNAT | WireGuard | On-demand, kernel-level, no open ports |
| Privilege boundary | sudoers + a small priv helper | NOPASSWD for named verbs only, never a root shell |
| Documentation shape | Diátaxis | Existing standard, four kinds, no invention |

A tool is adopted only when it does the job better than the prototype and does not force a rewrite of the parts that already work. If a tool requires systemd and the host is SysVinit, the tool is not adopted.

### 3. Build a helper only for a gap

When no existing tool covers a step, write a helper. The helper is small. It does one job. It is baked into the application, not shipped as a separate product the user has to install and wire.

A helper exists to fill a gap and to make the standalone tools work together. It does not replace them.

Helpers in this set:

| Helper | Gap it fills | Tools it joins |
|---|---|---|
| `stardust-priv` | Named privilege verbs without a root shell | sudo, Apache, file ownership |
| `lib/pull-rsync.sh` | One pull that moves code, content, and database | Git, rsync, Bee |
| `migrate-www` | Convert a `/var/www` docroot into the platform layout | Apache vhost, Bee, settings |
| `lib/test.sh` | Preflight a command, heal if safe, refuse if not | site-debug, site-heal |
| `contrib/captainrocket/run-tool.sh` | One entry Capcom can call | test runner, stardust verbs, SPEAK lines |
| Stardust bittybot | Capcom-facing specialist that owns the pack | Capcom, jetpack, run-tool.sh |

Each helper is called by the application. The user does not run the helper by hand unless they are debugging it.

## Applications

This standard is in use. Each application is the Command Module. Captain Rocket is the Service Module (SM) when it is present in the application's hidden `.captainrocket/` folder.

- [Stardust](stardust.md) — how the SM works inside Stardust. The Command Module side.
- [Captain Rocket](captain-rocket.md) — how Captain Rocket attaches as the SM. The Service Module side.

The SM pattern is the standard for application development with d-LitFunc. An application exposes a committed contract. It accepts an SM in a hidden folder. It runs alone when the SM is absent. When the SM is present it gains the coordinator, the bittybot, and the spoken path without changing its own verbs.

## The synergistic whole

The finished application is the prototype path, with existing tools in the places they fit, and helpers in the gaps. The helpers are what make the standalone tools into one system.

A site pull is not "rsync plus Bee plus Git." It is `stardust pull site @host:plat/site to @host:plat/site`. Inside that command:

1. WireGuard comes up if it is not already up, and is torn down only if this process started it.
2. Code moves by `git pull --ff-only`, with an rsync of the web tree only if Git cannot.
3. User content moves by rsync.
4. The database moves by Bee export, rsync, and Bee import.
5. `settings.local.php` is written once, atomically.
6. The run is logged to a timestamped file.

None of those tools know about the others. The helper knows the order and the failure points. That is the synergy.

The same pattern holds for Captain Rocket. Capcom does not shell into Stardust. It loads a jetpack, calls `run-tool.sh`, and reads JSON plus one `SPEAK:` line. The bittybot is the helper that sits between Capcom and the Stardust verbs. Capcom stays the coordinator. The bittybot stays the specialist. Stardust stays the platform tool.

## Rules

1. Prototype first. Do not design the final shape before something runs.
2. Adopt an existing tool when it reduces friction, errors, or attack surface, or when it is faster. Do not adopt a tool that forces a rewrite of working parts.
3. Write a helper only for a gap. Name it for the gap it fills.
4. Bake the helper in. The user runs the application, not the helper.
5. Document the result in one Diátaxis kind. Name the document for what it describes.
6. Keep the core pure. Put side effects in the shell.
7. Comments explain why or a contract. They do not narrate the next line.

## What this document is

This document is an explanation. It says why d-LitFunc is two halves and how the build half produced the current applications. It is not a tutorial and not a reference. The reference for a specific command lives next to that command. The how-to for a specific task lives in that task's how-to.
