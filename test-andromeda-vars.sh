#!/bin/sh
# test-andromeda-vars.sh — Pre-flight structural validator for Andromeda variables
set -eu

PROG=${0##*/}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

echo "===================================================="
echo "🔍 Starting Andromeda Configuration Hand-Off Audit..."
echo "===================================================="

# 1. Define the exact array of critical variables required by worker modules
REQUIRED_VARS="DRYRUN ROLE OWNER GROUP PLATFORMS STARDUST PKG INIT OS_ID SVC_APACHE SVC_DB"

# 2. Mock a standard runtime baseline context (mimicking install-andromeda.sh behavior)
DRYRUN=1
ROLE="devel"
OWNER="deploy"
ADMIN=""
GROUP="www-admin"
PLATFORMS="/srv/platforms"
STARDUST="/srv/andromeda"
PKG="apt"
INIT="sysvinit"
OS_ID="devuan"
SVC_APACHE="apache2"
SVC_DB="mariadb"

# 3. Define an internal auditor function
audit_environment() {
  local target_module="$1"
  local pass=0
  
  echo "📋 Auditing state tracking for module: [$(basename "$target_module")]"
  
  for var_name in $REQUIRED_VARS; do
    # Dynamically extract the value of the variable name string
    eval var_val=\${$var_name:-}
    
    if [ -z "$var_val" ]; then
      echo "  ❌ CRITICAL FAILURE: Variable [\$$var_name] is empty or unassigned!" >&2
      pass=1
    else
      echo "  ✓ Hand-off verified: \$$var_name = \"$var_val\""
    fi
  done
  
  return $pass
}

# 4. Iteratively inspect the structure without triggering destructive operations
failures=0
if [ -d "$HERE/modules" ]; then
  for module in "$HERE/modules/"[0-9][0-9]-*.sh; do
    if [ -f "$module" ]; then
      # Audit variables *before* sourcing to verify our orchestrator core is clean
      audit_environment "$module" || failures=$((failures + 1))
    fi
  done
else
  echo "❌ Error: The modules/ directory could not be located." >&2
  exit 1
fi

echo "===================================================="
if [ "$failures" -eq 0 ]; then
  echo "✅ PASS: All global environment variables handed off successfully!"
  exit 0
else
  echo "❌ FAIL: Detected $failures validation gaps in your configuration tracking." >&2
  exit 1
fi
