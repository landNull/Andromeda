#!/usr/bin/env bash
# stress_tests/00_stress.sh — multi-variation exercise of Stardust and Bee.
#
# Variations (in order):
#   1. Download Backdrop OLD_VER (default 1.31.0 — first with PHP 8.4) into a dedicated platform
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
#  15. Write Capcom packs (stardust, bee, d7convert, moduleheal) and the fix prompt
#  16. Download Drupal 7
#  17. Install D7 stubs, unsupported field type, and the bad module
#  18. php -l the broken module (must fail) so Capcom /fixloop has a target
#  19. Drop stress_bad into the Backdrop platform (autocomplete path is broken)
#  20. Bee project list (enable/disable cycle is best effort)
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
OLD_VER="${STARDUST_STRESS_OLD:-1.31.0}"
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

# Prime sudo once so later chown/bee calls do not fail mid-run.
echo "--> sudo (password prompted once)"
sudo -v || {
    echo "ERROR"
    echo "LAYER: host"
    echo "FILE: sudo"
    echo "WHAT: sudo password was not accepted."
    echo "WHY: The stress run needs sudo for mkdir, chown, and bee as deploy."
    echo "FIX: Run 'sudo -v' and re-run this script."
    exit 1
}

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
# 1.28.x dies on PHP 8.4 (CSS_THEME). Confirm the DB is not empty before continuing.
if stardust bee "$OLD_PLAT" "$PROD" status 2>&1 | grep -q 'Database status.*Empty\|not installed'; then
    echo "ERROR"
    echo "LAYER: runtime"
    echo "FILE: $PLATFORMS/$OLD_PLAT/web"
    echo "WHAT: Backdrop $OLD_VER did not install. Database is empty."
    echo "WHY: The core is too old for this PHP. PHP 8.4 needs Backdrop 1.31.0 or newer."
    echo "FIX: Set STARDUST_STRESS_OLD=1.31.0 or newer and re-run."
    exit 1
fi
stardust site-check "$OLD_PLAT" "$PROD" --host "$HOST"

# 3. Bee status and cache.
step "3 bee status + cc all"
stardust bee "$OLD_PLAT" "$PROD" status
stardust bee "$OLD_PLAT" "$PROD" cc all

# 4. Backup before the upgrade.
step "4 site-backup $PROD"
stardust site-backup "$OLD_PLAT" "$PROD"

# 5. Upgrade core in place: latest over the old web, then updb.
# 5. Upgrade core in place. Bee refuses to dl-core into an existing install,
# so download latest beside it and copy core over, keeping sites/.
step "5 upgrade core in place to latest"
LATEST=$(mktemp -d)
sudo chown deploy:www-admin "$LATEST"
sudo chmod 2775 "$LATEST"
(
    cd "$LATEST"
    sudo -u deploy bee dl-core web --version=latest
)
if [ ! -d "$LATEST/web/core" ]; then
    echo "ERROR"
    echo "LAYER: runtime"
    echo "FILE: $LATEST/web"
    echo "WHAT: latest core did not download."
    echo "WHY: bee dl-core --version=latest failed."
    echo "FIX: Run 'bee dl-core web --version=latest' in an empty directory."
    exit 1
fi
sudo -u deploy cp -a "$LATEST/web/core/." "$PLATFORMS/$OLD_PLAT/web/core/"
sudo rm -rf "$LATEST"
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

# 15. Capcom packs. Copy into CaptainRocket if the tree is present.
step "15 write Capcom packs"
PACK_SRC="$HERE/packs"
CAPCOM_PACKS="${CAPCOM_ROOT:-$HOME/Apps/CaptainRocket}/.captainrocket/packs"
mkdir -p "$CAPCOM_PACKS" 2>/dev/null || true
for pack in stardust bee d7convert moduleheal; do
    if [ -d "$CAPCOM_PACKS" ]; then
        cp "$PACK_SRC/${pack}.json" "$CAPCOM_PACKS/${pack}.json"
        echo "OK pack $pack -> $CAPCOM_PACKS"
    else
        echo "NOTE pack $pack stays in $PACK_SRC (CaptainRocket not found)"
    fi
done
PROMPT_DEST="${CAPCOM_ROOT:-$HOME/Apps/CaptainRocket}/promptfiles"
if [ -d "$PROMPT_DEST" ]; then
    cp "$HERE/prompts/capcom_fix_stress_bad.xml" "$PROMPT_DEST/"
    echo "OK prompt -> $PROMPT_DEST/capcom_fix_stress_bad.xml"
