#!/usr/bin/env bash
# run-test.sh — Stardust interactive test runner.
# Prompts for needed values with defaults. Never opens a root shell.
# sudo is used only for stardust-priv, bee, git, crdir (existing sudoers).
#
#   ./tests/run-test.sh                 # prompt, then --all
#   ./tests/run-test.sh --all
#   ./tests/run-test.sh -n platform
#   ./tests/run-test.sh -n daily
#   ./tests/run-test.sh --diagnose
#   ./tests/run-test.sh --lint
#   ./tests/run-test.sh --json --speak -n daily
#   ./tests/run-test.sh --intent "run the daily tests"

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_DIR}/test_run_${TIMESTAMP}.log"
LATEST_LOG="${LOG_DIR}/latest.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
ln -sfn "$LOG_FILE" "$LATEST_LOG"

PROG=${0##*/}
RUN_ALL=0
RUN_PLATFORM=0
RUN_SITE=0
RUN_SECURITY=0
RUN_DAILY=0
RUN_DIAGNOSE=0
RUN_LINT=0
RUN_HEAL=0
RUN_JSON=0
RUN_SPEAK=0
DRYRUN=0
MODULE=""
INTENT=""

# Defaults — overridden by prompt or flags
PLATFORM_NAME="${PLATFORM_NAME:-smoke}"
DOMAIN="${DOMAIN:-starhq.knarr}"
SITE_NAME="${SITE_NAME:-demo}"
ENV_NAME="${ENV_NAME:-devel}"

usage() {
    cat << USAGE
Usage: ./tests/$PROG [OPTIONS]
Interactive Stardust test runner. Prompts for values when needed.

Options:
  --all              Prompt, then run all modules
  -n, --module NAME  Run one module: platform, site, security, daily
  --diagnose         Stack checks only
  --lint             posaxe syntax and pattern checks
  --heal             posaxe safe fixes, then check
  --dry-run          Preview module runs
  --json             One JSON object per step (Capcom / LLM)
  --speak            One SPEAK: line for a voice assistant
  --intent PHRASE    Map a spoken phrase to a module
  -h, --help         This help

Environment overrides (skip prompt if set):
  PLATFORM_NAME  DOMAIN  SITE_NAME  ENV_NAME
USAGE
}

prompt() {
    # prompt VAR "Label" "default"
    local var="$1" label="$2" def="$3" ans
    if [ -n "${!var:-}" ] && [ "${!var}" != "$def" ]; then
        return 0
    fi
    read -r -p "$label [$def]: " ans
    if [ -n "$ans" ]; then
        printf -v "$var" '%s' "$ans"
    else
        printf -v "$var" '%s' "$def"
    fi
}

need_prompts() {
    [ "$RUN_JSON" -eq 1 ] && return 1
    [ "$RUN_SPEAK" -eq 1 ] && return 1
    [ -t 0 ] || return 1
    [ "$RUN_ALL" -eq 1 ] || [ "$RUN_PLATFORM" -eq 1 ] || [ "$RUN_SITE" -eq 1 ] || [ "$RUN_DAILY" -eq 1 ]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) RUN_ALL=1; shift ;;
        -n|--module) MODULE="$2"; shift 2 ;;
        --diagnose) RUN_DIAGNOSE=1; shift ;;
        --lint) RUN_LINT=1; shift ;;
        --heal) RUN_HEAL=1; shift ;;
        --platform) RUN_PLATFORM=1; shift ;;
        --site) RUN_SITE=1; shift ;;
        --security) RUN_SECURITY=1; shift ;;
        --daily) RUN_DAILY=1; shift ;;
        --dry-run) DRYRUN=1; shift ;;
        --json) RUN_JSON=1; shift ;;
        --speak) RUN_SPEAK=1; shift ;;
        --intent) INTENT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "$PROG: unknown argument $1" >&2; usage >&2; exit 2 ;;
    esac
done

