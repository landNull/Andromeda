#!/bin/sh
# contrib/captainrocket/starcoder-complete.sh
# Capcom tool: complete a code prefix with starcoder2 (raw).
#
#   ./starcoder-complete.sh 'def add(a, b):\n    """Return the sum."""\n    return '
#   printf '%s' "$prefix" | ./starcoder-complete.sh
#
# Environment:
#   STARCODER_MODEL   default starcoder2:3b
#   STARCODER_NPRED   default 64
#   STARCODER_TEMP    default 0.05
#   STARCODER_STOP    comma-separated stop strings (default: \n\ndef ,\n\nclass )
#   STARCODER_SUFFIX  optional suffix for fill-in-the-middle
#   CAPCOM_MODEL_ENDPOINT default http://127.0.0.1:11434
#
# Prints the completion on stdout. One SPEAK line on stderr.
# Exit 0 on a non-empty completion, 1 on failure, 2 on usage.

set -eu

PROG=${0##*/}
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
MODEL="${STARCODER_MODEL:-starcoder2:3b}"
TIMEOUT="${STARCODER_TIMEOUT:-90}"
NPRED="${STARCODER_NPRED:-64}"
TEMP="${STARCODER_TEMP:-0.05}"
STOP="${STARCODER_STOP:-\\n\\ndef ,\\n\\nclass }"
SUFFIX="${STARCODER_SUFFIX:-}"

if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
  printf 'SPEAK: Refusing to run as root.\n' >&2
  exit 2
fi

if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
  prefix=$1
  if [ $# -ge 2 ]; then
    SUFFIX=$2
  fi
else
  prefix=$(cat)
fi

if [ -z "$prefix" ]; then
  printf 'SPEAK: Give a code prefix to complete.\n' >&2
  exit 2
fi

# Build request body (handles stop list and optional FIM tokens).
body=$(python3 -c '
import json, sys, os
prefix = sys.argv[1]
model = sys.argv[2]
npred = int(sys.argv[3])
temp = float(sys.argv[4])
stop_raw = sys.argv[5]
suffix = sys.argv[6] if len(sys.argv) > 6 else ""

stops = []
if stop_raw:
    for s in stop_raw.split(","):
        s = s.strip()
        if not s:
            continue
        # allow literal \n in the env value
        s = s.replace("\\n", "\n")
        stops.append(s)

if suffix:
    # StarCoder2 FIM style
    prompt = "<fim_prefix>" + prefix + "<fim_suffix>" + suffix + "<fim_middle>"
else:
    prompt = prefix

opts = {
    "num_predict": npred,
    "temperature": temp,
}
if stops:
    opts["stop"] = stops

d = {
    "model": model,
    "prompt": prompt,
    "raw": True,
    "stream": False,
    "options": opts,
}
print(json.dumps(d))
' "$prefix" "$MODEL" "$NPRED" "$TEMP" "$STOP" "$SUFFIX")

out=$(mktemp)
trap 'rm -f "$out"' EXIT

if ! curl -sS -m "$TIMEOUT" -H 'Content-Type: application/json' \
     -d "$body" "$ENDPOINT/api/generate" > "$out" 2>/dev/null; then
  printf 'SPEAK: StarCoder did not answer.\n' >&2
  exit 1
fi

# Extract response and apply a light post-filter to cut trailing noise.
resp=$(python3 -c '
import json, sys, re
path = sys.argv[1]
try:
    d = json.load(open(path))
    text = d.get("response") or ""
except Exception:
    text = ""

if not text:
    print("")
    sys.exit(0)

# Prefer the first complete function-like block.
# Stop at the first double blank line after we have seen a return or a closing pattern.
lines = text.splitlines(keepends=True)
out = []
saw_code = False
blank_run = 0
for line in lines:
    stripped = line.strip()
    if not stripped:
        blank_run += 1
        if saw_code and blank_run >= 2:
            break
        out.append(line)
        continue
    blank_run = 0
    # Drop pure comment noise once we have real code and a blank line already passed
    if saw_code and stripped.startswith("#") and len(out) > 3:
        # allow one comment, then stop
        out.append(line)
        break
    out.append(line)
    if stripped and not stripped.startswith("#"):
        saw_code = True

result = "".join(out).rstrip()
print(result)
' "$out")

if [ -z "$resp" ]; then
  printf 'SPEAK: StarCoder returned an empty completion.\n' >&2
  exit 1
fi

printf '%s\n' "$resp"
printf 'SPEAK: Completion from %s.\n' "$MODEL" >&2
exit 0
