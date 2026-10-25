# Current app map (devel, 2026-09-20)

Host install order is `apps/MANIFEST`, not filename sort.

| App | Host phase | Runtime |
|-----|------------|---------|
| core | — | `lib/common.sh` |
| host | `apps/host/install.sh` | `bin/andromeda`, `bin/andromeda-priv`, `bin/crdir` |
| apache | `apps/apache/install.sh` | Apache vhosts via site-add |
| php | `apps/php/install.sh` | 30-andromeda.ini / FPM harden / CLI |
| security | `apps/security/install.sh` | extras, VPS sysctl, CSF `-F` |
| mariadb | `apps/mariadb/install.sh` | `bd_*` via andromeda-priv |
| deploy | `apps/deploy/install.sh` | ship tools, cron, state |
| bee | `apps/bee/install.sh` | `apps/bee/lib.sh` → `andromeda bee` |
| gitea | `apps/gitea/install.sh` | optional binary + app.ini (absent only) + git template |
| platform | — | `lib/platform.sh` `lib/promote.sh` |
| site | — | `lib/site.sh` backup clone check ops |
| doctor | — | `lib/doctor.sh` |
| migrate-d7 | — | `lib/d7.sh` `bin/d7-migrate` |
| ui | — | `bin/andromeda-menu` `tui/` |

Paths and contract are unchanged: `/srv/platforms`, `/srv/andromeda`, `bd_*`,
`andromeda-priv`, ff-only promote, refuse sudo on user binaries.

---

# Andromeda Control Plane: App-Centric Architecture & Git Guide

This document captures the complete architectural blueprint, step-by-step refactoring guidelines, safe deployment procedures, and version control procedures engineered to transition the Andromeda automation platform from a legacy monolithic script into an industry-standard, **App-Centric Module system**.

---

## 🗺️ Architectural Structural Map

In modern systems automation, code architecture dictates repository architecture. A monolith relies on rigid top-to-bottom linear execution within a single, brittle file. An App-Centric system uses an **Orchestrator Core** that dynamically scans, inherits global configuration tokens, and sources **Isolated, Single-Responsibility App Workers**.

```
[ GitHub Remote Repository: github.com/landNull/Andromeda.git ]
  └── devel Branch (Your Main Integration Stream — Current Stable Codebase)
        └── feature/modularize-installer (Your Isolated Testing Sandbox)
              │
              ├── [ The Orchestrator ] install-andromeda.sh (Manages global variables & loop)
              │     │
              │     └───► Iterates sequentially matching: modules/[0-9][0-9]-*.sh
              │
              ├── [ The Validator ] test-andromeda-vars.sh (Audits variable hand-offs)
              │
              ├── [ The Purger ] cleanup-andromeda.sh (Unprompted reverse tear-down engine)
              │
              └── [ The App Workers ] modules/
                    ├── 10-core-prereqs.sh  (Prerequisites, system users, groups, sudo privileges)
                    ├── 20-apache2.sh       (Apache2 installation, mpm_event tweaks, hardening)
                    ├── 30-php.sh           (PHP-FPM, memory limits, opcache tuning, SAPIs)
                    ├── 40-mariadb.sh       (MariaDB server, InnoDB buffers, secure socket binding)
                    ├── 50-bee.sh           (Backdrop CMS Bee CLI download & Composer compilation)
                    └── 60-gitea.sh         (Gitea binary automation & daemon configuration)
```

---

## 🏷️ Operational Naming Conventions

* **`install-andromeda.sh`**: Changed from a passive noun (`andromeda-installer.sh`) to an action-oriented verb prefix (`install-andromeda`). This instantly clarifies intent and matches traditional platform conventions.
* **Numeric Sequence Prefixes (`10-`, `20-`, `30-`)**: Order of execution is non-negotiable in shell infrastructure automation. You cannot optimize an InnoDB buffer pool (`40-mariadb.sh`) before the package manager installs the database binary. By assigning two-digit sequence numbers, the operating system's native alphabetical file sorting layout handles the execution stack automatically, mirroring native patterns like `/etc/sysctl.d/` or `/etc/sudoers.d/`.
* **Branch Categorization (`feature/modularize-installer`)**: Forward-slash prefixes act as functional visual anchors. They signal context clearly to dashboards, team reviewers, and automated CI pipelines before a single line of code is inspected.

---

## 🛠️ Core Control Scripts

### 1. The Central Orchestrator (`install-andromeda.sh`)
This file establishes constants, auto-detects package managers (`apt`, `apk`, `dnf`, `yum`) and init suites (`systemd`, `sysvinit`, `openrc`), and drives the main module loading loop.

