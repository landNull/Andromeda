#!/bin/sh
# contrib/captainrocket/starcoder-complete.sh
# Capcom tool: complete a code prefix with starcoder2:3b (raw).
#
#   ./starcoder-complete.sh 'def hello():\n    print("'
#   printf '%s' "$prefix" | ./starcoder-complete.sh
#
# Prints the completion on stdout. One SPEAK line on stderr.
# Exit 0 on a non-empty completion, 1 on failure.

set -eu

PROG=${0##*/}
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
MODEL="${STARCODER_MODEL:-starcoder2:3b}"
TIMEOUT="${STARCODER_TIMEOUT:-60}"
NPRED="${STARCODER_NPRED:-64}"

if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
  printf 'SPEAK: Refusing to run as root.\n' >&2
  exit 2
fi

if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
  prefix=$1
else
  prefix=$(cat)
fi

if [ -z "$prefix" ]; then
  printf 'SPEAK: Give a code prefix to complete.\n' >&2
  exit 2
fi

body=$(python3 -c '
import json,sys
prefix,model,npred=sys.argv[1:]
d={"model":model,"prompt":prefix,"raw":True,"stream":False,
   "options":{"num_predict":int(npred),"temperature":0.1}}
print(json.dumps(d))
' "$prefix" "$MODEL" "$NPRED")

out=$(mktemp)
trap 'rm -f "$out"' EXIT

if ! curl -sS -m "$TIMEOUT" -H 'Content-Type: application/json' \
     -d "$body" "$ENDPOINT/api/generate" > "$out" 2>/dev/null; then
  printf 'SPEAK: StarCoder did not answer.\n' >&2
  exit 1
fi

resp=$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(d.get("response") or "")
except Exception:
  print("")
' "$out")

if [ -z "$resp" ]; then
  printf 'SPEAK: StarCoder returned an empty completion.\n' >&2
  exit 1
fi

printf '%s' "$resp"
printf 'SPEAK: Completion from %s.\n' "$MODEL" >&2
exit 0
