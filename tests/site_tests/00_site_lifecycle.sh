#!/usr/bin/env bash
set -euo pipefail

echo "==> [TEST] Site Lifecycle & Bee Integration"
PLATFORM_NAME="siteplat-$$"
SITE_NAME="www"

cleanup() {
    echo "--> Cleaning up site and platform..."
    stardust site-remove "$PLATFORM_NAME" "$SITE_NAME" >/dev/null 2>&1 || true
    stardust platform-remove "$PLATFORM_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--> Provisioning test platform: $PLATFORM_NAME"
stardust platform-add "$PLATFORM_NAME"

echo "--> Adding test site: $SITE_NAME on platform $PLATFORM_NAME"
stardust site-add "$PLATFORM_NAME" "$SITE_NAME" --host "${SITE_NAME}.devel" --name "Test Site"

echo "--> Verifying site status & running Bee cache clear"
stardust site-status "$PLATFORM_NAME" "$SITE_NAME"
stardust site-bee "$PLATFORM_NAME" "$SITE_NAME" cc all

echo "PASS: Site lifecycle test completed successfully."