```sh
#!/bin/sh
# install-andromeda.sh — Modular orchestrator control engine for Andromeda
set -eu

PROG=${0##*/}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STARDUST_VERSION=0.4.0

if [ -f "$HERE/VERSION" ]; then
  STARDUST_VERSION=$(tr -d ' 
' < "$HERE/VERSION")
fi
if [ -d "$HERE/bin" ] && [ -d "$HERE/lib" ]; then
  BINDIR=$HERE/bin; LIBSRC=$HERE/lib; MANDIR=$HERE/man; TUIDIR=$HERE/tui
else
  BINDIR=$HERE; LIBSRC=$HERE/andromeda-lib; MANDIR=$HERE; TUIDIR=$HERE/andromeda-tui
fi

export DRYRUN=0; export DO_CSF=0; export LOCALHOST=0; export ROLE=devel
export OWNER="${OWNER:-deploy}"; export ADMIN="${ADMIN:-www-admin}"; export GROUP="${GROUP:-www-admin}"
HUMAN=""; DAEMON=""; PLATFORMS=/srv/platforms; export STARDUST=/srv/andromeda
CSF_ALLOW="10.8.0.0/24 192.168.1.0/24"; BEE_SRC=https://github.com/backdrop-contrib/bee.git
BEE_DST=/usr/local/src/bee; BEE_BIN=/usr/local/bin/bee

export PKG=unknown; export INIT=unknown; export OS_ID=unknown; export SVC_APACHE=""
export SVC_DB=""; export RELOAD_APACHE=""

as_root() { if [ "$(id -u)" -ne 0 ]; then sudo "$@"; else "$@"; fi }

run_root() {
  if [ "$DRYRUN" -eq 1 ]; then
    printf '+'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; return 0
  fi
  cmd_summary="$1"
  [ -n "${2:-}" ] && cmd_summary="$cmd_summary $2"
  printf "  \\033[33m⏳ Processing:\\033[0m [%s] ...                     \r" "$cmd_summary"
  as_root "$@"
  cmd_status=$?
  if [ $cmd_status -eq 0 ]; then
    printf "  \\033[32m✓\\033[0m Completed: [%s]                               \n" "$cmd_summary"
  else
    printf "  \\033[31m✗\\033[0m Failed (%s): [%s]                             \n" "$cmd_status" "$cmd_summary"
    return $cmd_status
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }
normalize_role() {
  case $1 in
    devel|localhost|dev) echo devel ;;
    test|vps-test) echo test ;;
    live|vps-live|prod|production) echo live ;;
    *) echo "" ;;
  esac
}

detect_os() {
  [ -f /etc/os-release ] && OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
  if have apt-get && have dpkg; then PKG=apt
  elif have apk; then PKG=apk
  elif have dnf; then PKG=dnf
  elif have yum; then PKG=yum
  else PKG=unknown; fi
}

detect_init() {
  if [ -d /run/systemd/system ] && have systemctl; then INIT=systemd
  elif [ -d /etc/init.d ] && [ ! -d /run/systemd/system ]; then INIT=sysv
  elif have rc-service; then INIT=openrc
  elif [ -x /etc/init.d/apache2 ] || [ -x /etc/init.d/httpd ]; then INIT=sysv
  elif have systemctl; then INIT=systemd
  else INIT=unknown; fi
}

detect_group() {
  if [ -z "$DAEMON" ]; then
    if getent passwd www-data >/dev/null 2>&1; then DAEMON=www-data
    elif getent passwd apache >/dev/null 2>&1; then DAEMON=apache
    else DAEMON=www-data; fi
  fi
}

detect_services() {
  if [ -x /etc/init.d/apache2 ] || [ -d /etc/apache2 ]; then SVC_APACHE=apache2
  elif [ -x /etc/init.d/httpd ] || [ -d /etc/httpd ]; then SVC_APACHE=httpd
  else SVC_APACHE=apache2; fi
  if [ -x /etc/init.d/mysql ] || have mysql; then SVC_DB=mysql
  elif [ -x /etc/init.d/mariadb ]; then SVC_DB=mariadb
  else SVC_DB=mysql; fi
  case $INIT in
    systemd) RELOAD_APACHE="systemctl reload $SVC_APACHE" ;;
    openrc) RELOAD_APACHE="rc-service $SVC_APACHE reload" ;;
    sysv|unknown) RELOAD_APACHE="/etc/init.d/$SVC_APACHE reload" ;;
  esac
}

pkg_ok() {
  case $PKG in
    apt) dpkg-query -W -f='\${Status}' "\$1" 2>/dev/null | grep -q 'install ok installed' ;;
    apk) apk info -e "\$1" >/dev/null 2>&1 ;;
    dnf|yum) rpm -q "\$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pkg_install() {
  case $PKG in
    apt) run_root apt-get update && run_root apt-get install -y "\$@" ;;
    apk) run_root apk add --no-cache "\$@" ;;
    dnf) run_root dnf install -y "\$@" ;;
    yum) run_root yum install -y "\$@" ;;
    *) echo "\$PROG: no package manager detected" >&2; return 1 ;;
  esac
}

svc_start() {
  name=\$1
  case \$INIT in
    systemd) run_root systemctl enable "\$name" 2>/dev/null || true; run_root systemctl start "\$name" || true ;;
    openrc) run_root rc-update add "\$name" default 2>/dev/null || true; run_root rc-service "\$name" start || true ;;
    sysv|unknown) [ -x "/etc/init.d/\$name" ] && run_root "/etc/init.d/\$name" start || true ;;
  esac
}

write_dropin() {
  dest=\$1
  [ "\$DRYRUN" -eq 1 ] && echo "+ write \$dest" && return 0
  as_root mkdir -p "\$(dirname "\$dest")"
  tmp=\$(mktemp)
  cat > "\$tmp"
  as_root install -m 0644 "\$tmp" "\$dest"
  rm -f "\$tmp"
  echo "wrote \$dest"
}

write_if_absent() { dest=\$1; [ -e "\$dest" ] && echo "exists: \$dest" || write_dropin "\$dest"; }

write_etc_conf() {
  dest=/etc/andromeda.conf
  [ -f "\$dest" ] && echo "global config exists: \$dest" && return 0
  [ "\$DRYRUN" -eq 1 ] && echo "+ write \$dest" && return 0
  as_root sh -c "cat > '\$dest'" <<EOF
STARDUST_ROLE=\$ROLE
STARDUST_ROOT=\$STARDUST
PLATFORMS=\$PLATFORMS
OWNER=\$OWNER
ADMIN=\$ADMIN
DAEMON=\$DAEMON
GROUP=\$GROUP
BEE=\\$(command -v bee 2>/dev/null || echo \$BEE_BIN)
APACHE_SERVICE=\$SVC_APACHE
DB_SERVICE=\$SVC_DB
APACHE_RELOAD="\$RELOAD_APACHE"
STARDUST_VERSION=\$STARDUST_VERSION
EOF
  as_root chmod 0644 "\$dest"
}

install_prompt() {
  q=\$1; def=\${2:-}; help=\${3:-}
  while :; do
    [ -n "\$help" ] && printf '%s (? help)\n' "\$q" >&2 || printf '%s\n' "\$q" >&2
    [ -n "\$def" ] && printf '> [%s]: ' "\$def" >&2 || printf '> ' >&2
    IFS= read -r ans || ans=
    case \$ans in \\?|help|HELP) printf '\\n%s\\n\\n' "\$help" >&2; continue ;; esac
    [ -n "\$ans" ] || ans=\$def
    printf '%s\n' "\$ans"
    return 0
  done
}

gitea_conf_path() {
  for f in /etc/gitea/app.ini /var/lib/gitea/custom/conf/app.ini /etc/gitea/conf/app.ini /home/git/gitea/custom/conf/app.ini; do
    [ -f "\$f" ] && printf '%s\n' "\$f" && return 0
  done; return 1
}
gitea_installed() { have gitea && return 0; [ -x /usr/local/bin/gitea ] && return 0; gitea_conf_path >/dev/null && return 0; return 1; }

maybe_gitea_defaults() {
  if [ "\$LOCALHOST" -ne 1 ] && [ "\$ROLE" != "devel" ] || andromeda_git_configured || ! gitea_installed; then return 0; fi
  host_def=gitforge
  [ -f "\$HOME/.ssh/config" ] && host_def=\$(awk 'tolower(\$1)=="host" && \$2 !~ /[*?]/ { if (\$2 ~ /gitea|github|gitlab|git/) { print \$2; exit } }' "\$HOME/.ssh/config" 2>/dev/null || echo "gitforge")
  host=\$(install_prompt "Git SSH host" "\$host_def" "SSH configuration host string.")
  owner=\$(install_prompt "Git owner/org" "" "Username or organization partition name.")
  [ -z "\$owner" ] && return 0
  tpl="git@\${host}:\${owner}/%s.git"
  [ -f /etc/andromeda.conf ] && as_root sh -c "printf 'STARDUST_GIT_TEMPLATE=%s\n' '\$tpl' >> /etc/andromeda.conf"
}

andromeda_git_configured() {
  for f in "\$HOME/.andromeda.conf" /etc/andromeda.conf; do
    [ -f "\$f" ] || continue
    val=\$(sed -n 's/^STARDUST_GIT_TEMPLATE=//p' "\$f" | tail -n 1)
    case \$val in ''|*YOURORG*|*git.example*) ;; *) return 0 ;; esac
  done; return 1
}

write_sudoers() {
  dest=\$1; body=\$(cat); [ "\$DRYRUN" -eq 1 ] && return 0
  tmp=\$(mktemp); printf '%s\n' "\$body" > "\$tmp"; as_root install -m 0440 "\$tmp" "\$dest"; rm -f "\$tmp"
  have visudo && ! as_root visudo -cf "\$dest" >/dev/null 2>&1 && as_root rm -f "\$dest" || true
}

user_conf() {
  name=\$1
  home=\$(getent passwd "\$name" 2>/dev/null | cut -d: -f6 || echo "/home/\$name")
  dest=\$home/.andromeda.conf
  [ -f "\$dest" ] && echo "conf exists: \$dest" && return 0
  [ "\$DRYRUN" -eq 1 ] && echo "+ write \$dest" && return 0
  as_root sh -c "cat > '\$dest'" <<EOF
STARDUST_ROLE=\$ROLE
STARDUST_ROOT=\$STARDUST
PLATFORMS=\$PLATFORMS
OWNER=\$OWNER
ADMIN=\$ADMIN
HUMAN=\$HUMAN
DAEMON=\$DAEMON
GROUP=\$GROUP
DIR_MODE=0770
BEE=\\$(command -v bee 2>/dev/null || echo \$BEE_BIN)
APACHE_SERVICE=\$SVC_APACHE
DB_SERVICE=\$SVC_DB
APACHE_RELOAD="\$RELOAD_APACHE"
DB_HOST=127.0.0.1
DB_PREFIX=bd_
EOF
  as_root chown "\$name:\$GROUP" "\$dest"
  as_root chmod 0600 "\$dest"
}

while [ \$# -gt 0 ]; do
  case \$1 in
    -n) DRYRUN=1 ;;
    -lh|--localhost) LOCALHOST=1 ;;
    -F) DO_CSF=1 ;;
    -m) ROLE=\$(normalize_role "\$2"); [ "\$ROLE" = "devel" ] && LOCALHOST=1; shift ;;
    -u) OWNER=\$2; shift ;;
    -a) ADMIN=\${2:-}; shift ;;
    -H) HUMAN=\${2:-}; shift ;;
    -g) GROUP=\${2:-}; shift ;;
    -h) usage; exit 0 ;;
    *) echo "\$PROG: unknown flag \$1" >&2; exit 1 ;;
  esac
  shift
done

[ -z "\$HUMAN" ] && HUMAN=\${SUDO_USER:-\$(whoami)}
detect_os; detect_init; detect_group; detect_services
ROLE=\$(normalize_role "\$ROLE")

# --- Automated Error Safety Exit Path for Dry-Run Mode ---
if [ "\$DRYRUN" -eq 1 ]; then
  echo "🛡️ Running in strict Dry-Run Verification Mode."
  if [ "\$PKG" = "unknown" ]; then
    echo "❌ DRY-RUN VALIDATION FAILURE: Unsupported or missing OS package manager architecture." >&2
    exit 2
  fi
  if ! have sudo && [ "\$(id -u)" -ne 0 ]; then
    echo "❌ DRY-RUN VALIDATION FAILURE: Non-root user lacks sudo fallback utility binary execution paths." >&2
    exit 3
  fi
fi

echo "===================================================="
echo "\$PROG \$STARDUST_VERSION — Starting Andromeda installation..."
echo "===================================================="

# --- The Sequential Orchestration Loop ---
for module in "\$HERE/modules/"[0-9][0-9]-*.sh; do
  if [ -f "\$module" ]; then
    echo "▶️ Running module: \$(basename "\$module")"
    . "\$module" || {
      echo "❌ Error: Module \$(basename "\$module") failed to execute correctly." >&2
      exit 1
    }
  fi
done

echo ""
echo "Andromeda installation complete!"
EOF
```

