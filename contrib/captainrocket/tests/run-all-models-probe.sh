#!/bin/sh
# contrib/captainrocket/tests/run-all-models-probe.sh
# List every local Ollama model and run a short concurrency ramp against each.
# Safety:
#   - Check free RAM and load before each model
#   - Skip a model if free < 8 GB or load > 6
#   - Per-model ramp uses the same rules as run-concurrency-ramp.sh
#   - Hard timeout; kill leftovers
#   - Never raise concurrency above --max (default 2)
#
#   ./run-all-models-probe.sh
#   ./run-all-models-probe.sh --max 2 --dry-run
#   ./run-all-models-probe.sh --models granite-code:3b,smollm2:1.7b

set -eu

PROG=${0##*/}
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
ONLY=""
DRY=0
TIMEOUT=30
MAX=2
MIN_FREE_MB=8192
MAX_LOAD=6

usage() {
  cat << USAGE
Usage: $PROG [OPTIONS]

Options:
  --models A,B,...   Limit to these names (comma-separated). Default: all local.
  --endpoint URL     Ollama-compatible base URL
  --timeout SEC      Per-wave wall-clock timeout (default 30)
  --max N            Highest concurrency to try per model (default 2)
  --dry-run          Print the plan; do not call models
  -h, --help         This help

Lists local models, then for each one runs a ramp from 1 to --max.
Skips a model if the resource guard fails. Stops the whole probe
on the first hard failure inside a model.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --models) ONLY=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --max) MAX=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
  esac
done

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

# Launch in current shell so $! is waitable. Args: model out_file
launch_one() {
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

# List models from the Ollama API.
list_models() {
  curl -sS -m 10 "$ENDPOINT/api/tags" 2>/dev/null | python3 -c '
import json,sys
try:
  data=json.load(sys.stdin)
except Exception:
  sys.exit(0)
for m in data.get("models") or []:
  name=m.get("name") or ""
  if name:
    print(name)
' || true
}

printf '%s\n' 'Capcom all-models probe'
printf 'Endpoint: %s\n' "$ENDPOINT"
printf 'Timeout: %ss  max concurrency per model: %s\n' "$TIMEOUT" "$MAX"
printf '%s\n' '===='

if [ -n "$ONLY" ]; then
  models=$(printf '%s' "$ONLY" | tr ',' ' ')
else
  models=$(list_models)
fi

if [ -z "$models" ]; then
  printf '%s\n' 'No models found.'
  exit 0
fi

printf 'Models:\n'
for m in $models; do
  printf '  %s\n' "$m"
done

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' 'DRY-RUN: would ramp each model from 1 to max, checking resources before each wave.'
  printf '%s\n' 'No model calls made.'
  exit 0
fi

for MODEL in $models; do
  printf '\n==== MODEL %s ====\n' "$MODEL"
  if ! resource_ok; then
    printf 'Skipping %s: resource guard failed before start\n' "$MODEL"
    continue
  fi

  highest=0
  n=1
  hard_fail=0
  while [ "$n" -le "$MAX" ]; do
    printf '\n---- %s concurrency=%s ----\n' "$MODEL" "$n"
    if ! resource_ok; then
      printf 'Stopping %s: resource guard failed before wave %s\n' "$MODEL" "$n"
      break
    fi

    i=1
    pids=""
    outs=""
    while [ "$i" -le "$n" ]; do
      out=$(mktemp)
      launch_one "$MODEL" "$out"
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

    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        failed=1
      else
        wait "$pid" 2>/dev/null || failed=1
      fi
    done
    for out in $outs; do
      rm -f "$out"
    done

    if [ "$failed" -ne 0 ]; then
      printf 'FAIL %s concurrency=%s (timeout or error)\n' "$MODEL" "$n"
      hard_fail=1
      break
    fi

    printf 'OK %s concurrency=%s\n' "$MODEL" "$n"
    highest=$n
    n=$((n + 1))
  done

  if [ "$highest" -eq 0 ]; then
    printf 'RESULT %s: no successful wave\n' "$MODEL"
  else
    printf 'RESULT %s: highest successful concurrency %s\n' "$MODEL" "$highest"
  fi

  if [ "$hard_fail" -eq 1 ]; then
    printf '%s\n' 'Hard failure on this model; stopping probe.'
    break
  fi
done

printf '\n---- FINAL ----\n'
resource_ok || true
printf '%s\n' 'All-models probe complete.'
