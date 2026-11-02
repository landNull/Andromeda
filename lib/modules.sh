# shellcheck shell=sh
# Module reconcile. Works for every module, including core.
# An enabled module whose code is not on disk is disabled in
# system.extensions.json so bootstrap and cache clear can finish.
# system is never disabled.

# module_on_disk WEB NAME
# True when NAME.module or NAME.info exists under core, modules, or sites.
module_on_disk() {
  web=$1
  name=$2
  found=$(find "$web/core/modules" "$web/modules" "$web/sites" \
    -path "*/${name}/${name}.module" -o -path "*/${name}/${name}.info" \
    2>/dev/null | head -n 1)
  [ -n "$found" ]
}

# disable_module_in_config ACTIVE NAME
# Sets modules.NAME to false in system.extensions.json. Never touches system.
disable_module_in_config() {
  active=$1
  name=$2
  file=$active/system.extensions.json
  [ "$name" = "system" ] && return 1
  [ -f "$file" ] || return 1
  python3 - "$file" "$name" << 'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
if name == "system":
    sys.exit(1)
with open(path) as f:
    data = json.load(f)
mods = data.get("modules") or {}
if name not in mods:
    sys.exit(1)
mods[name] = False
data["modules"] = mods
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(name)
PY
}

# reconcile_modules WEB ACTIVE
# Disables every enabled module whose code is missing. Prints each name.
reconcile_modules() {
  web=$1
  active=$2
  file=$active/system.extensions.json
  if [ ! -f "$file" ]; then
    echo "modules  no system.extensions.json — skip"
    return 0
  fi
  missing=$(python3 - "$file" "$web" << 'PY'
import json, os, sys
path, web = sys.argv[1], sys.argv[2]
keep = {"system"}
with open(path) as f:
    data = json.load(f)
mods = data.get("modules") or {}
disabled = []
roots = [
    os.path.join(web, "core", "modules"),
    os.path.join(web, "modules"),
    os.path.join(web, "sites"),
]
def on_disk(name):
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if os.path.basename(dirpath) != name:
                continue
            if f"{name}.module" in filenames or f"{name}.info" in filenames:
                return True
    return False
for name, on in list(mods.items()):
    if not on or name in keep:
        continue
    if not on_disk(name):
        mods[name] = False
        disabled.append(name)
if disabled:
    data["modules"] = mods
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
print(" ".join(disabled))
PY
)
  if [ -n "$missing" ]; then
    echo "modules  disabled (code missing): $missing"
  else
    echo "modules  all enabled modules are on disk"
  fi
}

# cache_clear_safe WEB PRODUCT ACTIVE
# Runs bee cc all. On a missing class or a fatal in a module file, disables
# that module and retries once. Covers contrib and core.
cache_clear_safe() {
  web=$1
  product=$2
  active=$3
  log=$(mktemp)
  if bee_site_cmd "$web" "$product" cc all >"$log" 2>&1; then
    cat "$log"
    rm -f "$log"
    return 0
  fi
  cat "$log" >&2
  # Path in the error names the module: .../modules/NAME/... or .../core/modules/NAME/...
  mod=$(grep -oE '(core/modules|modules|sites/[^/]+/modules)/[A-Za-z0-9_]+/' "$log" | head -n 1 | awk -F/ '{print $(NF-1)}')
  if [ -z "$mod" ]; then
    mod=$(grep -oE 'Class [A-Za-z0-9_]+ does not exist' "$log" | head -n 1 | awk '{print $2}')
  fi
  rm -f "$log"
  if [ -z "$mod" ] || [ "$mod" = "system" ]; then
    echo "modules  cache clear failed — no module to disable" >&2
    return 1
  fi
  echo "modules  cache clear failed in $mod — disabling and retrying"
  disable_module_in_config "$active" "$mod" || return 1
  bee_site_cmd "$web" "$product" cc all
}
