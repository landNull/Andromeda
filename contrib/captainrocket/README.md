# Stardust as a CaptainRocket tool

Capcom calls Stardust. Stardust does not call Capcom.

This directory is the contract. The hidden `.captainrocket/` at the repo root is Capcom's runtime state (log, state.db) and is gitignored.

## What Capcom can ask

| Phrase | Command |
|---|---|
| run the daily tests | `./tests/run-test.sh --json --speak -n daily` |
| run all the tests | `./tests/run-test.sh --json --speak --all` |
| diagnose the stack | `./tests/run-test.sh --json --speak --diagnose` |
| check the platform | `./tests/run-test.sh --json --speak -n platform` |
| check the site | `./tests/run-test.sh --json --speak -n site` |
| check security | `./tests/run-test.sh --json --speak -n security` |

Or pass the phrase through:

```sh
./tests/run-test.sh --json --speak --intent "run the daily tests"
```

## What Capcom reads

- Lines starting with `{` are JSON. One object per module, plus a summary.
- One line starting with `SPEAK:` is the spoken result.
- Exit `0` pass, `1` fail, `2` bad usage.

## What Capcom must not do

- Do not run `sudo stardust` or `sudo ./tests/run-test.sh`.
- Do not answer the interactive prompts. `--json` and `--speak` skip them.
- Do not treat `.captainrocket/state.db` as part of this contract.
