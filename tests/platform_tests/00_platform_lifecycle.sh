#!/usr/bin/env bash
set -euo pipefail

echo "==> [TEST] Platform Lifecycle & Permissions"
PLATFORM_NAME="test-plat-$$"

cleanup() {
    echo "--> Cleaning up platform $PLATFORM_NAME..."
    rm -rf "/srv/platforms/$PLATFORM_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "--> Creating platform: $PLATFORM_NAME (using bee dl-core fallback)"
stardust platform-add "$PLATFORM_NAME"

if [ ! -d "/srv/platforms/$PLATFORM_NAME" ]; then
    echo "FAIL: /srv/platforms/$PLATFORM_NAME directory was not created."
    exit 1
fi

echo "--> Verifying platform directory"
test -d "/srv/platforms/$PLATFORM_NAME"

echo "PASS: Platform lifecycle test completed successfully."