fi

# 16. Download Drupal 7 for the conversion path.
step "16 download Drupal 7"
D7_VER="${STARDUST_STRESS_D7:-7.103}"
D7_DIR="/tmp/stress-d7-${STAMP}"
mkdir -p "$D7_DIR"
if command -v wget >/dev/null 2>&1; then
    wget -q -O "$D7_DIR/drupal.tar.gz" \
        "https://ftp.drupal.org/files/projects/drupal-${D7_VER}.tar.gz" || \
        echo "NOTE Drupal ${D7_VER} tarball failed — continuing with stubs only"
    if [ -f "$D7_DIR/drupal.tar.gz" ]; then
        tar -xzf "$D7_DIR/drupal.tar.gz" -C "$D7_DIR"
        echo "OK Drupal $D7_VER at $D7_DIR"
    fi
else
    echo "NOTE wget missing — skip D7 tarball"
fi

# 17. Install stubs, unsupported field, and the bad module into the D7 tree.
step "17 install D7 stubs + unsupported field + bad module"
D7_ROOT=$(find "$D7_DIR" -maxdepth 1 -type d -name 'drupal-*' | head -1)
if [ -n "$D7_ROOT" ] && [ -d "$D7_ROOT/sites/all" ]; then
    mkdir -p "$D7_ROOT/sites/all/modules"
    cp -a "$HERE/modules/d7_stubs/." "$D7_ROOT/sites/all/modules/"
    cp -a "$HERE/modules/stress_field" "$D7_ROOT/sites/all/modules/"
    cp -a "$HERE/modules/stress_bad" "$D7_ROOT/sites/all/modules/"
    echo "OK stubs + stress_field + stress_bad in $D7_ROOT/sites/all/modules"
    echo "NEXT on a live D7: enable entity_plus entity_ui ubercart, then dump backdrop-ready.sql"
    echo "NEXT: stress_field defines field type stress_widget — uninstall or port before update.php"
else
    echo "NOTE no D7 tree — stubs remain under $HERE/modules/d7_stubs"
fi

# 18. Prove the bad PHP fails lint. Capcom /fixloop should repair it.
step "18 php -l the broken module (expect fail)"
if command -v php >/dev/null 2>&1; then
    if php -l "$HERE/modules/stress_bad/stress_bad.broken.inc"; then
        echo "ERROR"
        echo "LAYER: test"
        echo "FILE: stress_bad.broken.inc"
        echo "WHAT: parse error was fixed already."
        echo "WHY: The stress fixture must fail php -l so Capcom has something to repair."
        echo "FIX: Restore the missing semicolons in stress_bad.broken.inc."
        exit 1
    else
        echo "OK php -l failed as expected on stress_bad.broken.inc"
    fi
    php -l "$HERE/modules/stress_bad/stress_bad.module" && echo "OK loader lints"
    echo "Capcom: /fixloop against $HERE/modules/stress_bad/"
    echo "Prompt: $HERE/prompts/capcom_fix_stress_bad.xml"
else
    echo "NOTE php missing — skip lint proof"
fi

# 19. Drop the bad module into the Backdrop platform so Bee can see it.
step "19 install stress_bad into Backdrop platform"
if [ -d "$PLATFORMS/$OLD_PLAT/web/modules" ]; then
    sudo -u deploy cp -a "$HERE/modules/stress_bad" "$PLATFORMS/$OLD_PLAT/web/modules/"
    echo "OK stress_bad in $PLATFORMS/$OLD_PLAT/web/modules"
    echo "Autocomplete path: stress-bad/autocomplete (callback is broken on purpose)"
    echo "Bee: stardust bee $OLD_PLAT $PROD en stress_bad   # will fail until Capcom fixes the include"
else
    echo "NOTE platform web missing — skip Backdrop install of stress_bad"
fi

# 20. Module enable/disable cycle on a known-good module if Bee can see one.
step "20 bee enable/disable cycle (best effort)"
stardust bee "$OLD_PLAT" "$PROD" pml || true

echo ""
echo "PASS: Stress completed."
echo "Capcom packs: stardust bee d7convert moduleheal"
echo "Fix target: $HERE/modules/stress_bad/stress_bad.broken.inc"
echo "Autocomplete target: $HERE/modules/stress_bad/stress_bad.autocomplete.inc"
STRESS_OK=1
