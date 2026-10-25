# Stardust docs outline

## Install and day-to-day

- `tutorial.txt` — install the host, then day-to-day CLI
- `d7-migration.txt` — Drupal 7 / BOA → Backdrop
- `README.txt` — map of this folder

## Reference

- `reference/commands.md` — command reference
- `reference/wg-nopasswd.md` — WireGuard NOPASSWD

## Architecture and milestones

- `AppCentricArchitecture.md` — application-centric layout
- `StardustMilestones.md` — milestones

## Standard

d-LitFunc is the documentation and build standard. The SM pattern is the standard for attaching Captain Rocket.

- `d-litfunc.md` — the standard
- `d-litfunc-stardust.md` — how the SM works inside Stardust
- `d-litfunc-captain-rocket.md` — Captain Rocket as the SM

The application is the Command Module. Captain Rocket is the Service Module when `.captainrocket/` is present. The contract is `contrib/captainrocket/`.
