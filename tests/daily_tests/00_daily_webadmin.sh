#!/usr/bin/env bash
# daily_tests/00_daily_webadmin.sh — a day in the life of a Andromeda webadmin.
# Uses the real CLI the same way an operator does. Creates its own platform
# and product, exercises the daily verbs, then removes them.
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
export PATH="$REPO/bin:$PATH"

PLAT="${PLATFORM_NAME:-dailyplat-$$}"
PROD="${SITE_NAME:-www$$}"
PREVIEW="${PROD}-preview"
HOST="${PROD}.devel"
PREVIEW_HOST="${PREVIEW}.devel"
TITLE="Daily ${PROD}"

echo "==> [TEST] Daily webadmin flow"
echo "--> platform=$PLAT product=$PROD host=$HOST"

# Clean on failure, or when STARDUST_KEEP is unset.
# Capcom exports STARDUST_KEEP=1 so a successful drive leaves the platform.
DAILY_OK=0
cleanup() {
    if [ "$DAILY_OK" -eq 1 ] && [ -n "${STARDUST_KEEP:-}" ]; then
        echo "--> keep platform=$PLAT (STARDUST_KEEP set, module passed)"
        return 0
    fi
    echo "--> cleanup"
    andromeda site-delete "$PLAT" "$PREVIEW" --force >/dev/null 2>&1 || true
    andromeda site-delete "$PLAT" "$PROD" --force >/dev/null 2>&1 || true
    rm -rf "/srv/platforms/$PLAT" 2>/dev/null || true
}
trap cleanup EXIT

# Morning health. doctor may exit 1 if the host is NOT READY; record it, do not abort.
echo "--> doctor"
if andromeda doctor; then
    echo "OK doctor READY"
else
    echo "NOTE doctor NOT READY (continuing; host may still serve sites)"
fi

echo "--> platform-add $PLAT"
andromeda platform-add "$PLAT"

echo "--> site-add $PLAT $PROD --host $HOST"
andromeda site-add "$PLAT" "$PROD" --host "$HOST" --name "$TITLE"

echo "--> inventory"
andromeda inventory

echo "--> site-check $PLAT $PROD"
andromeda site-check "$PLAT" "$PROD" --host "$HOST"

echo "--> site-disable / site-enable"
andromeda site-disable "$PLAT" "$PROD"
andromeda site-enable "$PLAT" "$PROD"

echo "--> bee cc all / status"
andromeda bee "$PLAT" "$PROD" cc all
andromeda bee "$PLAT" "$PROD" status

echo "--> site-backup"
andromeda site-backup "$PLAT" "$PROD"

echo "--> site-restore (latest)"
andromeda site-restore "$PLAT" "$PROD"

echo "--> site-clone to $PREVIEW"
andromeda site-clone "$PLAT" "$PROD" "$PLAT" "$PREVIEW" --host "$PREVIEW_HOST"
andromeda site-check "$PLAT" "$PREVIEW" --host "$PREVIEW_HOST"

echo "--> site-delete preview"
andromeda site-delete "$PLAT" "$PREVIEW" --force

echo "--> log / last"
andromeda log 10 || true
andromeda last || true

echo "PASS: Daily webadmin flow completed."
DAILY_OK=1