resolve_intent() {
    # maps a spoken phrase to a module. See tests/intents.txt.
    local p
    p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$p" in
        *daily*|*webadmin*|*web\ admin*) echo daily ;;
        *platform*) echo platform ;;
        *site*|*lifecycle*) echo site ;;
        *security*|*contract*) echo security ;;
        *diagnos*|*stack*) echo diagnose ;;
        *lint*|*posaxe*) echo lint ;;
        *heal*) echo heal ;;
        *all*|*everything*) echo all ;;
        *) echo "" ;;
    esac
}

if [ -n "$INTENT" ]; then
    resolved=$(resolve_intent "$INTENT")
    case "$resolved" in
        daily) RUN_DAILY=1 ;;
        platform) RUN_PLATFORM=1 ;;
        site) RUN_SITE=1 ;;
        security) RUN_SECURITY=1 ;;
        diagnose) RUN_DIAGNOSE=1 ;;
        lint) RUN_LINT=1 ;;
        heal) RUN_HEAL=1 ;;
        all) RUN_ALL=1 ;;
        *) echo "$PROG: no module for intent: $INTENT" >&2; exit 2 ;;
    esac
fi

case "$MODULE" in
    platform) RUN_PLATFORM=1 ;;
    site) RUN_SITE=1 ;;
    security) RUN_SECURITY=1 ;;
    daily) RUN_DAILY=1 ;;
    "") ;;
    *) echo "$PROG: unknown module $MODULE" >&2; exit 2 ;;
esac

if [ $RUN_ALL -eq 0 ] && [ $RUN_PLATFORM -eq 0 ] && [ $RUN_SITE -eq 0 ] && \
   [ $RUN_SECURITY -eq 0 ] && [ $RUN_DAILY -eq 0 ] && [ $RUN_DIAGNOSE -eq 0 ] && \
   [ $RUN_LINT -eq 0 ] && [ $RUN_HEAL -eq 0 ]; then
    RUN_ALL=1
fi

# --- groups: refuse a root shell ----------------------------------------
in_group() { id -nG 2>/dev/null | grep -qw "$1"; }

if ! in_group www-admin || ! in_group stardust; then
    echo "ERROR"
    echo "LAYER: host"
    echo "FILE: /etc/group"
    echo "WHAT: Current user is missing group www-admin or stardust."
    echo "WHY: Mutating Stardust commands require both groups. A sudo shell would create root-owned files and break Bee."
    echo "FIX: sudo usermod -aG www-admin,stardust \$USER ; then log out and log back in. Do not run this script under sudo."
    printf '%s\n' '{"module":"host","status":"fail","what":"missing www-admin or stardust"}'
    printf 'SPEAK: Cannot run. You are not in www-admin and stardust. Log out and back in after usermod.\n'
    exit 1
fi

# Limited sudo helper — only the four sudoers commands
stardust_sudo() {
    # stardust_sudo stardust-priv|bee|git|crdir [args...]
    case "$1" in
        stardust-priv|bee|git|crdir) sudo -- "$@" ;;
        *) echo "REFUSED: sudo only allowed for stardust-priv, bee, git, crdir" >&2; return 1 ;;
    esac
}

echo "=========================================================="
echo " Stardust run-test"
echo " Time: $(date)"
echo " Log:  $LOG_FILE"
echo " Repo: $REPO_ROOT"
echo "=========================================================="

if need_prompts; then
    echo ""
    echo "---- INPUT (Enter accepts the default) ----"
    prompt PLATFORM_NAME "Platform name" "$PLATFORM_NAME"
    prompt DOMAIN "Domain" "$DOMAIN"
    prompt SITE_NAME "Site name" "$SITE_NAME"
    prompt ENV_NAME "Environment" "$ENV_NAME"
    echo "Using: platform=$PLATFORM_NAME domain=$DOMAIN site=$SITE_NAME env=$ENV_NAME"
    export PLATFORM_NAME DOMAIN SITE_NAME ENV_NAME
fi

FAILED=0
PASSED=0

