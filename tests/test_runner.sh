#!/bin/sh
# Compatibility shim. The live runner is tests/run-test.sh.
# Capcom and old paths both land here.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$HERE/run-test.sh" "$@"
