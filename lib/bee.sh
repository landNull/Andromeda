# shellcheck shell=sh
# Installed name of apps/bee/lib.sh. Keep these two files in sync.
# Prefer the app tree when running from the git checkout.

if [ -n "${LIBDIR:-}" ] && [ -f "$LIBDIR/../apps/bee/lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$LIBDIR/../apps/bee/lib.sh"
elif [ -n "${HERE:-}" ] && [ -f "$HERE/apps/bee/lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$HERE/apps/bee/lib.sh"
else
  # Flattened install: /usr/local/lib/andromeda/bee.sh is a copy of apps/bee/lib.sh
  # This branch is only reached if someone sources this shim after a bad ship.
  :
fi
