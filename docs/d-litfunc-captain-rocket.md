# Captain Rocket as the Service Module

Captain Rocket is the Service Module. It attaches to an application by being present in the application's hidden `.captainrocket/` folder.

This page is an explanation. It says what Captain Rocket carries and how it attaches. It is the reference shape for the SM side of any application built with d-LitFunc.

## What the SM is

On Apollo the Command Module was the crew cabin. The Service Module was bolted to it and carried the power, propulsion, and communications the cabin did not have on its own. The crew flew the Command Module. The Service Module made the trip possible.

Captain Rocket is that attachment. The application is the Command Module. `.captainrocket/` is the Service Module. The two names are interchangeable: Service Module and SM.

## What the SM carries

| Capability | Where it lives | What the application gains |
|---|---|---|
| Phrase map | jetpack in `.captainrocket/jetpacks/` | Spoken verbs that resolve to the application's commands |
| Coordinator | Capcom | Local-first routing, approval gate, model cascade |
| Specialist | bittybot | One domain owned well, spoken back into the chat log |
| Contract caller | Capcom → `contrib/captainrocket/run-tool.sh` | JSON plus one `SPEAK:` line, no password prompt |
| Resume and ladder | Capcom | Skill scores for local models and contractors |
| Preflight | the application's `test` verb, called by the SM | Heal if safe, refuse if not |

The SM does not replace the application's verbs. It calls them.

## How the SM attaches

1. The application ships a contract directory (`contrib/captainrocket/` or the equivalent).
2. Captain Rocket is present when `.captainrocket/` exists at the application root.
3. Capcom loads the jetpack named for the application.
4. The bittybot for that domain owns the pack.
5. A spoken line is mapped, approved, and handed to the contract.
6. The contract returns machine lines and one spoken line. The bittybot speaks the result.

If `.captainrocket/` is absent, the application runs alone. The SM is optional. The contract is not.

## What the SM does not do

- It does not shell into the application.
- It does not own the application's data.
- It does not prompt for a password. Capcom mode refuses.
- It does not rewrite the application's verbs. It calls them.

## Why this is the standard

An application built with d-LitFunc is the Command Module. Captain Rocket is the Service Module. The application exposes a contract. The SM attaches by presence. The user runs the application. The SM supplies the coordinator, the specialist, and the spoken path.

See [Stardust](stardust.md) for the Command Module side of the same attachment.