emit_json() {
    # emit_json module status what
    [ "$RUN_JSON" -eq 1 ] || return 0
    printf '{"module":"%s","status":"%s","what":"%s"}\n' "$1" "$2" "$3"
}

emit_speak() {
    [ "$RUN_SPEAK" -eq 1 ] || return 0
    printf 'SPEAK: %s\n' "$1"
}

error_block() {
    echo ""
    echo "ERROR"
    echo "LAYER: $1"
    echo "FILE: $2"
    echo "WHAT: $3"
    echo "WHY: $4"
    echo "FIX: $5"
    echo ""
    FAILED=$((FAILED + 1))
}

ok_block() {
    echo "OK LAYER=$1 FILE=$2 WHAT=$3"
    PASSED=$((PASSED + 1))
}

# --- lint ----------------------------------------------------------------
# Always lint unless this is a pure --diagnose run. Heal stays opt-in.
POSAXE="$REPO_ROOT/bin/posaxe"
run_posaxe() {
    local mode="$1"
    echo ""
    echo "---- LINT (posaxe $mode) ----"
    if [ ! -x "$POSAXE" ]; then
        error_block lint bin/posaxe \
            "posaxe is missing or not executable." \
            "The runner delegates checks to bin/posaxe." \
            "Restore bin/posaxe and chmod 755 it."
        return 1
    fi
    cd "$REPO_ROOT"
    if [ "$mode" = heal ]; then
        "$POSAXE" --json heal || FAILED=$((FAILED+1))
    else
        "$POSAXE" --json check || FAILED=$((FAILED+1))
    fi
    echo "---- END LINT ----"
}

if [ "$RUN_DIAGNOSE" -eq 0 ]; then
    if [ "$RUN_HEAL" -eq 1 ]; then
        run_posaxe heal
    else
        run_posaxe check
    fi
fi

if [ "$RUN_LINT" -eq 1 ] && [ "$RUN_ALL" -eq 0 ] && [ "$RUN_PLATFORM" -eq 0 ]; then
    echo "Passed: $PASSED  Failed: $FAILED"
    echo "Log: $LOG_FILE"
    [ "$FAILED" -eq 0 ] && exit 0 || exit 1
fi

# --- diagnosis -----------------------------------------------------------
echo ""
echo "---- STACK DIAGNOSIS ----"
ok_block host /etc/group "operator is in www-admin and stardust"

if id deploy >/dev/null 2>&1; then
    ok_block host /etc/passwd "deploy user exists"
else
    error_block host /etc/passwd \
        "User deploy does not exist." \
        "platform-add runs bee as deploy." \
        "Re-run install-stardust.sh so STEP deploy creates the account."
fi

if [ -d /srv/platforms ]; then
    perms=$(stat -c '%a' /srv/platforms 2>/dev/null || echo unknown)
    grp=$(stat -c '%G' /srv/platforms 2>/dev/null || echo unknown)
    if [ "$grp" = "www-admin" ] && [ "$perms" = "2775" ]; then
        ok_block host /srv/platforms "mode 2775 group www-admin"
    else
        error_block host /srv/platforms \
            "Directory mode is $perms and group is $grp." \
            "Bee runs as deploy and must write under a new platform." \
            "Run: sudo chown deploy:www-admin /srv/platforms && sudo chmod 2775 /srv/platforms"
    fi
else
    error_block host /srv/platforms \
        "Directory /srv/platforms does not exist." \
        "platform-add expects this root." \
        "Run: sudo mkdir -p /srv/platforms && sudo chown deploy:www-admin /srv/platforms && sudo chmod 2775 /srv/platforms"
fi

if [ -x "$REPO_ROOT/bin/stardust" ]; then
    ok_block runtime bin/stardust "CLI present"
else
    error_block runtime bin/stardust \
        "CLI binary is missing." \
        "Tests and the operator call this file." \
        "Restore bin/stardust from the repo."
fi

echo "---- END DIAGNOSIS ----"