### 2. The Pre-Flight Pre-Check Validator (`test-andromeda-vars.sh`)
Wipes variable fragmentation gaps before real execution runs by forcing explicit checking validations on environment variables.

```sh
#!/bin/sh
# test-andromeda-vars.sh — Pre-flight structural validator for Andromeda variables
set -eu

PROG=${0##*/}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

echo "===================================================="
echo "🔍 Starting Andromeda Configuration Hand-Off Audit..."
echo "===================================================="

REQUIRED_VARS="DRYRUN ROLE OWNER ADMIN GROUP PLATFORMS STARDUST PKG INIT OS_ID SVC_APACHE SVC_DB"

DRYRUN=1; ROLE="devel"; OWNER="deploy"; ADMIN="www-admin"; GROUP="www-admin"
PLATFORMS="/srv/platforms"; STARDUST="/srv/andromeda"; PKG="apt"; INIT="systemd"
OS_ID="debian"; SVC_APACHE="apache2"; SVC_DB="mariadb"

audit_environment() {
  local target_module="$1"
  local pass=0
  echo "📋 Auditing state tracking for module: [$(basename "$target_module")]"
  for var_name in $REQUIRED_VARS; do
    eval var_val=\${$var_name:-}
    if [ -z "$var_val" ]; then
      echo "  ❌ CRITICAL FAILURE: Variable [\$$var_name] is empty or unassigned!" >&2
      pass=1
    else
      echo "  ✓ Hand-off verified: \$$var_name = "$var_val""
    fi
  done
  return $pass
}

failures=0
if [ -d "$HERE/modules" ]; then
  for module in "$HERE/modules/"[0-9][0-9]-*.sh; do
    if [ -f "$module" ]; then
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
```

