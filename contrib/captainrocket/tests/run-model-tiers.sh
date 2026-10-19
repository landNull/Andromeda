#!/bin/sh
# contrib/captainrocket/tests/run-model-tiers.sh
# Run incrementally harder tasks against a local model via an Ollama-compatible
# endpoint. Tries prompt styles until one passes the local check, then records
# the winner.
#
#   ./run-model-tiers.sh --model granite-code:3b
#   ./run-model-tiers.sh --model smollm2:1.7b --endpoint http://127.0.0.1:11434
#   ./run-model-tiers.sh --dry-run
#   ./run-model-tiers.sh --style strict --tier 2
#
# Cache: $HOME/.cache/stardust/capcom-model-tiers/<model>.txt
# One line: TIER|LANG|TASK|STYLE

set -eu

PROG=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TIERS="$HERE/tiers.txt"
STYLES="$HERE/prompt-styles"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/stardust/capcom-model-tiers"

MODEL=""
ENDPOINT="${CAPCOM_MODEL_ENDPOINT:-http://127.0.0.1:11434}"
STYLE=""
TIER_FILTER=""
DRY=0
LANG_FILTER=""

usage() {
  cat << USAGE
Usage: $PROG [OPTIONS]

Options:
  --model NAME       Model name to pass to the endpoint (required unless --dry-run)
  --endpoint URL     Ollama-compatible base URL (default: http://127.0.0.1:11434)
  --style NAME       Force one style (default, strict, example). Default: try all.
  --tier N           Run only tier N
  --lang NAME        Run only language (posix, python, php)
  --dry-run          Print filled prompts; do not call a model
  -h, --help         This help

Styles tried (in order) when --style is omitted: default strict example
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --style) STYLE=$2; shift 2 ;;
    --tier) TIER_FILTER=$2; shift 2 ;;
    --lang) LANG_FILTER=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
  esac
done

[ -n "$MODEL" ] || [ "$DRY" -eq 1 ] || { printf '%s: --model required\n' "$PROG" >&2; exit 2; }

mkdir -p "$CACHE_DIR"
safe_model=$(printf '%s' "$MODEL" | tr '/:' '__')
CACHE="$CACHE_DIR/$safe_model.txt"
touch "$CACHE"

lang_label() {
  case "$1" in
    posix) printf 'POSIX /bin/sh IEEE 1003.1' ;;
    python) printf 'Python 3.12' ;;
    php) printf 'PHP 8.2 typed' ;;
    *) printf '%s' "$1" ;;
  esac
}

fill_style() {
  python3 - "$1" "$2" "$3" "$4" "$5" << 'PY'
import sys
tpl, task, lang, inputs, output = sys.argv[1:]
text = open(tpl).read()
text = text.replace("{{TASK}}", task)
text = text.replace("{{LANG}}", lang)
text = text.replace("{{INPUTS}}", inputs)
text = text.replace("{{OUTPUT}}", output)
print(text, end="")
PY
}

extract_code() {
  awk '
    /^```/ { if (in_fence) { exit } else { in_fence=1; next } }
    in_fence { print }
  '
}

call_model() {
  prompt=$1
  body=$(printf '%s' "$prompt" | python3 -c '
import json,sys
p=sys.stdin.read()
print(json.dumps({"model":sys.argv[1],"prompt":p,"stream":False}))
' "$MODEL")
  curl -sS -m 120 -H 'Content-Type: application/json' \
    -d "$body" "$ENDPOINT/api/generate" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("response",""))'
}

already_won() {
  grep -F "$1|$2|$3|" "$CACHE" >/dev/null 2>&1
}

record_win() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$CACHE"
}

printf '%s\n' 'Capcom model tiers'
printf 'Model: %s\n' "${MODEL:-dry-run}"
printf 'Endpoint: %s\n' "$ENDPOINT"
printf 'Cache: %s\n' "$CACHE"
printf '%s\n' '===='

passed=0
failed=0

while IFS='|' read -r tier lang task inputs output check; do
  case "$tier" in
    ''|\#*) continue ;;
  esac
  [ -n "$TIER_FILTER" ] && [ "$tier" != "$TIER_FILTER" ] && continue
  [ -n "$LANG_FILTER" ] && [ "$lang" != "$LANG_FILTER" ] && continue

  printf '\n---- TIER %s LANG=%s ----\n' "$tier" "$lang"
  printf 'TASK: %s\n' "$task"

  if already_won "$tier" "$lang" "$task"; then
    printf '%s\n' 'SKIP: already won (see cache)'
    passed=$((passed+1))
    continue
  fi

  styles="default strict example"
  [ -n "$STYLE" ] && styles=$STYLE

  won=0
  for style in $styles; do
    printf 'STYLE: %s\n' "$style"
    style_file="$STYLES/$style.txt"
    [ -f "$style_file" ] || { printf 'missing style %s\n' "$style" >&2; continue; }
    filled=$(fill_style "$style_file" "$task" "$(lang_label "$lang")" "$inputs" "$output")

    if [ "$DRY" -eq 1 ]; then
      printf '%s\n' "$filled"
      printf '%s\n' '---- end style ----'
      continue
    fi

    reply=$(call_model "$filled" || true)
    code=$(printf '%s\n' "$reply" | extract_code || true)
    [ -n "$code" ] || code=$reply

    if printf '%s\n' "$code" | eval "$check" >/dev/null 2>&1; then
      printf 'OK STYLE=%s\n' "$style"
      record_win "$tier" "$lang" "$task" "$style"
      passed=$((passed+1))
      won=1
      break
    else
      printf 'FAIL STYLE=%s\n' "$style"
    fi
  done

  if [ "$won" -eq 0 ] && [ "$DRY" -eq 0 ]; then
    printf 'ERROR\nLAYER: model\nFILE: tiers.txt\nWHAT: no style passed tier %s (%s)\nWHY: all tried styles failed the local check\nFIX: inspect the model reply or add a new style\n' "$tier" "$lang"
    failed=$((failed+1))
  fi
done < "$TIERS"

printf '%s\n' ''
printf '%s\n' '==== SUMMARY ===='
printf 'Passed: %s\n' "$passed"
printf 'Failed: %s\n' "$failed"
printf 'Cache: %s\n' "$CACHE"
[ "$failed" -eq 0 ]
