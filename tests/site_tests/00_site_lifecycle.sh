#!/usr/bin/env bash
set -euo pipefail

echo "==> [TEST] Site Lifecycle & Bee Integration"
PLATFORM_NAME="siteplat-$$"
SITE_NAME="www$$"
HOST="${SITE_NAME}.devel"
SITE_NAME="www$$"

cleanup() {
    echo "--> Cleaning up site and platform..."
    stardust site-delete "$PLATFORM_NAME" "$SITE_NAME" --force >/dev/null 2>&1 || true
    rm -rf "/srv/platforms/$PLATFORM_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "--> Provisioning test platform: $PLATFORM_NAME"
stardust platform-add "$PLATFORM_NAME"

echo "--> Adding test site: $SITE_NAME on platform $PLATFORM_NAME"
stardust site-add "$PLATFORM_NAME" "$SITE_NAME" --host "$HOST" --name "Test Site"

echo "--> Verifying site and clearing cache"
stardust site-check "$PLATFORM_NAME" "$SITE_NAME" --host "$HOST"
stardust bee "$PLATFORM_NAME" "$SITE_NAME" cc all

echo "PASS: Site lifecycle test completed successfully."
