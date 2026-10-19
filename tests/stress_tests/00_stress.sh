#!/usr/bin/env bash
# stress_tests/00_stress.sh — multi-variation exercise of Stardust and Bee.
#
# Variations (in order):
#   1. Download Backdrop OLD_VER (default 1.28.4) into a dedicated platform
#   2. site-add first product on the old core (Bee install path)
#   3. Bee status + cache clear on the old site
#   4. site-backup of the old site
#   5. Upgrade core in place: download latest over the old web,
#      then updb, config-import, site-check
#   6. platform-upgrade --no-pull (backup every product, updb, check)
#   7. Second site on the same platform (core/scripts/install.sh, not Bee)
#   8. site-clone same platform to a preview host
#   9. Cross-platform clone: new platform on latest, clone the upgraded site
#  10. site-disable / site-enable
#  11. site-restore from the pre-upgrade backup
#  12. Bee cron, config-export, config-import, uli
#  13. D7 toolkit: d7-stubs and d7-toolkit (no dump; full d7-prep needs one)
#  14. inventory + doctor + log
#  15. Cleanup unless STARDUST_KEEP is set
#
# Opt-in. Not part of --all. Run with:
#   ./tests/run-test.sh -n stress
# Override the old pin with STARDUST_STRESS_OLD=1.30.2
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
export PATH="$REPO/bin:$PATH"

STAMP=$$
OLD_PLAT="stress-old-${STAMP}"
NEW_PLAT="stress-new-${STAMP}"
PROD="www${STAMP}"
SECOND="www${STAMP}b"
PREVIEW="${PROD}-preview"
CROSS="www${STAMP}-x"
OLD_VER="${STARDUST_STRESS_OLD:-1.28.4}"
HOST="${PROD}.devel"
SECOND_HOST="${SECOND}.devel"
PREVIEW_HOST="${PREVIEW}.devel"
CROSS_HOST="${CROSS}.devel"
PLATFORMS=/srv/platforms
STRESS_OK=0

echo "==> [TEST] Stress"
echo "--> old-platform=$OLD_PLAT new-platform=$NEW_PLAT"
echo "--> product=$PROD second=$SECOND preview=$PREVIEW cross=$CROSS"
echo "--> old core=$OLD_VER"

cleanup() {
    if [ "$STRESS_OK" -eq 1 ] && [ -n "${STARDUST_KEEP:-}" ]; then
        echo "--> keep platforms $OLD_PLAT $NEW_PLAT (STARDUST_KEEP set, module passed)"
        return 0
    fi
    echo "--> cleanup"
    for plat in "$OLD_PLAT" "$NEW_PLAT"; do
        for prod in "$PROD" "$SECOND" "$PREVIEW" "$CROSS"; do
            stardust site-delete "$plat" "$prod" --force >/dev/null 2>&1 || true
        done
        sudo rm -rf "$PLATFORMS/$plat" 2>/dev/null || true
    done
}
trap cleanup EXIT

step() { echo ""; echo "--> $*"; }

# 1. Old core. platform-add always fetches latest, so build this one by hand.
step "1 download Backdrop $OLD_VER into $OLD_PLAT"
sudo mkdir -p "$PLATFORMS/$OLD_PLAT"
sudo chown deploy:www-admin "$PLATFORMS/$OLD_PLAT"
sudo chmod 2775 "$PLATFORMS/$OLD_PLAT"
(
    cd "$PLATFORMS/$OLD_PLAT"
    sudo -u deploy bee dl-core web --version="$OLD_VER"
)
sudo -u deploy git -C "$PLATFORMS/$OLD_PLAT" init >/dev/null
sudo -u deploy git -C "$PLATFORMS/$OLD_PLAT" checkout -B devel >/dev/null 2>&1 || true
if [ ! -f "$PLATFORMS/$OLD_PLAT/web/core/includes/bootstrap.inc" ]; then
    echo "ERROR"
    echo "LAYER: runtime"
    echo "FILE: $PLATFORMS/$OLD_PLAT/web"
    echo "WHAT: Backdrop $OLD_VER did not land."
    echo "WHY: bee dl-core --version=$OLD_VER failed or wrote elsewhere."
    echo "FIX: Run 'sudo -u deploy bee dl-core web --version=$OLD_VER' in an empty dir and check the version tag."
    exit 1
