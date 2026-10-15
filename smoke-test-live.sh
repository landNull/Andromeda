#!/bin/sh
# smoke-test-live.sh — automated product demo of Stardust.
#
# Creates a real platform and sites, then exercises every verb Stardust
# can run against them. Prints a clear narrative to the screen.
#
# On success writes  passed.YYYYMMDD-HHMMSS.log   (readable story)
# On failure writes  smoketest.error.YYYYMMDD-HHMMSS.log
#
# Cleanup is NOT automatic. Pass --delete yourself if you want the
# demo sites removed at the end.
#
# Usage (as the operator login — never under sudo):
#   ./smoke-test-live.sh
#   ./smoke-test-live.sh --platform demo --product www --host www.devel
#   ./smoke-test-live.sh --delete
#   ./smoke-test-live.sh --dry-run          # preview only, creates nothing
#
# Exit 0 on full success, 1 on any failure.

set -eu

PROG=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STARDUST=${STARDUST_BIN:-$HERE/bin/stardust}
[ -x "$STARDUST" ] || STARDUST=$(command -v stardust 2>/dev/null || true)
if [ -z "${STARDUST:-}" ] || [ ! -x "$STARDUST" ]; then
  echo "$PROG: cannot find stardust binary" >&2
  exit 1
fi

PLATFORM=""
PRODUCT=""
HOST=""
GIT_URL=""
DELETE=0
DRYRUN=0
STAMP=$(date +%Y%m%d-%H%M%S)
PASSED_LOG="passed.${STAMP}.log"
ERROR_LOG="smoketest.error.${STAMP}.log"
STORY=$(mktemp /tmp/stardust-demo-story.XXXXXX)
trap 'rm -f "$STORY"' EXIT

while [ $# -gt 0 ]; do
  case $1 in
    --platform) PLATFORM=$2; shift 2 ;;
    --product)  PRODUCT=$2;  shift 2 ;;
    --host)     HOST=$2;     shift 2 ;;
    --git)      GIT_URL=$2;  shift 2 ;;
    --delete)   DELETE=1;    shift ;;
    --dry-run)  DRYRUN=1;    shift ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) echo "$PROG: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [ -n "${SUDO_USER:-}" ] || [ "$(id -u)" -eq 0 ]; then
  echo "$PROG: do not run this with sudo or as root." >&2
  echo "$PROG: log in as the operator account and re-run." >&2
  exit 2
fi

# --- narrative helpers ----------------------------------------------------
say() {
  printf '%s\n' "$*" | tee -a "$STORY"
}

section() {
  printf '\n══════════════════════════════════════════════════════════════\n' | tee -a "$STORY"
  printf '  %s\n' "$1" | tee -a "$STORY"
  printf '══════════════════════════════════════════════════════════════\n' | tee -a "$STORY"
}

explain() {
  printf '\n%s\n' "$1" | tee -a "$STORY"
}

demo_run() {
  # demo_run "description" cmd arg arg ...
  desc=$1; shift
  printf '\n→ %s\n' "$desc" | tee -a "$STORY"
  printf '$ %s\n' "$*" | tee -a "$STORY"
  tmp=$(mktemp)
  set +e
  "$@" >"$tmp" 2>&1
  rc=$?
  set -e
  cat "$tmp" | tee -a "$STORY"
  rm -f "$tmp"
  if [ "$rc" -eq 0 ]; then
    printf '  ✓ %s\n' "$desc" | tee -a "$STORY"
    return 0
  fi
  printf '  ✗ %s (exit %s)\n' "$desc" "$rc" | tee -a "$STORY"
  # write error story and stop
  {
    echo "Stardust product demo FAILED at: $desc"
    echo "Timestamp: $STAMP"
    echo "Exit code: $rc"
    echo
    cat "$STORY"
  } > "$ERROR_LOG"
  echo
  echo "Demo stopped. Error story written to: $ERROR_LOG"
  exit 1
}