### 3. The Unprompted Non-Interactive Purger (`cleanup-andromeda.sh`)
An advanced environment wipe tool that cleanly reverses state parameters by checking for non-interactive `apt` variables and dropping library layers from the outside in.

```sh
#!/bin/sh
# cleanup-andromeda.sh — Modular tear-down control engine for Andromeda
set -eu

PROG=${0##*/}
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

export STARDUST=/srv/andromeda
export DRYRUN=0
export PURGE_ALL=0
export OWNER="${OWNER:-deploy}"
export ADMIN="${ADMIN:-www-admin}"
export GROUP="${GROUP:-www-admin}"
FORCE=0

usage() {
  cat <<EOF
Usage: $PROG [-n] [-f] [-p]
  -n  Dry run. Prints the destructive actions without executing them.
  -f  Force execution. Skips safety verification prompts.
  -p  Purge all. Wipes out core system packages (apt) and downloaded binaries (Gitea/Bee).
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    -n) DRYRUN=1 ;;
    -f) FORCE=1 ;;
    -p) PURGE_ALL=1 ;;
    -h) usage; exit 0 ;;
    *) echo "Unknown flag $1" >&2; exit 1 ;;
  esac
  shift
done

as_root() { if [ "$(id -u)" -ne 0 ]; then sudo "$@"; else "$@"; fi }

if [ "$FORCE" -ne 1 ] && [ "$DRYRUN" -ne 1 ]; then
  if [ "$PURGE_ALL" -eq 1 ]; then
    printf "🚨 CRITICAL WARNING: This will completely UNINSTALL all database, web server, and binary engines. Continue? [y/N]: "
  else
    printf "⚠️ WARNING: This will completely tear down the Andromeda control plane configurations. Continue? [y/N]: "
  fi
  read -r ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Tear-down aborted."; exit 0 ;; esac
fi

echo "🧹 Initializing Andromeda system removal..."

if [ -d "$HERE/cleanup-modules" ]; then
  for module_path in "$HERE/cleanup-modules/"[0-9][0-9]-*.sh; do
    [ -f "$module_path" ] || continue
    echo "▶️ Running Tear-down Module: $(basename "$module_path")"
    # shellcheck source=/dev/null
    . "$module_path" || {
      echo "❌ Error: Module $(basename "$module_path") encountered a failure status." >&2
      exit 1
    }
  done
else
  echo "note: No cleanup modules detected in cleanup-modules/"
fi

echo "🏁 Andromeda platform footprint successfully purged."
```

