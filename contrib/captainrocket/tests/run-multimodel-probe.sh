#!/bin/sh
# contrib/captainrocket/tests/run-multimodel-probe.sh
# Launch concurrent tiny prompts against different models at the same time.
# Same safety rules as run-concurrency-probe.sh:
#   - Refuse if free RAM < 8 GB or load > 6
#   - Hard 30s wall-clock timeout
#   - Kill leftovers on timeout or exit
#   - Never more than 2 concurrent requests
#
#   ./run-multimodel-probe.sh --models granite-code:3b,granite4.1:8b
#   ./run-multimodel-probe.sh --models smollm2:1.7b,starcoder2:3b --dry-run

set -eu

PROG=${0##*/}
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
MODELS=""
DRY=0
TIMEOUT=30
MIN_FREE_MB=8192
MAX_LOAD=6

usage() {
  cat << USAGE
Usage: $PROG [OPTIONS]

Options:
  --models A,B       Two model names, comma-separated (required unless --dry-run)
  --endpoint URL     Ollama-compatible base URL
  --timeout SEC      Wall-clock timeout (default 30)
  --dry-run          Print the plan; do not call models
  -h, --help         This help

Launches exactly one request per model, in parallel. Stops if resources
are low or either request fails or times out.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --models) MODELS=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
  esac
done

[ -n "$MODELS" ] || [ "$DRY" -eq 1 ] || { printf '%s: --models required\n' "$PROG" >&2; exit 2; }

# Split on comma into MODEL_A MODEL_B
MODEL_A=${MODELS%%,*}
MODEL_B=${MODELS#*,}
if [ -z "$MODEL_A" ] || [ -z "$MODEL_B" ] || [ "$MODEL_A" = "$MODEL_B" ]; then
  printf '%s: need two different models as A,B\n' "$PROG" >&2
  exit 2
fi

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

# Launch in current shell so $! is waitable.
launch_curl() {
  # $1 model  $2 out file
  model=$1
  out=$2
  body=$(printf '%s' "$(tiny_prompt)" | python3 -c '
import json,sys
p=sys.stdin.read()
print(json.dumps({"model":sys.argv[1],"prompt":p,"stream":False}))
' "$model")
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

printf '%s\n' 'Capcom multi-model probe'
printf 'Models: %s and %s\n' "$MODEL_A" "$MODEL_B"
printf 'Endpoint: %s\n' "$ENDPOINT"
printf 'Timeout: %ss  concurrent: 2\n' "$TIMEOUT"
printf '%s\n' '===='

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' 'DRY-RUN: would send one tiny prompt to each model in parallel.'
  printf '%s\n' 'Resource guard would be checked first.'
  printf '%s\n' 'No model calls made.'
  exit 0
fi

if ! resource_ok; then
  printf '%s\n' 'Probe aborted before any request (resource guard).'
  exit 0
fi

printf '\n---- WAVE: %s + %s concurrent ----\n' "$MODEL_A" "$MODEL_B"
outa=$(mktemp)
outb=$(mktemp)
launch_curl "$MODEL_A" "$outa"
pida=$LAST_PID
launch_curl "$MODEL_B" "$outb"
pidb=$LAST_PID
printf 'launched %s (pid %s) and %s (pid %s)\n' "$MODEL_A" "$pida" "$MODEL_B" "$pidb"

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

kill "$pida" "$pidb" 2>/dev/null || true
wait "$pida" "$pidb" 2>/dev/null || true

if [ "$ok_a" -eq 1 ] && [ "$ok_b" -eq 1 ]; then
  printf 'OK concurrent: both models finished within timeout\n'
else
  printf 'FAIL concurrent: %s=%s %s=%s (1=ok 2=error 0=timeout)\n' \
    "$MODEL_A" "$ok_a" "$MODEL_B" "$ok_b"
  printf '%s\n' '--- output A ---'
  cat "$outa" 2>/dev/null || true
  printf '%s\n' '--- output B ---'
  cat "$outb" 2>/dev/null || true
  printf '%s\n' '--- end ---'
  printf '%s\n' 'Hardware or model server did not complete both models in time.'
  printf '%s\n' 'This is a graceful failure.'
fi

rm -f "$outa" "$outb"

printf '\n---- FINAL ----\n'
resource_ok || true
printf '%s\n' 'Probe complete.'
