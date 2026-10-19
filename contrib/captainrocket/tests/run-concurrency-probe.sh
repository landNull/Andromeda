#!/bin/sh
# contrib/captainrocket/tests/run-concurrency-probe.sh
# Probe whether the host can run more than one model request at once
# without approaching CPU or RAM limits.
#
# Safe by design:
#   - Refuses to start if free RAM < 8 GB or load average > 6
#   - Uses a 30-second wall-clock timeout per wave
#   - Never launches more than 2 concurrent requests
#   - Kills background curls on timeout or on exit
#   - Reports SKIP / OK / FAIL; never aborts the machine
#
#   ./run-concurrency-probe.sh --model granite-code:3b
#   ./run-concurrency-probe.sh --model smollm2:1.7b --endpoint http://127.0.0.1:11434
#   ./run-concurrency-probe.sh --dry-run

set -eu

PROG=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

MODEL=""
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
DRY=0
TIMEOUT=30
MIN_FREE_MB=8192
MAX_LOAD=6

usage() {
  cat << USAGE
Usage: $PROG [OPTIONS]

Options:
  --model NAME       Model name (required unless --dry-run)
  --endpoint URL     Ollama-compatible base URL
  --timeout SEC      Wall-clock timeout per wave (default 30)
  --dry-run          Print the plan; do not call the model
  -h, --help         This help

The probe never launches more than 2 concurrent requests and aborts a wave
if free RAM drops below ${MIN_FREE_MB} MB or load exceeds ${MAX_LOAD}.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
  esac
done

[ -n "$MODEL" ] || [ "$DRY" -eq 1 ] || { printf '%s: --model required\n' "$PROG" >&2; exit 2; }

free_mb() {
  # Linux free -m; fall back to 0 if unavailable.
  free -m 2>/dev/null | awk '/^Mem:/ { print $7; exit }' || echo 0
}

load_1() {
  awk '{ print $1 }' /proc/loadavg 2>/dev/null || echo 0
}

resource_ok() {
  free=$(free_mb)
  load=$(load_1)
  # integer compare for load (truncate)
  load_int=$(printf '%s' "$load" | cut -d. -f1)
  [ -z "$load_int" ] && load_int=0
  if [ "$free" -lt "$MIN_FREE_MB" ]; then
    printf 'SKIP: free RAM %s MB < %s MB\n' "$free" "$MIN_FREE_MB"
    return 1
  fi
  if [ "$load_int" -gt "$MAX_LOAD" ]; then
    printf 'SKIP: load %s > %s\n' "$load" "$MAX_LOAD"
    return 1
  fi
  printf 'OK resources: free=%s MB load=%s\n' "$free" "$load"
  return 0
}

tiny_prompt() {
  printf '%s' 'Reply with the single word OK.'
}

# Launch curl in the current shell so $! is waitable.
# Do not wrap this in $(...) or the background job dies with the subshell.
launch_curl() {
  # $1 out file
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
  # kill any leftover curls from this run
  jobs -p 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

printf '%s\n' 'Capcom concurrency probe'
printf 'Model: %s\n' "${MODEL:-dry-run}"
printf 'Endpoint: %s\n' "$ENDPOINT"
printf 'Timeout: %ss  max concurrent: 2\n' "$TIMEOUT"
printf '%s\n' '===='

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' 'DRY-RUN: would send 1 sequential then 2 concurrent tiny prompts.'
  printf '%s\n' 'Resource guard would be checked before each wave.'
  printf '%s\n' 'No model calls made.'
  exit 0
fi

if ! resource_ok; then
  printf '%s\n' 'Probe aborted before any request (resource guard).'
  exit 0
fi

# Wave 1: sequential baseline
printf '\n---- WAVE 1: sequential ----\n'
out1=$(mktemp)
launch_curl "$out1"
pid1=$LAST_PID
if wait "$pid1" 2>/dev/null; then
  printf 'OK sequential (pid %s)\n' "$pid1"
else
  printf 'FAIL sequential (pid %s)\n' "$pid1"
  printf '%s\n' '--- curl output ---'
  cat "$out1" 2>/dev/null || true
  printf '%s\n' '--- end ---'
  rm -f "$out1"
  exit 0
fi
rm -f "$out1"

# Re-check before concurrent
if ! resource_ok; then
  printf '%s\n' 'Skipping concurrent wave (resource guard).'
  exit 0
fi

# Wave 2: two concurrent
printf '\n---- WAVE 2: 2 concurrent ----\n'
outa=$(mktemp)
outb=$(mktemp)
launch_curl "$outa"
pida=$LAST_PID
launch_curl "$outb"
pidb=$LAST_PID
printf 'launched pids %s %s\n' "$pida" "$pidb"

# Wait with a hard wall clock
deadline=$(( $(date +%s) + TIMEOUT + 5 ))
ok_a=0
ok_b=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$ok_a" -eq 0 ] && ! kill -0 "$pida" 2>/dev/null; then
    wait "$pida" 2>/dev/null && ok_a=1 || ok_a=2
  fi
  if [ "$ok_b" -eq 0 ] && ! kill -0 "$pidb" 2>/dev/null; then
    wait "$pidb" 2>/dev/null && ok_b=1 || ok_b=2
  fi
  [ "$ok_a" -ne 0 ] && [ "$ok_b" -ne 0 ] && break
  sleep 1
done

# Force-kill if still running
kill "$pida" "$pidb" 2>/dev/null || true
wait "$pida" "$pidb" 2>/dev/null || true

if [ "$ok_a" -eq 1 ] && [ "$ok_b" -eq 1 ]; then
  printf 'OK concurrent: both requests finished within timeout\n'
else
  printf 'FAIL concurrent: a=%s b=%s (1=ok 2=error 0=timeout)\n' "$ok_a" "$ok_b"
  printf '%s\n' 'Hardware or model server did not complete 2 concurrent requests in time.'
  printf '%s\n' 'This is a graceful failure; no further waves will be attempted.'
fi

rm -f "$outa" "$outb"

# Final resource snapshot
printf '\n---- FINAL ----\n'
resource_ok || true
printf '%s\n' 'Probe complete.'
