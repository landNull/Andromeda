# Stardust and the Service Module

Stardust is the Command Module. The Service Module is Captain Rocket present in the hidden `.captainrocket/` folder at the repo root.

This page is an explanation. It says how the SM works inside Stardust. It is the reference shape for any application built with d-LitFunc.

## The two folders

| Path | What it is | Committed |
|---|---|---|
| `.captainrocket/` | The SM. Capcom's runtime state: log, state, jetpack cache. | No. Gitignored. |
| `contrib/captainrocket/` | The contract. The entry Capcom calls, the phrase map, the tool list. | Yes. |

The SM is discovered by presence. If `.captainrocket/` exists, Captain Rocket is attached. If it does not, Stardust runs alone.

The contract is the stable surface. Capcom never shells into Stardust. It calls `contrib/captainrocket/run-tool.sh`, sets `STARDUST_SPEAK=1` and `STARDUST_JSON=1`, and reads JSON lines plus one `SPEAK:` line.

## What the SM carries for Stardust

The jetpack at `.captainrocket/jetpacks/stardust.json` (loaded by Capcom) maps spoken phrases to Stardust verbs:

- `site check` → `stardust site-check`
- `site heal` → `stardust site-heal`
- `heal all` → `stardust heal all`
- `pull site` → `stardust pull site`
- `test command` → `stardust test`
- `stardust doctor` → `stardust doctor`

The contract in `contrib/captainrocket/` resolves the same phrases for the test runner and the preflight:

| Phrase | Resolves to |
|---|---|
| `run the daily tests` | `tests/run-test.sh --json --speak -n daily` |
| `preflight a command` | `stardust test …` |
| `heal all sites` | `stardust heal all` |
| `show the last log` | `stardust last` |

## How a call moves

1. The user speaks to Captain Rocket.
2. Capcom loads the Stardust jetpack.
3. The Stardust bittybot owns the pack. It does not reason. It maps the phrase and calls `run-tool.sh`.
4. `run-tool.sh` sets Capcom mode. Stardust never prompts for a password.
5. Stardust runs the verb. If the verb is `test`, it preflights, heals if safe, and refuses if still failing.
6. The result returns as JSON plus one `SPEAK:` line. The bittybot speaks it into the chat log as `★ Stardust:`.

Capcom stays the coordinator. The bittybot stays the specialist. Stardust stays the platform tool.

## What Capcom must not do

- Do not run `sudo stardust`.
- Do not answer interactive prompts. Capcom mode skips them.
- Do not treat `.captainrocket/state.db` as part of the contract.

## Why this is the standard

An application built with d-LitFunc does not embed Captain Rocket. It exposes a contract in a committed directory and accepts an SM in a hidden folder. The application runs alone when the SM is absent. When the SM is present, the application gains the coordinator, the bittybot, and the spoken path without changing its own verbs.

See [Captain Rocket](captain-rocket.md) for the other side of the attachment.
