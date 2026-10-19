#!/bin/sh
# contrib/captainrocket/tests/run-skill-probe.sh
# Gauge what each local Ollama model is skilled at.
# Runs a fixed set of short tasks and records pass/fail + latency.
#
# Tasks:
#   code      — completion-style (raw for starcoder*)
#   instruct  — simple instruction following
#   reason    — short multi-step reasoning
#   format    — structured output (JSON-like)
#
#   ./run-skill-probe.sh
#   ./run-skill-probe.sh --models granite-code:3b,smollm2:1.7b
#   ./run-skill-probe.sh --dry-run

set -eu

PROG=${0##*/}
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
ONLY=""
DRY=0
TIMEOUT=90
OUTDIR=""

usage() {
  cat << USAGE
Usage: $PROG [OPTIONS]

Options:
  --models A,B,...   Limit to these names. Default: all local.
  --endpoint URL     Ollama-compatible base URL
  --timeout SEC      Per-request timeout (default 90)
  --outdir DIR       Write JSON results here (default /tmp/skill-probe-*)
  --dry-run          Print plan; do not call models
  -h, --help         This help

Runs four short tasks against each model and prints a score table.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --models) ONLY=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --outdir) OUTDIR=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
  esac
done

if [ -z "$OUTDIR" ]; then
  OUTDIR=$(mktemp -d /tmp/skill-probe-XXXXXX)
fi
mkdir -p "$OUTDIR"

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

# Return 0 if the model name looks like a pure completion model.
is_completion() {
  case "$1" in
    starcoder*|codellama*|deepseek-coder*) return 0 ;;
    *) return 1 ;;
  esac
}

# Call generate. Args: model prompt raw(0|1) num_predict
# Prints response text or empty on failure. Sets CALL_MS.
call_generate() {
  model=$1
  prompt=$2
  raw=$3
  npred=$4
  start=$(date +%s%N)
  body=$(python3 -c '
import json,sys
model,prompt,raw,npred=sys.argv[1:]
d={"model":model,"prompt":prompt,"stream":False,
   "options":{"num_predict":int(npred),"temperature":0.1}}
if raw=="1":
  d["raw"]=True
print(json.dumps(d))
' "$model" "$prompt" "$raw" "$npred")
  out=$(mktemp)
  if curl -sS -m "$TIMEOUT" -H 'Content-Type: application/json' \
       -d "$body" "$ENDPOINT/api/generate" > "$out" 2>/dev/null; then
    end=$(date +%s%N)
    CALL_MS=$(( (end - start) / 1000000 ))
    python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(d.get("response") or "")
except Exception:
  print("")
' "$out"
  else
    CALL_MS=0
    printf ''
  fi
  rm -f "$out"
}

# Simple checks. Args: task response. Return 0 if pass.
check_task() {
  task=$1
  resp=$2
  case "$task" in
    code)
      printf '%s' "$resp" | grep -q 'print' && return 0
      ;;
    instruct)
      printf '%s' "$resp" | grep -qi 'ok' && return 0
      ;;
    reason)
      printf '%s' "$resp" | grep -q '4' && return 0
      ;;
    format)
      printf '%s' "$resp" | grep -q '{' && printf '%s' "$resp" | grep -q '}' && return 0
      ;;
  esac
  return 1
}

run_task() {
  model=$1
  task=$2
  prompt=$3
  raw=$4
  npred=$5
  printf '  %s ... ' "$task"
  if [ "$DRY" -eq 1 ]; then
    printf 'DRY\n'
    return 0
  fi
  resp=$(call_generate "$model" "$prompt" "$raw" "$npred")
  if [ -z "$resp" ]; then
    printf 'FAIL (no response, %sms)\n' "$CALL_MS"
    echo "$model $task FAIL $CALL_MS" >> "$OUTDIR/results.txt"
    return 1
  fi
  if check_task "$task" "$resp"; then
    printf 'PASS (%sms)\n' "$CALL_MS"
    echo "$model $task PASS $CALL_MS" >> "$OUTDIR/results.txt"
  else
    printf 'FAIL (bad output, %sms)\n' "$CALL_MS"
    echo "$model $task FAIL $CALL_MS" >> "$OUTDIR/results.txt"
  fi
}

printf '%s\n' 'Capcom skill probe'
printf 'Endpoint: %s\n' "$ENDPOINT"
printf 'Timeout: %ss\n' "$TIMEOUT"
printf 'Results: %s\n' "$OUTDIR"
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
  printf '%s\n' 'DRY-RUN: would run code, instruct, reason, format against each.'
  exit 0
fi

: > "$OUTDIR/results.txt"

for MODEL in $models; do
  printf '\n==== MODEL %s ====\n' "$MODEL"
  raw=0
  if is_completion "$MODEL"; then
    raw=1
    printf '  (completion model, using raw)\n'
  fi

  # code: complete a tiny function
  run_task "$MODEL" code 'def hello():\n    print("' "$raw" 16

  # instruct: reply with a single word
  run_task "$MODEL" instruct 'Reply with the single word OK.' 0 8

  # reason: simple arithmetic
  run_task "$MODEL" reason 'What is 2 + 2? Answer with just the number.' 0 8

  # format: emit a tiny JSON object
  run_task "$MODEL" format 'Return a JSON object with key "status" and value "ok".' 0 24
done

printf '\n---- SCORE ----\n'
if [ -f "$OUTDIR/results.txt" ]; then
  awk '
    { total[$1]++; if ($3=="PASS") pass[$1]++ }
    END {
      for (m in total)
        printf "%s: %d/%d\n", m, pass[m]+0, total[m]
    }
  ' "$OUTDIR/results.txt"
fi
printf 'Full log: %s/results.txt\n' "$OUTDIR"