---

## 📦 The App-Centric Worker Modules

### 10-core-prereqs.sh
```sh
# modules/10-core-prereqs.sh
# App-Centric Worker: Shared Prerequisites, Groups, Accounts, and System Users

echo "👥 STEP 10: Provisioning Platform Prerequisites and Core Accounts"
echo "------------------------------------------------------------------"

prereqs_install_packages() {
  echo "  ⚙️ Syncing system toolsets..."
  case $PKG in
    apt)
      pkg_install git curl unzip rsync acl msmtp-mta unattended-upgrades needrestart logwatch goaccess etckeeper smartmontools irqbalance haveged moreutils jq pv age
      [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = "devel" ] && pkg_install dnsmasq
      [ "$LOCALHOST" -eq 0 ] && { [ "$ROLE" = "test" ] || [ "$ROLE" = "live" ]; } && pkg_install certbot python3-certbot-apache
      [ "$LOCALHOST" -eq 0 ] && [ "$DO_CSF" -eq 1 ] && pkg_install iptables perl libwww-perl liblwp-protocol-https-perl libgd-perl
      ;;
    apk)
      pkg_install git curl unzip rsync acl jq smartmontools haveged
      [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = "devel" ] && pkg_install dnsmasq
      ;;
    dnf|yum)
      pkg_install git jq pv smartmontools irqbalance
      [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = "devel" ] && pkg_install dnsmasq
      [ "$LOCALHOST" -eq 0 ] && { [ "$ROLE" = "test" ] || [ "$ROLE" = "live" ]; } && pkg_install certbot python3-certbot-apache
      ;;
  esac
}

prereqs_enforce_security() {
  echo "  ⚙️ Constructing security user profiles..."
  for g in "$GROUP" andromeda adm; do
    if ! getent group "$g" >/dev/null 2>&1; then
      if [ "$DRYRUN" -eq 1 ]; then echo "+ groupadd $g"; else have groupadd && run_root groupadd "$g" || run_root addgroup "$g"; fi
    fi
  done

  for u in "$OWNER:Andromeda code owner" "$ADMIN:Andromeda file admin"; do
    local uname="${u%%:*}"
    local ucomment="${u##*:}"
    if ! id "$uname" >/dev/null 2>&1; then
      if [ "$DRYRUN" -eq 1 ]; then
        echo "+ useradd -m -G $GROUP $uname"
      else
        if [ "$PKG" = "apt" ] && have adduser; then
          run_root adduser --disabled-password --gecos "$ucomment" --ingroup "$GROUP" "$uname"
        elif have useradd; then
          run_root useradd -m -s /bin/bash -c "$ucomment" -G "$GROUP" "$uname"
        else
          run_root adduser -D -s /bin/ash -G "$GROUP" "$uname"
        fi
      fi
    fi
    [ "$DRYRUN" -eq 1 ] && echo "+ usermod -aG $GROUP $uname" || { have usermod && run_root usermod -aG "$GROUP" "$uname" 2>/dev/null || run_root adduser "$uname" "$GROUP" 2>/dev/null || true; }
    
    local uhome; uhome=$(getent passwd "$uname" 2>/dev/null | cut -d: -f6 || echo "/home/$uname")
    run_root mkdir -p "$uhome/.ssh" && run_root chmod 0700 "$uhome/.ssh" && run_root chown -R "$uname:$GROUP" "$uhome/.ssh"
    if [ ! -f "$uhome/.ssh/authorized_keys" ] && [ "$DRYRUN" -eq 0 ]; then
      as_root touch "$uhome/.ssh/authorized_keys" && as_root chmod 0600 "$uhome/.ssh/authorized_keys" && as_root chown "$uname:$GROUP" "$uhome/.ssh/authorized_keys"
    fi
  done

  write_sudoers /etc/sudoers.d/andromeda-deploy <<EOF
$OWNER ALL=(ALL) NOPASSWD: /usr/local/bin/andromeda, /usr/local/bin/crdir, /usr/local/bin/newfeature, /usr/local/sbin/andromeda-priv
EOF
  write_sudoers /etc/sudoers.d/andromeda-admin <<EOF
$ADMIN ALL=(ALL) NOPASSWD: /usr/local/bin/andromeda, /usr/local/bin/crdir, /usr/local/bin/newfeature, /usr/local/sbin/andromeda-priv
EOF

  for user_profile in "$OWNER" "$ADMIN" "$HUMAN"; do
    [ -n "$user_profile" ] && user_conf "$user_profile"
  done
}

prereqs_install_packages
prereqs_enforce_security
```

