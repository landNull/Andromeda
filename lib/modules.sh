# shellcheck shell=sh
# Module preflight. Production gate, not a silent disable.
# Backdrop boots from system.extensions.json plus the system table.
# An enabled module must have its code on disk and its .info
# dependencies present and enabled. If either fails, stop and report.
# Never disable a module to make the pull look successful.

# module_preflight WEB ACTIVE
# Returns 1 and prints a report when the site cannot boot cleanly.
module_preflight() {
  web=$1
  active=$2
  file=$active/system.extensions.json
  report=$active/../module-preflight.txt
  if [ ! -f "$file" ]; then
    echo "modules  no system.extensions.json — cannot verify" >&2
    return 1
  fi
  python3 - "$file" "$web" "$report" << 'PY'
import json, os, sys
path, web, report = sys.argv[1], sys.argv[2], sys.argv[3]
keep_required = {"system"}
with open(path) as f:
    data = json.load(f)
mods = data.get("modules") or {}
enabled = sorted(n for n, on in mods.items() if on)

roots = [
    os.path.join(web, "core", "modules"),
    os.path.join(web, "modules"),
    os.path.join(web, "sites"),
    os.path.join(web, "core", "profiles"),
    os.path.join(web, "profiles"),
]
# system is required. It is not listed as a toggle in system.extensions.
always = {"system"}

def find_dir(name):
    # A module is NAME/NAME.module, or NAME.module loose in another
    # directory (Ubercart keeps test_gateway.module in tests/).
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if f"{name}.module" in filenames or f"{name}.info" in filenames:
                return dirpath
    return None

def deps_of(name, dirpath):
    info = os.path.join(dirpath, f"{name}.info")
    out = []
    if not os.path.isfile(info):
        return out
    for line in open(info, errors="replace"):
        line = line.strip()
        if not line.startswith("dependencies[]"):
            continue
        # dependencies[] = ubercart
        val = line.split("=", 1)[-1].strip().strip('"').strip("'")
        # Backdrop allows dependencies[] = module (>=1.0)
        val = val.split()[0] if val else ""
        if val:
            out.append(val)
    return out

missing_code = []
missing_deps = []
ok = []
for name in enabled:
    if name in always:
        ok.append(name)
        continue
    d = find_dir(name)
    if not d:
        missing_code.append(name)
        continue
    ok.append(name)
    for dep in deps_of(name, d):
        if dep in always:
            continue
        if dep not in mods or not mods.get(dep):
            missing_deps.append(f"{name} needs {dep} (not enabled)")
        elif not find_dir(dep):
            missing_deps.append(f"{name} needs {dep} (code missing)")

lines = []
lines.append(f"enabled {len(enabled)}")
lines.append(f"on disk {len(ok)}")
if missing_code:
    lines.append("FAIL code missing:")
    lines.extend(f"  {n}" for n in missing_code)
if missing_deps:
    lines.append("FAIL dependencies:")
    lines.extend(f"  {n}" for n in missing_deps)
if not missing_code and not missing_deps:
    lines.append("ok all enabled modules are on disk and dependencies are met")
text = "\n".join(lines) + "\n"
os.makedirs(os.path.dirname(report), exist_ok=True)
with open(report, "w") as f:
    f.write(text)
print(text, end="")
sys.exit(1 if missing_code or missing_deps else 0)
PY
}

# cache_clear_report WEB PRODUCT ACTIVE
# Runs bee cc all. On failure, writes which module and class broke it.
# Does not disable anything. Returns 1 so the pull stops.
cache_clear_report() {
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
  mod=$(grep -oE '(core/modules|modules|sites/[^/]+/modules)/[A-Za-z0-9_]+/' "$log" | head -n 1 | awk -F/ '{print $(NF-1)}')
  cls=$(grep -oE 'Class [A-Za-z0-9_]+ does not exist' "$log" | head -n 1 | awk '{print $2}')
  report=$active/../module-preflight.txt
  {
    echo "FAIL cache clear"
    [ -n "$mod" ] && echo "  module $mod"
    [ -n "$cls" ] && echo "  class  $cls"
    echo "  the module was not disabled. Fix the code or the dependency, then pull again."
  } | tee -a "$report" >&2
  rm -f "$log"
  return 1
}
