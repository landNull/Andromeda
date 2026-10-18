#!/bin/sh
# contrib/captainrocket/run-tool.sh — one entry for Capcom.
# Resolves a module name or a spoken phrase, then runs the Stardust
# test runner with --json --speak. Prints JSON lines and one SPEAK: line.
#
#   ./contrib/captainrocket/run-tool.sh daily
#   ./contrib/captainrocket/run-tool.sh "run the daily tests"
#
# Exit: 0 pass, 1 fail, 2 usage or unknown phrase.
# Do not run this under sudo.

set -eu

PROG=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
INTENTS="$HERE/intents.txt"
RUNNER="$REPO/tests/run-test.sh"

if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
  printf 'SPEAK: Refusing to run as root. Log in as the operator.\n'
  exit 2
fi

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  printf 'SPEAK: Say a module or a phrase. For example, run the daily tests.\n'
  printf '%s\n' '{"module":"usage","status":"fail","what":"missing argument"}'
  exit 2
fi

phrase=$1
key=$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')

flags=""
if [ -f "$INTENTS" ]; then
  flags=$(awk -F ': ' -v k="$key" '
    $0 ~ /^#/ { next }
    NF < 2 { next }
    {
      name=$1
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      if (tolower(name) == k) { print $2; exit }
    }
  ' "$INTENTS")
fi

if [ -z "$flags" ]; then
  case "$key" in
    daily|webadmin) flags="--json --speak -n daily" ;;
    all|everything) flags="--json --speak --all" ;;
    diagnose|stack|host) flags="--json --speak --diagnose" ;;
    platform) flags="--json --speak -n platform" ;;
    site) flags="--json --speak -n site" ;;
    security) flags="--json --speak -n security" ;;
    lint) flags="--json --speak --lint" ;;
    heal) flags="--json --speak --heal" ;;
    *)
      printf 'SPEAK: No Stardust tool matches that phrase.\n'
      printf '%s\n' '{"module":"usage","status":"fail","what":"unknown phrase"}'
      exit 2
      ;;
  esac
fi

if [ ! -x "$RUNNER" ]; then
  printf 'SPEAK: The Stardust test runner is missing.\n'
  printf '%s\n' '{"module":"runner","status":"fail","what":"tests/run-test.sh not executable"}'
  exit 1
fi

# Filter to JSON lines and the SPEAK line so Capcom does not see the human log.
# Capture the runner exit, not awk's.
cd "$REPO"
tmp=$(mktemp)
set +e
# shellcheck disable=SC2086
"$RUNNER" $flags >"$tmp" 2>&1
status=$?
set -e
awk '/^\{/ || /^SPEAK:/' "$tmp"
rm -f "$tmp"
exit "$status"