### 20-apache2.sh
```sh
# modules/20-apache2.sh
# App-Centric Worker: Apache2 Installation, Tuning, and Security Hardening

echo "🌐 STEP 20: Provisioning Web Server Layer (Apache2)"
echo "--------------------------------------------------"

apache_install() {
  if ! pkg_ok apache2 && ! pkg_ok httpd; then
    install_prompt "Install Apache2 (Web Server)? [Y/n]" "Y" "Apache2 is required for local site rendering structures."
    if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
      case $PKG in apt|apk) pkg_install apache2 ;; dnf|yum) pkg_install httpd ;; esac
    fi
  else
    echo "  Apache2 package is already installed."
  fi
}

apache_tune_speed() {
  echo "  ⚙️ Applying high-performance thread parameters (mpm_event)..."
  run_root mkdir -p /etc/apache2/mods-enabled
  for mod in mpm_event proxy_fcgi setenvif deflate expires cache headers; do
    [ -f "/etc/apache2/mods-available/\${mod}.load" ] && run_root ln -sf "../mods-available/\${mod}.load" "/etc/apache2/mods-enabled/\${mod}.load"
    [ -f "/etc/apache2/mods-available/\${mod}.conf" ] && run_root ln -sf "../mods-available/\${mod}.conf" "/etc/apache2/mods-enabled/\${mod}.conf"
  done

  if [ "$PKG" = "apt" ] || [ "$PKG" = "dnf" ] || [ "$PKG" = "yum" ]; then
    local apache_perf_conf="/etc/apache2/conf-available/andromeda-perf.conf"
    local body="<IfModule mpm_event_module>
  StartServers 2
  MinSpareThreads 25
  MaxSpareThreads 75
  ThreadLimit 64
  ThreadsPerChild 25
  MaxRequestWorkers 150
  MaxConnectionsPerChild 1000
</IfModule>
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css text/javascript application/javascript
</IfModule>
<IfModule mod_expires.c>
  ExpiresActive On
  ExpiresDefault "access plus 1 month"
</IfModule>"
    printf '%s
' "$body" | write_dropin "$apache_perf_conf"
    run_root mkdir -p /etc/apache2/conf-enabled
    run_root ln -sf "../conf-available/andromeda-perf.conf" /etc/apache2/conf-enabled/andromeda-perf.conf
  fi
}

apache_tune_security() {
  echo "  ⚙️ Stripping server signatures..."
  local apache_h_conf="/etc/apache2/conf-available/andromeda-harden.conf"
  local body="ServerTokens Prod
ServerSignature Off
TraceEnable Off
Timeout 30
KeepAlive On
KeepAliveTimeout 5
MaxKeepAliveRequests 100"
  
  if [ -d /etc/apache2/conf-available ]; then
    printf '%s
' "$body" | write_dropin "$apache_h_conf"
    have a2enconf && run_root a2enconf andromeda-harden >/dev/null 2>&1 || true
  fi
}

apache_install
apache_tune_speed
apache_tune_security
```

