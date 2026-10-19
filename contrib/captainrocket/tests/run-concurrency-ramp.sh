#!/bin/sh
# contrib/captainrocket/tests/run-concurrency-ramp.sh
# Ramp concurrent requests against one model until a guard fails.
# Safety:
#   - Check free RAM and load before every wave
#   - Abort the wave (and the probe) if free < 8 GB or load > 6
#   - Hard wall-clock timeout per wave
#   - Kill leftovers immediately
#   - Never continue past the first failure
#
#   ./run-concurrency-ramp.sh --model granite-code:3b
#   ./run-concurrency-ramp.sh --model granite4.1:8b --max 4 --dry-run

set -eu

PROG=${0##*/}
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
MODEL=""
DRY=0
TIMEOUT=30
MAX=4
MIN_FREE_MB=8192
MAX_LOAD=6

usage() {
  cat << USAGE
Usage: $PROG [OPTIONS]

Options:
  --model NAME       Model to probe (required unless --dry-run)
  --endpoint URL     Ollama-compatible base URL
  --timeout SEC      Per-wave wall-clock timeout (default 30)
  --max N            Highest concurrency to try (default 4)
  --dry-run          Print the plan; do not call models
  -h, --help         This help

Starts at concurrency 1 and increases by 1. Stops at the first
resource guard trip, timeout, or request error. Reports the
highest concurrency that fully succeeded.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --max) MAX=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
  esac
done

[ -n "$MODEL" ] || [ "$DRY" -eq 1 ] || { printf '%s: --model required\n' "$PROG" >&2; exit 2; }

free_mb() {
  free -m 2>/dev/null | awk '/^Mem:/ { print $7; exit }' || echo 0
}

load_1() {
  awk '{ print $1 }' /proc/loadavg 2>/dev/null || echo 0
}

resource_ok() {
  free=$(free_mb)
  load=$(load_1)
  load_int=$(printf '%s' "$load" | cut -d. -f1)
  [ -z "$load_int" ] && load_int=0
  if [ "$free" -lt "$MIN_FREE_MB" ]; then
    printf 'GUARD: free RAM %s MB < %s MB\n' "$free" "$MIN_FREE_MB"
    return 1
  fi
  if [ "$load_int" -gt "$MAX_LOAD" ]; then
    printf 'GUARD: load %s > %s\n' "$load" "$MAX_LOAD"
    return 1
  fi
  printf 'OK resources: free=%s MB load=%s\n' "$free" "$load"
  return 0
}

tiny_prompt() {
  printf '%s' 'Reply with the single word OK.'
}

# Launch in current shell so $! is waitable. Args: out_file
launch_one() {
  out=$1
  body=$(printf '%s' "$(tiny_prompt)" | python3 -c '
import json,sys
p=sys.stdin.read()
print(json.dumps({"model":sys.argv[1],"prompt":p,"stream":False}))
' "$MODEL")
  curl -sS -m "$TIMEOUT" -H 'Content-Type: application/json' \
    -d "$body" "$ENDPOINT/api/generate" > "$out" 2>&1 &
  LAST_PID=$!
}

cleanup() {
  jobs -p 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

printf '%s\n' 'Capcom concurrency ramp'
printf 'Model: %s\n' "$MODEL"
printf 'Endpoint: %s\n' "$ENDPOINT"
printf 'Timeout: %ss  max concurrency: %s\n' "$TIMEOUT" "$MAX"
printf '%s\n' '===='

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' 'DRY-RUN: would ramp concurrency from 1 to max, checking resources before each wave.'
  printf '%s\n' 'No model calls made.'
  exit 0
fi

highest=0
n=1
while [ "$n" -le "$MAX" ]; do
  printf '\n---- WAVE concurrency=%s ----\n' "$n"
  if ! resource_ok; then
    printf 'Stopping: resource guard failed before wave %s\n' "$n"
    break
  fi

  # Launch n requests
  i=1
  pids=""
  outs=""
  while [ "$i" -le "$n" ]; do
    out=$(mktemp)
    launch_one "$out"
    pids="$pids $LAST_PID"
    outs="$outs $out"
    i=$((i + 1))
  done
  printf 'launched %s pids:%s\n' "$n" "$pids"

  deadline=$(( $(date +%s) + TIMEOUT + 5 ))
  failed=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    still=0
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        still=1
      fi
    done
    [ "$still" -eq 0 ] && break
    sleep 1
  done

  # Collect results
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      failed=1
    else
      wait "$pid" 2>/dev/null || failed=1
    fi
  done
  # Cleanup temps
  for out in $outs; do
    rm -f "$out"
  done

  if [ "$failed" -ne 0 ]; then
    printf 'FAIL concurrency=%s (timeout or error)\n' "$n"
    printf '%s\n' 'Highest successful concurrency reported below.'
    break
  fi

  printf 'OK concurrency=%s\n' "$n"
  highest=$n
  n=$((n + 1))
done

printf '\n---- RESULT ----\n'
if [ "$highest" -eq 0 ]; then
  printf 'No successful wave.\n'
else
  printf 'Highest successful concurrency: %s\n' "$highest"
fi
resource_ok || true
printf '%s\n' 'Ramp complete.'
