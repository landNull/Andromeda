#!/usr/bin/env bash
set -euo pipefail

echo "==> [TEST] Security and Architectural Contracts"

if id -u www-admin >/dev/null 2>&1; then
    echo "FAIL: www-admin exists as a user account. It must be group-only."
    exit 1
fi

if ! id -u deploy >/dev/null 2>&1; then
    echo "FAIL: deploy user does not exist."
    exit 1
fi

if [ -d /srv/platforms ]; then
    GROUP_OWNER=$(stat -c '%G' /srv/platforms)
    PERMS=$(stat -c '%a' /srv/platforms)
    if [ "$GROUP_OWNER" != "www-admin" ]; then
        echo "FAIL: /srv/platforms group owner is $GROUP_OWNER (expected www-admin)."
        exit 1
    fi
    if [ "$PERMS" != "2775" ]; then
        echo "FAIL: /srv/platforms permissions are $PERMS (expected 2775)."
        exit 1
    fi
fi

echo "PASS: Security contract checks passed."