### 30-php.sh
```sh
# modules/30-php.sh
# App-Centric Worker: PHP Execution Environment Engine

echo "⚙️ STEP 30: Provisioning Runtime Process Engine (PHP)"
echo "---------------------------------------------------"

php_install() {
  if ! pkg_ok php; then
    install_prompt "Install PHP (Hypertext Preprocessor)? [Y/n]" "Y" "PHP extensions required for Backdrop CMS site execution profiles."
    if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
      case $PKG in
        apt) pkg_install php php-cli php-mysql php-xml php-gd php-mbstring php-curl php-zip php-fpm php-intl php-bcmath php-imagick php-apcu ;;
        apk) pkg_install php php-cli php-mysqli php-xml php-gd php-mbstring php-curl php-zip apache2-proxy php-intl php-bcmath imagemagick ;;
        dnf|yum) pkg_install php php-cli php-mysqlnd php-xml php-gd php-mbstring php-json php-intl php-bcmath ;;
      esac
    fi
  else
    echo "  PHP is already running on the system."
  fi
}

php_tune_runtime() {
  echo "  ⚙️ Customizing memory limits and runtime boundaries..."
  local shared="; Andromeda Shared Engine
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
max_input_vars = 3000
date.timezone = UTC
allow_url_include = Off
expose_php = Off
opcache.enable = 1
opcache.memory_consumption = 256
opcache.max_accelerated_files = 16000
opcache.interned_strings_buffer = 16"

  local opc_web="opcache.validate_timestamps = 1
opcache.revalidate_freq = 2"
  if [ "$ROLE" = "live" ] || [ "$ROLE" = "test" ]; then opc_web="opcache.validate_timestamps = 0
opcache.revalidate_freq = 0"; fi

  local web="; Andromeda FPM Configuration
disable_functions = passthru,popen,proc_open,proc_close,dl,pcntl_exec,pcntl_fork
allow_url_fopen = On
session.cookie_httponly = 1
session.use_strict_mode = 1
\$(printf '%b' "\$opc_web")"
  if [ "$ROLE" = "live" ] || [ "$ROLE" = "test" ]; then web="\${web}
session.cookie_secure = 1"; fi

  local cli="; Andromeda CLI Override
opcache.enable_cli = 0
opcache.validate_timestamps = 1"

  local written=0
  if [ -d /etc/php ]; then
    for d in /etc/php/*/apache2/conf.d /etc/php/*/cli/conf.d /etc/php/*/fpm/conf.d; do
      [ -d "$d" ] || continue
      printf '%s
' "$shared" | write_dropin "$d/30-andromeda.ini"
      case $d in
        */cli/conf.d) printf '%s
' "$cli" | write_dropin "$d/35-andromeda-cli.ini" ;;
        *) printf '%s
' "$web" | write_dropin "$d/35-andromeda-harden.ini" ;;
      esac
      written=1
    done
  fi

  if [ "$written" -eq 0 ] && [ -d /etc/php.d ]; then
    printf '%s
' "$shared" | write_dropin /etc/php.d/30-andromeda.ini
    written=1
  fi
}

php_install
php_tune_runtime
```

### 40-mariadb.sh
```sh
# modules/40-mariadb.sh
# App-Centric Worker: MariaDB Relational Database Setup & Cluster Core

echo "🐬 STEP 40: Provisioning Database Layer (MariaDB)"
echo "------------------------------------------------"

mysql_install() {
  if ! pkg_ok mariadb-server && ! pkg_ok mysql-server; then
    install_prompt "Install MariaDB (Database Server)? [Y/n]" "Y" "MariaDB server engine provides SQL persistence nodes."
    if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
      case $PKG in apt) pkg_install mariadb-server ;; apk) pkg_install mariadb ;; dnf|yum) pkg_install mariadb-server ;; esac
    fi
  else
    echo "  MariaDB infrastructure packages already registered."
  fi
}

mysql_tune_storage() {
  echo "  ⚙️ Customizing transactional buffer sizes and InnoDB limits..."
  local body="; Andromeda SQL Parameter Overrides
[mysqld]
bind-address = 127.0.0.1
skip-networking = 0
innodb_buffer_pool_size = 2G
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
max_connections = 80
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci"

  if [ -d /etc/mysql/mariadb.conf.d ]; then
    printf '%s
' "$body" | write_dropin /etc/mysql/mariadb.conf.d/90-andromeda.cnf
  elif [ -d /etc/mysql/conf.d ]; then
    printf '%s
' "$body" | write_dropin /etc/mysql/conf.d/90-andromeda.cnf
  elif [ -d /etc/my.cnf.d ]; then
    printf '%s
' "$body" | write_dropin /etc/my.cnf.d/90-andromeda.cnf
  fi
}

mysql_install
mysql_tune_storage
```