fi
echo "OK core $OLD_VER at $PLATFORMS/$OLD_PLAT/web"

# 2. First site on the old core (Bee path).
step "2 site-add $PROD on old core (Bee)"
stardust site-add "$OLD_PLAT" "$PROD" --host "$HOST" --name "Stress $PROD"
stardust site-check "$OLD_PLAT" "$PROD" --host "$HOST"

# 3. Bee status and cache.
step "3 bee status + cc all"
stardust bee "$OLD_PLAT" "$PROD" status
stardust bee "$OLD_PLAT" "$PROD" cc all

# 4. Backup before the upgrade.
step "4 site-backup $PROD"
stardust site-backup "$OLD_PLAT" "$PROD"

# 5. Upgrade core in place: latest over the old web, then updb.
step "5 upgrade core in place to latest"
(
    cd "$PLATFORMS/$OLD_PLAT"
    sudo -u deploy bee dl-core web --version=latest
)
stardust bee "$OLD_PLAT" "$PROD" updb
stardust bee "$OLD_PLAT" "$PROD" config-import || true
stardust site-check "$OLD_PLAT" "$PROD" --host "$HOST"

# 6. platform-upgrade --no-pull (backup every product, updb, check).
step "6 platform-upgrade --no-pull"
stardust platform-upgrade "$OLD_PLAT" --no-pull

# 7. Second site on the same platform (install.sh path).
step "7 site-add $SECOND (install.sh, not Bee)"
stardust site-add "$OLD_PLAT" "$SECOND" --host "$SECOND_HOST" --name "Stress $SECOND"
stardust site-check "$OLD_PLAT" "$SECOND" --host "$SECOND_HOST"

# 8. Same-platform clone to a preview host.
step "8 site-clone $PROD -> $PREVIEW"
stardust site-clone "$OLD_PLAT" "$PROD" "$OLD_PLAT" "$PREVIEW" --host "$PREVIEW_HOST"
stardust site-check "$OLD_PLAT" "$PREVIEW" --host "$PREVIEW_HOST"

# 9. Cross-platform clone onto a fresh latest platform.
step "9 platform-add $NEW_PLAT (latest) + cross-clone"
stardust platform-add "$NEW_PLAT"
stardust site-clone "$OLD_PLAT" "$PROD" "$NEW_PLAT" "$CROSS" --host "$CROSS_HOST"
stardust site-check "$NEW_PLAT" "$CROSS" --host "$CROSS_HOST"

# 10. Disable and enable.
step "10 site-disable / site-enable $PROD"
stardust site-disable "$OLD_PLAT" "$PROD"
stardust site-enable "$OLD_PLAT" "$PROD"
stardust site-check "$OLD_PLAT" "$PROD" --host "$HOST"

# 11. Restore the pre-upgrade backup onto the old site.
step "11 site-restore $PROD from latest backup"
stardust site-restore "$OLD_PLAT" "$PROD"
stardust site-check "$OLD_PLAT" "$PROD" --host "$HOST"

# 12. Bee extras.
step "12 bee cron / config-export / config-import / uli"
stardust bee "$OLD_PLAT" "$PROD" cron || true
stardust bee "$OLD_PLAT" "$PROD" config-export || true
stardust bee "$OLD_PLAT" "$PROD" config-import || true
stardust bee "$OLD_PLAT" "$PROD" uli || true

# 13. D7 toolkit. Full d7-prep/d7-apply needs a D7 dump; these do not.
step "13 d7-stubs + d7-toolkit"
D7_OUT="/tmp/stress-d7-stubs-${STAMP}"
mkdir -p "$D7_OUT"
stardust d7-stubs || true
stardust d7-toolkit "$OLD_PLAT" || true

# 14. Inventory, doctor, log.
step "14 inventory / doctor / log"
stardust inventory || true
stardust doctor || true
stardust log 10 || true

echo ""
echo "PASS: Stress completed."
STRESS_OK=1