if [ "$RUN_DIAGNOSE" -eq 1 ]; then
    echo "Diagnosis only."
    echo "Passed: $PASSED  Failed: $FAILED"
    echo "Log: $LOG_FILE"
    emit_json "diagnose" "$([ "$FAILED" -eq 0 ] && echo pass || echo fail)" "passed=$PASSED failed=$FAILED"
    if [ "$FAILED" -eq 0 ]; then
        emit_speak "Diagnosis passed. $PASSED checks, 0 failed."
    else
        emit_speak "Diagnosis failed. $PASSED passed, $FAILED failed."
    fi
    [ "$FAILED" -eq 0 ] && exit 0 || exit 1
fi

# --- modules -------------------------------------------------------------
run_module() {
    local mod_path="$1" mod_name="$2"
    if [ ! -f "$mod_path" ]; then
        echo "SKIP $mod_name — missing: $mod_path"
        return 0
    fi
    echo ""
    echo "INFO MODULE=$mod_name FILE=$mod_path"
    echo "INFO PLATFORM=$PLATFORM_NAME DOMAIN=$DOMAIN SITE=$SITE_NAME ENV=$ENV_NAME"
    if [ "$DRYRUN" -eq 1 ]; then
        echo "DRY-RUN would run: bash $mod_path"
        emit_json "$mod_name" "dry-run" "would run $mod_path"
        PASSED=$((PASSED + 1))
        return 0
    fi
    if PLATFORM_NAME="$PLATFORM_NAME" DOMAIN="$DOMAIN" SITE_NAME="$SITE_NAME" ENV_NAME="$ENV_NAME" bash "$mod_path"; then
        echo "PASS MODULE=$mod_name"
        emit_json "$mod_name" "pass" "module completed"
        PASSED=$((PASSED + 1))
    else
        echo ""
        echo "ERROR"
        echo "LAYER: test"
        echo "FILE: $mod_path"
        echo "WHAT: Module $mod_name exited non-zero."
        echo "WHY: See the ERROR blocks above."
        echo "FIX: Fix the LAYER named in the first ERROR block, then re-run."
        echo ""
        echo "INFO re-running posaxe after module failure"
        run_posaxe check
        emit_json "$mod_name" "fail" "module exited non-zero"
        FAILED=$((FAILED + 1))
    fi
}

if [ "$RUN_ALL" -eq 1 ]; then
    run_module "${SCRIPT_DIR}/security_tests/00_permissions_and_contracts.sh" "Security and contracts"
    run_module "${SCRIPT_DIR}/platform_tests/00_platform_lifecycle.sh" "Platform lifecycle"
    run_module "${SCRIPT_DIR}/site_tests/00_site_lifecycle.sh" "Site lifecycle"
    run_module "${SCRIPT_DIR}/daily_tests/00_daily_webadmin.sh" "Daily webadmin"
else
    [ "$RUN_SECURITY" -eq 1 ] && run_module "${SCRIPT_DIR}/security_tests/00_permissions_and_contracts.sh" "Security and contracts"
    [ "$RUN_PLATFORM" -eq 1 ] && run_module "${SCRIPT_DIR}/platform_tests/00_platform_lifecycle.sh" "Platform lifecycle"
    [ "$RUN_SITE" -eq 1 ] && run_module "${SCRIPT_DIR}/site_tests/00_site_lifecycle.sh" "Site lifecycle"
    [ "$RUN_DAILY" -eq 1 ] && run_module "${SCRIPT_DIR}/daily_tests/00_daily_webadmin.sh" "Daily webadmin"
fi

echo ""
echo "=========================================================="
echo " SUMMARY"
echo " Passed: $PASSED"
echo " Failed: $FAILED"
echo " Log: $LOG_FILE"
echo "=========================================================="
emit_json "summary" "$([ "$FAILED" -eq 0 ] && echo pass || echo fail)" "passed=$PASSED failed=$FAILED"
if [ "$FAILED" -eq 0 ]; then
    emit_speak "Stardust tests passed. $PASSED checks, 0 failed."
else
    emit_speak "Stardust tests failed. $PASSED passed, $FAILED failed. See the log."
fi
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
