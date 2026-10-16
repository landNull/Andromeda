#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
RUN_PREFLIGHT=0
DRYRUN=0

usage() {
    cat << USAGE
Usage: ./tests/$PROG [OPTIONS]
Modular test suite runner for Stardust.

Options:
  --all           Run all test modules in the correct architectural sequence
  --platform      Run platform creation, ownership, and permission tests
  --site          Run site lifecycle, Bee CLI, and health check tests
  --security      Run security boundaries, group memberships, and sudo delegation tests
  --preflight     Run system diagnostics and Stardust doctor checks
  --dry-run       Preview actions without executing mutating commands
  -h, --help      Display this help message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) RUN_ALL=1; shift ;;
        --platform) RUN_PLATFORM=1; shift ;;
        --site) RUN_SITE=1; shift ;;
        --security) RUN_SECURITY=1; shift ;;
        --preflight) RUN_PREFLIGHT=1; shift ;;
        --dry-run) DRYRUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "$PROG: unknown argument $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ $RUN_ALL -eq 0 ] && [ $RUN_PLATFORM -eq 0 ] && [ $RUN_SITE -eq 0 ] && [ $RUN_SECURITY -eq 0 ] && [ $RUN_PREFLIGHT -eq 0 ]; then
    RUN_ALL=1
fi

echo "=========================================================="
echo " Stardust Test Suite Execution"
echo " Time: $(date)"
echo " Log:  $LOG_FILE"
echo "=========================================================="

FAILED=0
PASSED=0

run_module() {
    local mod_path="$1"
    local mod_name="$2"
    if [ -f "$mod_path" ]; then
        echo -e "\n\033[0;33mINFO: Running [${mod_name}] -> ${mod_path}\033[0m"
        if [ "$DRYRUN" -eq 1 ]; then
            echo "[DRY-RUN] Would execute: bash $mod_path"
            PASSED=$((PASSED + 1))
        else
            if bash "$mod_path"; then
                echo -e "\033[0;32mPASS: ${mod_name}\033[0m"
                PASSED=$((PASSED + 1))
            else
                echo -e "\033[0;31mFAIL: ${mod_name} - FAILED!\033[0m"
                FAILED=$((FAILED + 1))
            fi
        fi
    fi
}

if [ "$RUN_ALL" -eq 1 ]; then
    run_module "${SCRIPT_DIR}/security_tests/00_permissions_and_contracts.sh" "Security & Contracts"
    run_module "${SCRIPT_DIR}/install_tests/00_installation_smoke.sh" "Installation Smoke"
    run_module "${SCRIPT_DIR}/platform_tests/00_platform_lifecycle.sh" "Platform Lifecycle"
    run_module "${SCRIPT_DIR}/site_tests/00_site_lifecycle.sh" "Site Lifecycle"
else
    [ "$RUN_PREFLIGHT" -eq 1 ] && run_module "${SCRIPT_DIR}/cli_tests/00_stardust_doctor.sh" "Stardust Doctor"
    [ "$RUN_SECURITY" -eq 1 ] && run_module "${SCRIPT_DIR}/security_tests/00_permissions_and_contracts.sh" "Security & Contracts"
    [ "$RUN_PLATFORM" -eq 1 ] && run_module "${SCRIPT_DIR}/platform_tests/00_platform_lifecycle.sh" "Platform Lifecycle"
    [ "$RUN_SITE" -eq 1 ] && run_module "${SCRIPT_DIR}/site_tests/00_site_lifecycle.sh" "Site Lifecycle"
fi

echo ""
echo "=========================================================="
echo " Test Run Summary"
echo " Passed: $PASSED"
echo " Failed: $FAILED"
echo " Log:    $LOG_FILE"
echo "=========================================================="

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
exit 0