demo_run_ok_any() {
  # demo_run_ok_any "0|1|2" "description" cmd ...
  # used for commands that are expected to refuse (e.g. promote on devel)
  allowed=$1; shift
  desc=$1; shift
  printf '\n→ %s\n' "$desc" | tee -a "$STORY"
  printf '$ %s\n' "$*" | tee -a "$STORY"
  tmp=$(mktemp)
  set +e
  "$@" >"$tmp" 2>&1
  rc=$?
  set -e
  cat "$tmp" | tee -a "$STORY"
  rm -f "$tmp"
  case "|${allowed}|" in
    *"|${rc}|"*)
      printf '  ✓ %s (exit %s, expected)\n' "$desc" "$rc" | tee -a "$STORY"
      return 0
      ;;
  esac
  printf '  ✗ %s (got %s, allowed %s)\n' "$desc" "$rc" "$allowed" | tee -a "$STORY"
  {
    echo "Stardust product demo FAILED at: $desc"
    echo "Timestamp: $STAMP"
    echo "Exit code: $rc (allowed $allowed)"
    echo
    cat "$STORY"
  } > "$ERROR_LOG"
  echo
  echo "Demo stopped. Error story written to: $ERROR_LOG"
  exit 1
}

prompt() {
  var=$1; q=$2; def=${3:-}
  if [ -n "$def" ]; then
    printf '%s [%s]: ' "$q" "$def" >&2
  else
    printf '%s: ' "$q" >&2
  fi
  read -r ans </dev/tty || ans=""
  [ -z "$ans" ] && ans=$def
  eval "$var=\$ans"
}