### 50-bee.sh
```sh
# modules/50-bee.sh
# App-Centric Worker: Backdrop CMS Bee Companion Command Line Interface

echo "🐝 STEP 50: Provisioning Backdrop CMS CLI (Bee)"
echo "-----------------------------------------------"

bee_install_core() {
  if ! command -v bee >/dev/null 2>&1; then
    install_prompt "Install Bee (Backdrop CMS CLI)? [Y/n]" "Y" "Bee handles rapid site profile deployments."
    if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
      if [ ! -d "$BEE_DST" ]; then
        run_root git clone "$BEE_SRC" "$BEE_DST"
      fi
      if [ -d "$BEE_DST" ]; then
        if have composer; then
          (
            cd "$BEE_DST"
            run_root composer install --no-dev
            run_root ln -sf "$BEE_DST/bee" "$BEE_BIN"
          )
          echo "  ✓ Bee installation sequence complete."
        else
          echo "  ⚠️ Composer missing. Cannot auto-compile packages."
        fi
      else
        echo "❌ Error: Failed to execute Git source tracking download for Bee." >&2
        return 1
      fi
    fi
  else
    echo "  Bee CLI utility is already linked to execution paths."
  fi
}

bee_install_core
```

### 60-gitea.sh
```sh
# modules/60-gitea.sh
# App-Centric Worker: Gitea Self-Hosted Git Hosting Server Core

echo "🐙 STEP 60: Provisioning Code Repository Infrastructure (Gitea)"
echo "--------------------------------------------------------------"

gitea_install_core() {
  if ! gitea_installed; then
    install_prompt "Install Gitea (Self-hosted Git Service)? [Y/n]" "Y" "Gitea builds your local code tracking control nodes."
    if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
      echo "  🌐 Downloading production Gitea server compilation..."
      if [ "$DRYRUN" -eq 1 ]; then
        echo "+ wget -O /tmp/gitea https://gitea.com"
      else
        as_root mkdir -p /tmp
        as_root wget -q --show-progress -O /tmp/gitea "https://gitea.com"
      fi
      run_root install -m 755 /tmp/gitea /usr/local/bin/gitea
      [ "$DRYRUN" -eq 0 ] && as_root rm -f /tmp/gitea
      svc_start gitea
    fi
  else
    echo "  Gitea core deployment is already registered."
  fi
  maybe_gitea_defaults
}

gitea_install_core
```

---

## 🗑️ The Deep Cleanup Worker (`cleanup-modules/10-purge-packages.sh`)

```sh
# cleanup-modules/10-purge-packages.sh
# Worker Module: Non-interactive deep purge engine for system packages and libraries

echo "📦 STEP 10: Finalizing Core System Package Audits"
echo "-------------------------------------------------"

APT_PACKAGES="apache2 mariadb-server php-fpm php-cli php-mysql php-xml php-gd php-mbstring php-curl php-zip php-intl php-bcmath php-imagick php-apcu apache2-utils mariadb-backup msmtp-mta unattended-upgrades needrestart logwatch goaccess etckeeper smartmontools irqbalance haveged moreutils jq pv age dnsmasq"

purge_package_framework() {
  if [ "$PURGE_ALL" -eq 1 ]; then
    echo "🚨 Purge flag detected! Executing automated deep-cleansing sequence..."
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ DEBIAN_FRONTEND=noninteractive apt-get purge -y -o Dpkg::Options::="--force-confold" $APT_PACKAGES"
      echo "+ DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y"
      echo "+ rm -rf /usr/local/bin/bee /usr/local/src/bee"
      echo "+ rm -f /usr/local/bin/gitea"
    else
      echo "  Stopping background application listeners..."
      as_root /etc/init.d/apache2 stop 2>/dev/null || true
      as_root /etc/init.d/mysql stop 2>/dev/null || true
      as_root /etc/init.d/gitea stop 2>/dev/null || true

      echo "  Purging system repository packages via apt (Non-interactive Mode)..."
      as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Options::="--force-confmiss" \
        \$APT_PACKAGES
      
      echo "  Executing dynamic dependency autoremove and purge cascade..."
      as_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
      as_root env DEBIAN_FRONTEND=noninteractive apt-get clean
      
      echo "  Deleting manual scripted binary installations..."
      as_root rm -rf /usr/local/bin/bee /usr/local/src/bee
      as_root rm -f /usr/local/bin/gitea
      echo "  ✓ Environment successfully scrubbed back to a pristine vanilla baseline."
    fi
  else
    echo "  ⚙️ Core engines preserved (Soft-removal mode)."
  fi
}

purge_package_framework
```

---

## 🚀 Live Local Execution Verification Pipeline

Follow this operational workflow checklist on your Devuan SysVinit virtual machine to verify complete pipeline integrity:

```bash
# 1. Fetch, prune tracking logs, and force-snap to baseline commits
git fetch --all --prune
git reset --hard origin/feature/modularize-installer

# 2. Perform the aggressive environment wipe (Vanilla scrubbing reset)
sudo ./cleanup-andromeda.sh -p

# 3. Execute pre-flight parameters sanity hand-off check
./test-andromeda-vars.sh

# 4. Fire the dry-run simulation mode log verification test
./install-andromeda.sh -n

# 5. Execute the live App-Centric modular installation cascade
sudo ./install-andromeda.sh

# 6. Run final platform diagnostic verification check
andromeda doctor
```