confirm() {
  printf '%s [y/N]: ' "$1" >&2
  read -r ans </dev/tty || ans=""
  case $ans in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- gather parameters ----------------------------------------------------
section "Stardust product demo — setup"

role=$(grep -E '^STARDUST_ROLE=' /etc/stardust.conf 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
role=${role:-${STARDUST_ROLE:-devel}}
explain "This is an automated product demo of Stardust, the shell control plane for Backdrop CMS.
It will create a real platform and sites on this host (role=$role), then run every
operation Stardust can perform on them. Everything is printed here so you can
follow along. A readable story log is written at the end."

if [ -z "$PLATFORM" ]; then
  prompt PLATFORM "Platform name to create" "demo"
fi
if [ -z "$PRODUCT" ]; then
  prompt PRODUCT "First product (site) name" "www"
fi
if [ -z "$HOST" ]; then
  prompt HOST "Hostname for the first site" "${PRODUCT}.${role}"
fi
COPY_PRODUCT="${PRODUCT}-copy"
COPY_HOST="${COPY_PRODUCT}.${role}"

if [ -z "$GIT_URL" ]; then
  if confirm "Clone the platform from a Git URL? (no = bee dl-core or template)"; then
    prompt GIT_URL "Git URL"
  fi
fi

explain "Demo will use:
  platform : $PLATFORM
  product  : $PRODUCT
  host     : $HOST
  clone to : $COPY_PRODUCT ($COPY_HOST)
  role     : $role
  delete   : $([ $DELETE -eq 1 ] && echo yes || echo no — pass --delete to remove sites at the end)
  dry-run  : $([ $DRYRUN -eq 1 ] && echo yes || echo no)"

if [ "$DRYRUN" -eq 0 ]; then
  if ! confirm "Create real platform and sites now?"; then
    echo "Aborted."
    exit 1
  fi
fi

# --- preflight ------------------------------------------------------------
section "Preflight — groups, sudo, doctor"

explain "Stardust refuses to run under sudo. Root work goes through stardust-priv.
The operator must be in groups www-admin and stardust. We cache sudo credentials
now so later privileged steps do not interrupt the demo."

if id -nG | grep -qw www-admin && id -nG | grep -qw stardust; then
  say "  ✓ operator is in www-admin and stardust"
else
  say "  ✗ missing required groups. Fix with:"
  say "    sudo usermod -aG www-admin,stardust \$USER && exec su - \$USER"
  {
    echo "Preflight failed: missing groups"
    cat "$STORY"
  } > "$ERROR_LOG"
  echo "Error story: $ERROR_LOG"
  exit 1
fi

if sudo -n true 2>/dev/null; then
  say "  ✓ sudo already available"
else
  explain "Please enter your sudo password to cache credentials for this demo:"
  if sudo -v; then
    say "  ✓ sudo credentials cached"
  else
    say "  ✗ could not cache sudo"
    { echo "sudo failed"; cat "$STORY"; } > "$ERROR_LOG"
    exit 1
  fi
fi

if [ "$DRYRUN" -eq 1 ]; then
  STARDUST_CMD="$STARDUST -n"
else
  STARDUST_CMD="$STARDUST"
fi

demo_run "Show help (same text as man page EXAMPLES)" $STARDUST help
demo_run "Check that this box is ready (doctor)" $STARDUST doctor
demo_run "Show loaded configuration (env)" $STARDUST env
demo_run "List existing platforms and products" $STARDUST list

# --- create platform ------------------------------------------------------
section "Create the platform"

explain "A platform is one Backdrop codebase under /srv/platforms/NAME.
platform-add creates the directory, optionally clones from Git, or uses
bee dl-core to download a fresh Backdrop tree. If the directory already
exists it is left alone."

if [ -n "$GIT_URL" ]; then
  demo_run "Create platform $PLATFORM from Git" \
    $STARDUST_CMD platform-add "$PLATFORM" --git "$GIT_URL" --branch "$role" --no-prompt
else
  demo_run "Create platform $PLATFORM (bee dl-core or template)" \
    $STARDUST_CMD platform-add "$PLATFORM" --branch "$role" --no-prompt
fi

demo_run "List platforms again — the new one should appear" $STARDUST list

# --- create first site ----------------------------------------------------
section "Add the first product (site)"

explain "A product (site) lives inside a platform. site-add creates the
files/config directories with crdir, writes settings.php and sites.php,
creates the MariaDB database and user, runs bee install, and writes the
Apache vhost. The hostname you chose is what Apache and Backdrop will answer."

demo_run "Add product $PRODUCT with host $HOST" \
  $STARDUST_CMD site-add "$PLATFORM" "$PRODUCT" --host "$HOST" --name "Demo $PRODUCT"

demo_run "Check the new site responds" \
  $STARDUST_CMD site-check "$PLATFORM" "$PRODUCT" --host "$HOST"

# --- day-to-day operations ------------------------------------------------
section "Day-to-day operations on the site"

explain "Once a site exists, content and config still go through Bee.
Stardust provides a thin wrapper that sets --root and --site for you.
We also take a backup, toggle maintenance mode, and clone the site."

demo_run "Bee status via the stardust wrapper" \
  $STARDUST_CMD bee "$PLATFORM" "$PRODUCT" status

demo_run "Bee cache clear (cc all)" \
  $STARDUST_CMD bee "$PLATFORM" "$PRODUCT" cc all

demo_run "Backup the site (files + database)" \
  $STARDUST_CMD site-backup "$PLATFORM" "$PRODUCT"

demo_run "Put the site into maintenance mode" \
  $STARDUST_CMD site-disable "$PLATFORM" "$PRODUCT"

demo_run "Bring the site back online" \
  $STARDUST_CMD site-enable "$PLATFORM" "$PRODUCT"

demo_run "Clone the site to $COPY_PRODUCT" \
  $STARDUST_CMD site-clone "$PLATFORM" "$PRODUCT" "$PLATFORM" "$COPY_PRODUCT" --host "$COPY_HOST"

demo_run "Check the cloned site" \
  $STARDUST_CMD site-check "$PLATFORM" "$COPY_PRODUCT" --host "$COPY_HOST"

demo_run "Restore the original site from its latest backup" \
  $STARDUST_CMD site-restore "$PLATFORM" "$PRODUCT"

# --- platform-level operations --------------------------------------------
section "Platform-level operations"

explain "platform-upgrade pulls the latest code (if this is a Git checkout)
and runs Bee updates on every product after backing them up.
backup-all and cron-all operate on every product on the box.
promote is only allowed on test/live hosts — on devel it refuses."

demo_run "Upgrade the platform (backup first, then Bee updates)" \
  $STARDUST_CMD platform-upgrade "$PLATFORM" --no-pull

demo_run "Backup every product on the box" \
  $STARDUST_CMD backup-all

demo_run "Run Bee cron on every product" \
  $STARDUST_CMD cron-all

demo_run_ok_any "0|1|2" "Try promote to test (refused on devel — that is correct)" \
  $STARDUST -n promote "$PLATFORM" --to test

# --- inventory and journal ------------------------------------------------
section "Inventory and task journal"

explain "inventory walks the platforms and prints a summary.
log and last show the task journal that mutating commands write
under /srv/stardust/state."

demo_run "Show inventory" $STARDUST inventory
demo_run "Show recent task log" $STARDUST log 10
demo_run "Show the last task" $STARDUST last
demo_run "List platforms and products one more time" $STARDUST list

# --- d7 surface (no real D7 tree required) --------------------------------
section "Drupal 7 / BOA importer surface"

explain "The d7 verb is the portable Drupal 7 / BOA importer.
We only exercise the help and tools listings here — a real migration
needs a D7 site path. See man d7-migrate for the full workflow."

demo_run "Show d7 help" $STARDUST d7 help
demo_run "List d7 tools" $STARDUST d7 tools

# --- optional delete ------------------------------------------------------
section "Cleanup"

if [ "$DELETE" -eq 1 ] && [ "$DRYRUN" -eq 0 ]; then
  explain "You passed --delete. Removing the demo sites.
  site-delete backs up first, drops the database and user, and removes
  the product directories. The platform directory itself is left in place
  (there is no platform-delete verb yet)."
  demo_run "Delete product $COPY_PRODUCT" \
    $STARDUST site-delete "$PLATFORM" "$COPY_PRODUCT" --force
  demo_run "Delete product $PRODUCT" \
    $STARDUST site-delete "$PLATFORM" "$PRODUCT" --force
  say "Platform directory /srv/platforms/$PLATFORM was left in place."
elif [ "$DELETE" -eq 1 ] && [ "$DRYRUN" -eq 1 ]; then
  explain "Dry-run mode: showing what --delete would do."
  demo_run "Dry-run delete $COPY_PRODUCT" \
    $STARDUST -n site-delete "$PLATFORM" "$COPY_PRODUCT" --force
  demo_run "Dry-run delete $PRODUCT" \
    $STARDUST -n site-delete "$PLATFORM" "$PRODUCT" --force
else
  explain "Sites were left in place so you can inspect them.
  To remove them later, re-run with --delete or run:
    stardust site-delete $PLATFORM $COPY_PRODUCT --force
    stardust site-delete $PLATFORM $PRODUCT --force"
fi

# --- success story --------------------------------------------------------
section "Demo complete"

explain "All steps finished successfully.
The full narrative has been saved to $PASSED_LOG"

{
  echo "Stardust product demo — PASSED"
  echo "Timestamp : $STAMP"
  echo "Host role : $role"
  echo "Platform  : $PLATFORM"
  echo "Products  : $PRODUCT  $COPY_PRODUCT"
  echo "Host      : $HOST"
  echo "Delete    : $([ $DELETE -eq 1 ] && echo yes || echo no)"
  echo
  echo "This log is the story of the demo, in the order the steps ran."
  echo
  cat "$STORY"
} > "$PASSED_LOG"

echo
echo "Success story written to: $PASSED_LOG"
exit 0
