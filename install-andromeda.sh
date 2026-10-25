#!/bin/sh
# install-andromeda.sh — idempotent bootstrap for Andromeda
# Same script on a devel workstation and a remote test/live host.
# Contract: artifacts/andromeda-settings.json
#
# Detects package manager and init. Does not assume Devuan or systemd.
# Creates system account deploy (HOME under $STARDUST/home, nologin) +
# group www-admin, ships crdir/newfeature/andromeda, tunes
# PHP/MariaDB/Apache, writes logrotate + state. No PHP GUI.
# Does not wipe /srv/platforms or existing platform checkouts.
# Does not install nginx, Podman, or rewrite firewall/VPN.
#
# Usage:
#   andromeda-install.sh [-n] [-m ROLE] [-u USER] [-g GROUP] [-a ADMIN]
#   andromeda-install.sh -h
#
# ROLE: devel | test | live
#       devel, vps-test, vps-live still accepted as aliases.

set -eu

PROG=${0##*/}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Source common functions
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

STARDUST_VERSION=0.4.0
if [ -f "$HERE/VERSION" ]; then
  STARDUST_VERSION=$(tr -d ' \n' < "$HERE/VERSION")
fi
if [ -d "$HERE/bin" ] && [ -d "$HERE/lib" ]; then
  BINDIR=$HERE/bin
  LIBSRC=$HERE/lib
  MANDIR=$HERE/man
  TUIDIR=$HERE/tui
else
  BINDIR=$HERE
  LIBSRC=$HERE/andromeda-lib
  MANDIR=$HERE
  TUIDIR=$HERE/andromeda-tui
fi
DRYRUN=0
DO_CSF=0
LOCALHOST=0
ROLE=devel
OWNER=deploy
ADMIN=""
HUMAN=""
DAEMON=""
GROUP=""
PLATFORMS=/srv/platforms
STARDUST=/srv/andromeda
CONF=""
CSF_ALLOW="10.8.0.0/24 192.168.1.0/24"
BEE_SRC=https://github.com/backdrop-contrib/bee.git
BEE_DST=/usr/local/src/bee
BEE_BIN=/usr/local/bin/bee

PKG=unknown
INIT=unknown
OS_ID=unknown
SVC_APACHE=""
SVC_DB=""
RELOAD_APACHE=""

usage() {
  cat <<EOF
$PROG $STARDUST_VERSION — prepare any Andromeda host (Apache + PHP + MariaDB + Bee)

WHAT THIS IS FOR
  One script for any host. Detects apt vs other managers and
  sysvinit vs systemd vs OpenRC. Creates system account deploy
  (HOME $STARDUST/home, shell nologin, locked password) and group
  www-admin, the $STARDUST control plane, missing packages, PHP/MariaDB snippets,
  companion CLIs (crdir, newfeature, andromeda, bee, glow, gum), and conf files.
  PHP: 30-andromeda.ini every SAPI; 35-andromeda-harden.ini FPM/apache2
  only; 35-andromeda-cli.ini leaves Bee able to exec.
  Also: php-intl/bcmath/imagick/apcu, apache2-utils, mariadb-backup,
  msmtp-mta, unattended-upgrades (no auto-reboot), needrestart,
  logwatch, goaccess, etckeeper, smartmontools, irqbalance, haveged,
  moreutils, jq, pv, age.
  Leaves $PLATFORMS trees alone. No Aegir/BOA frontend.

USERS
  $OWNER      system account. Owns platforms and the control plane.
                 HOME $STARDUST/home, shell nologin, no password.
                 Not a human login. sudo -u $OWNER bee|git|crdir.
  $GROUP      file group on every tree (default: www-admin).
                 Not a login. This is the web-admin grant.
  andromeda    secrets group. Not www-data.
  invoking    the login that ran this script is added to
                 $GROUP, andromeda, and $OWNER only.
                 Never added to sudo, admin, or wheel.
                 The account is not created; it must already exist.
  extra login  only if you pass -a NAME and NAME is not $GROUP.
  daemon      Apache/PHP user (www-data or apache); also in $GROUP.

  No passwords are set. $OWNER is locked. Humans keep the password
  they already have. Put deploy's forge key in $STARDUST/home/.ssh.

HOW TO RUN IT
  $PROG [-n] [-lh|--localhost] [-F] [-m devel|test|live] [-u owner] [-a admin] [-H human] [-g group]
  $PROG -h

  Run as a sudo-capable account. Do not type "sudo $PROG".

FLAGS
  -n         Dry run. Print the plan with a leading + and change nothing.
  -lh, --localhost
             Local dev box only (127.0.0.1). Skips CSF, WireGuard
             policy, and certbot. Installs dnsmasq (*.devel → 127.0.0.1).
             Role becomes devel. Apache and MariaDB stay on localhost.
  -m ROLE    devel (default), test, or live
  -u owner   Code owner (default: deploy)
  -a admin   Optional extra login. Omitted by default. Ignored when
             NAME equals the file group (www-admin): that name is a
             group, not a user.
  -H user    Existing login to put in Andromeda groups
             (default: whoever ran this script). Not created.
  -g group   File group on every tree (default: www-admin)
  -F         Install/apply CSF. SSH is not world-open: only 10.8.0.0/24
             (WireGuard) and 192.168.1.0/24 (LAN). UDP 51820 stays open
             for the tunnel. HTTP 80 on devel; 80+443 on test/live.
             First enable uses CSF TESTING=1 so a lockout self-reverts.
  -h         This text

SAFE FIRST RUN
  laptop: $PROG -n --localhost
  devel:  $PROG -n -m devel
  VPS:    $PROG -n -m test     (or -m live)

WHAT IT WILL NOT DO
  Touch files inside $PLATFORMS/<platform>
  Enable a catch-all vhost
  Rewrite an existing WireGuard interface (CSF only adds allow rules)
  Set or print account passwords
  Start a container runtime
EOF
}

as_root() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_root() {
  if [ "$DRYRUN" -eq 1 ]; then
    printf '+'
    for a in "$@"; do
      printf ' %s' "$a"
    done
    printf '\n'
    return 0
  fi
  as_root "$@"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

normalize_role() {
  case $1 in
    devel|devel|localhost|dev) echo devel ;;
    test|vps-test) echo test ;;
    live|vps-live|prod|production) echo live ;;
    *) echo "" ;;
  esac
}

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
  fi
  if have apt-get && have dpkg; then
    PKG=apt
  elif have apk; then
    PKG=apk
  elif have dnf; then
    PKG=dnf
  elif have yum; then
    PKG=yum
  elif have pacman; then
    PKG=pacman
  elif have zypper; then
    PKG=zypper
  elif have xbps-install; then
    PKG=xbps
  else
    PKG=unknown
  fi
}

detect_init() {
  if [ -d /run/systemd/system ] && have systemctl; then
    INIT=systemd
  elif [ -d /etc/init.d ] && [ ! -d /run/systemd/system ]; then
    INIT=sysv
  elif have rc-service; then
    INIT=openrc
  elif [ -x /etc/init.d/apache2 ] || [ -x /etc/init.d/httpd ]; then
    INIT=sysv
  elif have systemctl; then
    INIT=systemd
  else
    INIT=unknown
  fi
}

detect_group() {
  if [ -z "$DAEMON" ]; then
    if getent passwd www-data >/dev/null 2>&1; then
      DAEMON=www-data
    elif getent passwd apache >/dev/null 2>&1; then
      DAEMON=apache
    else
      DAEMON=www-data
    fi
  fi
  if [ -z "$GROUP" ]; then
    GROUP=www-admin
  fi
}

detect_services() {
  SVC_APACHE=""
  SVC_DB=""
  if [ -x /etc/init.d/apache2 ] || [ -d /etc/apache2 ]; then
    SVC_APACHE=apache2
  elif [ -x /etc/init.d/httpd ] || [ -d /etc/httpd ]; then
    SVC_APACHE=httpd
  else
    SVC_APACHE=apache2
  fi
  if [ -x /etc/init.d/mysql ] || have mysql; then
    SVC_DB=mysql
  elif [ -x /etc/init.d/mariadb ]; then
    SVC_DB=mariadb
  else
    SVC_DB=mysql
  fi

  case $INIT in
    systemd)
      RELOAD_APACHE="systemctl reload $SVC_APACHE"
      ;;
    openrc)
      RELOAD_APACHE="rc-service $SVC_APACHE reload"
      ;;
    sysv|unknown)
      RELOAD_APACHE="/etc/init.d/$SVC_APACHE reload"
      ;;
  esac
}

pkg_ok() {
  case $PKG in
    apt)
      dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
      ;;
    apk)
      apk info -e "$1" >/dev/null 2>&1
      ;;
    dnf|yum)
      rpm -q "$1" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# Charm tools: glow renders markdown help; gum drives the menu and key picker.
# Static binaries from GitHub releases. No extra apt repo.
install_charm() {
  for tool in glow gum; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "$tool ok"
      continue
    fi
    arch=$(uname -m)
    case $arch in
      x86_64) suffix=Linux_x86_64.tar.gz ;;
      aarch64|arm64) suffix=Linux_arm64.tar.gz ;;
      *) echo "$PROG: no $tool build for $arch" >&2; continue ;;
    esac
    url=$(curl -fsSL "https://api.github.com/repos/charmbracelet/${tool}/releases/latest" \
      | awk -F'"' -v s="$suffix" '/browser_download_url/ && $0 ~ s {print $4; exit}')
    if [ -z "$url" ]; then
      echo "$PROG: could not find a $tool release" >&2
      continue
    fi
    tmp=$(mktemp -d)
    curl -fsSL "$url" | tar -xz -C "$tmp"
    bin=$(find "$tmp" -type f -name "$tool" | head -1)
    if [ -n "$bin" ]; then
      run_root install -m 0755 "$bin" "/usr/local/bin/$tool"
      echo "$tool installed"
    fi
    rm -rf "$tmp"
  done
}
  case $PKG in
    apt)
      run_root apt-get update
      # AppArmor breaks the install on Devuan/SysVinit. Remove and hold it.
      run_root apt-get purge -y apparmor apparmor-utils libapache2-mod-apparmor || true
      run_root apt-mark hold apparmor || true
      # Skip debconf UI (msmtp asks about AppArmor). Answer no.
      run_root bash -c 'echo msmtp msmtp/apparmor boolean false | debconf-set-selections' || true
      run_root env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true         apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confdef         -o Dpkg::Options::=--force-confold "$@"
      ;;
    apk)
      run_root apk add --no-cache "$@"
      ;;
    dnf)
      run_root dnf install -y "$@"
      ;;
    yum)
      run_root yum install -y "$@"
      ;;
    pacman)
      run_root pacman -Sy --noconfirm "$@"
      ;;
    zypper)
      run_root zypper install -y "$@"
      ;;
    xbps)
      run_root xbps-install -Sy "$@"
      ;;
    *)
      echo "$PROG: no package manager detected; install Apache PHP MariaDB git sudo by hand" >&2
      return 1
      ;;
  esac
}

svc_start() {
  name=$1
  case $INIT in
    systemd)
      run_root systemctl enable "$name" 2>/dev/null || true
      run_root systemctl start "$name" || true
      ;;
    openrc)
      run_root rc-update add "$name" default 2>/dev/null || true
      run_root rc-service "$name" start || true
      ;;
    sysv|unknown)
      if [ -x "/etc/init.d/$name" ]; then
        run_root "/etc/init.d/$name" start || true
      fi
      ;;
  esac
}

pkg_list_for() {
  case $PKG in
    apt)
      echo "sudo apache2 mariadb-server git curl unzip rsync ca-certificates acl"
      echo "php php-cli php-mysql php-xml php-gd php-mbstring php-curl php-zip php-fpm"
      echo "php-intl php-bcmath php-imagick php-apcu"
      echo "libapache2-mod-php apache2-utils"
      echo "mariadb-backup msmtp-mta unattended-upgrades needrestart"
      echo "logwatch goaccess etckeeper smartmontools irqbalance haveged"
      echo "moreutils jq pv age"
      if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
        echo "dnsmasq"
      fi
      if [ "$LOCALHOST" -eq 0 ] && { [ "$ROLE" = test ] || [ "$ROLE" = live ]; }; then
        echo "certbot python3-certbot-apache"
      fi
      if [ "$LOCALHOST" -eq 0 ] && [ "$DO_CSF" -eq 1 ]; then
        echo "iptables perl libwww-perl liblwp-protocol-https-perl libgd-perl"
      fi
      ;;
    apk)
      echo "sudo apache2 mariadb mariadb-client git curl unzip rsync acl"
      echo "php php-cli php-mysqli php-xml php-gd php-mbstring php-curl php-zip apache2-proxy"
      echo "php-intl php-bcmath imagemagick jq rsync smartmontools haveged"
      if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
        echo "dnsmasq"
      fi
      ;;
    dnf|yum)
      echo "sudo httpd mariadb-server git curl unzip rsync ca-certificates acl"
      echo "php php-cli php-mysqlnd php-xml php-gd php-mbstring php-json php-intl php-bcmath"
      echo "httpd-tools mariadb-backup jq pv smartmontools irqbalance"
      if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
        echo "dnsmasq"
      fi
      if [ "$LOCALHOST" -eq 0 ] && { [ "$ROLE" = test ] || [ "$ROLE" = live ]; }; then
        echo "certbot python3-certbot-apache"
      fi
      ;;
    pacman)
      echo "sudo apache mariadb git curl unzip rsync ca-certificates acl"
      echo "php php-apache php-gd php-intl php-fpm"
      echo "jq pv smartmontools"
      if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
        echo "dnsmasq"
      fi
      ;;
    zypper)
      echo "sudo apache2 mariadb git curl unzip rsync ca-certificates acl"
      echo "php8 php8-mysql php8-gd php8-mbstring php8-intl php8-zip php8-fpm"
      echo "apache2-mod_php8 mariadb-client jq"
      if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
        echo "dnsmasq"
      fi
      ;;
    xbps)
      echo "sudo apache mariadb git curl unzip rsync ca-certificates acl"
      echo "php php-mysql php-gd php-mbstring php-intl php-fpm"
      echo "jq"
      if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
        echo "dnsmasq"
      fi
      ;;
  esac
}

find_admin_bin() {
  # groupadd/useradd live in /usr/sbin; unprivileged PATH often omits it.
  name=$1
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for d in /usr/sbin /sbin /usr/bin /bin; do
    [ -x "$d/$name" ] && { echo "$d/$name"; return 0; }
  done
  return 1
}

ensure_group() {
  g=$1
  if getent group "$g" >/dev/null 2>&1; then
    echo "group ok: $g"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ groupadd $g"
    return 0
  fi
  bin=$(find_admin_bin groupadd || true)
  if [ -n "$bin" ]; then
    run_root "$bin" "$g"
    return $?
  fi
  bin=$(find_admin_bin addgroup || true)
  if [ -n "$bin" ]; then
    run_root "$bin" "$g"
    return $?
  fi
  echo "$PROG: cannot create group $g (no groupadd/addgroup in PATH or /usr/sbin)" >&2
  echo "$PROG: install passwd, or: sudo groupadd $g" >&2
  return 1
}

nologin_shell() {
  for s in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin; do
    [ -x "$s" ] && { echo "$s"; return 0; }
  done
  echo /usr/sbin/nologin
}

is_privilege_group() {
  case $1 in
    sudo|admin|wheel|root) return 0 ;;
    *) return 1 ;;
  esac
}

# Groups a human needs to admin Andromeda. Never sudo/admin/wheel.
andromeda_admin_groups() {
  echo "$GROUP"
  echo andromeda
  echo "$OWNER"
}

ensure_andromeda_groups() {
  # ensure_andromeda_groups LOGIN — add only Andromeda admin groups.
  name=$1
  [ -n "$name" ] || return 0
  if ! id "$name" >/dev/null 2>&1; then
    echo "note: login $name does not exist; not creating it"
    echo "note: after adduser $name: usermod -aG $GROUP,andromeda,$OWNER $name"
    return 0
  fi
  usermod_bin=$(find_admin_bin usermod || true)
  for g in $(andromeda_admin_groups); do
    [ -n "$g" ] || continue
    if is_privilege_group "$g"; then
      echo "note: refusing to add $name to privilege group $g"
      continue
    fi
    if ! getent group "$g" >/dev/null 2>&1; then
      continue
    fi
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ usermod -aG $g $name"
      continue
    fi
    if [ -n "$usermod_bin" ]; then
      run_root "$usermod_bin" -aG "$g" "$name" 2>/dev/null || true
    fi
  done
  echo "groups for $name: $GROUP,andromeda,$OWNER (not sudo)"
}

ensure_owner_home() {
  home=$STARDUST/home
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ mkdir -p $home $home/.ssh"
    echo "+ chown $OWNER:$OWNER $home && chmod 0700 $home"
    return 0
  fi
  run_root mkdir -p "$home/.ssh"
  run_root chown "$OWNER:$OWNER" "$home" "$home/.ssh"
  run_root chmod 0700 "$home" "$home/.ssh"
  if have setfacl; then
    as_root setfacl -b "$home" 2>/dev/null || true
    as_root setfacl -b "$home/.ssh" 2>/dev/null || true
  fi
}

ensure_owner() {
  # System account: HOME $STARDUST/home, nologin, locked password.
  # If the uid already exists (older install), leave shell/home alone.
  shell=$(nologin_shell)
  home=$STARDUST/home
  adduser_bin=$(find_admin_bin adduser || true)
  useradd_bin=$(find_admin_bin useradd || true)
  if id "$OWNER" >/dev/null 2>&1; then
    echo "user ok: $OWNER (existing; not rewriting shell or home)"
    ensure_andromeda_groups "$OWNER"
    ensure_owner_home
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ mkdir -p $home"
    if [ -n "$adduser_bin" ] && [ "$PKG" = apt ]; then
      echo "+ adduser --system --home $home --shell $shell --disabled-password --ingroup $OWNER --gecos 'Andromeda deploy' $OWNER"
    else
      echo "+ useradd -r -m -d $home -s $shell -g $OWNER -c 'Andromeda deploy' $OWNER"
    fi
    echo "+ usermod -aG $GROUP,andromeda $OWNER"
    return 0
  fi
  run_root mkdir -p "$STARDUST"
  if [ -n "$adduser_bin" ] && [ "$PKG" = apt ]; then
    run_root "$adduser_bin" --system --home "$home" --shell "$shell" \
      --disabled-password --ingroup "$OWNER" --gecos "Andromeda deploy" "$OWNER" || {
      echo "$PROG: cannot create system user $OWNER (adduser failed)" >&2
      return 1
    }
  elif [ -n "$useradd_bin" ]; then
    run_root "$useradd_bin" -r -m -d "$home" -s "$shell" -g "$OWNER" \
      -c "Andromeda deploy" "$OWNER" || {
      echo "$PROG: cannot create system user $OWNER (useradd failed)" >&2
      return 1
    }
  else
    echo "$PROG: cannot create system user $OWNER (no useradd/adduser in /usr/sbin)" >&2
    return 1
  fi
  echo "system user: $OWNER home=$home shell=$shell"
  ensure_andromeda_groups "$OWNER"
  ensure_owner_home
}

ensure_user() {
  # ensure_user NAME COMMENT — optional human login (-a only).
  # useradd/adduser/usermod live in /usr/sbin; unprivileged PATH omits it.
  # Never used for $OWNER (that is ensure_owner) or the invoking operator.
  name=$1
  comment=$2
  adduser_bin=$(find_admin_bin adduser || true)
  useradd_bin=$(find_admin_bin useradd || true)
  usermod_bin=$(find_admin_bin usermod || true)
  if id "$name" >/dev/null 2>&1; then
    echo "user ok: $name"
  else
    if getent group "$name" >/dev/null 2>&1; then
      primary=$name
    else
      primary=$GROUP
    fi
    if [ "$DRYRUN" -eq 1 ]; then
      if [ -n "$adduser_bin" ] && [ "$PKG" = apt ]; then
        echo "+ adduser --disabled-password --gecos '$comment' --ingroup $primary $name"
      else
        echo "+ useradd -m -s /bin/bash -c '$comment' -g $primary -N $name"
      fi
    elif [ -n "$adduser_bin" ] && [ "$PKG" = apt ]; then
      run_root "$adduser_bin" --disabled-password --gecos "$comment" --ingroup "$primary" "$name" || {
        echo "$PROG: cannot create user $name (adduser failed)" >&2
        return 1
      }
    elif [ -n "$useradd_bin" ]; then
      run_root "$useradd_bin" -m -s /bin/bash -c "$comment" -g "$primary" -N "$name" || {
        echo "$PROG: cannot create user $name (useradd failed)" >&2
        return 1
      }
    elif [ -n "$adduser_bin" ]; then
      run_root "$adduser_bin" -D -s /bin/ash -G "$primary" "$name" || {
        echo "$PROG: cannot create user $name (adduser failed)" >&2
        return 1
      }
    else
      echo "$PROG: cannot create user $name (no useradd/adduser in PATH or /usr/sbin)" >&2
      echo "$PROG: install passwd/adduser, or: sudo useradd -m -g $primary -N $name" >&2
      return 1
    fi
  fi

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ usermod -aG $GROUP $name"
    return 0
  fi

  if [ -n "$usermod_bin" ]; then
    run_root "$usermod_bin" -aG "$GROUP" "$name" 2>/dev/null || true
  elif [ -n "$adduser_bin" ]; then
    run_root "$adduser_bin" "$name" "$GROUP" 2>/dev/null || true
  fi

  home=$(getent passwd "$name" 2>/dev/null | cut -d: -f6)
  if [ -z "$home" ]; then
    home=/home/$name
  fi
  run_root mkdir -p "$home/.ssh"
  run_root chmod 0700 "$home/.ssh"
  run_root chown -R "$name:$name" "$home/.ssh"
  if [ ! -f "$home/.ssh/authorized_keys" ]; then
    if [ "$DRYRUN" -eq 0 ]; then
      as_root touch "$home/.ssh/authorized_keys"
      as_root chmod 0600 "$home/.ssh/authorized_keys"
      as_root chown "$name:$name" "$home/.ssh/authorized_keys"
    else
      echo "+ touch $home/.ssh/authorized_keys"
    fi
  fi
}


write_wg_sudoers() {
  dest=/etc/sudoers.d/andromeda-wg
  body="%${GROUP} ALL=(root) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick"
  write_sudoers "$dest" "$body"
}

write_sudoers() {
  dest=$1
  body=$2
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    printf '%s\n' "$body" | sed 's/^/+ /'
    return 0
  fi
  tmp=$(mktemp)
  printf '%s\n' "$body" > "$tmp"
  as_root install -m 0440 "$tmp" "$dest"
  rm -f "$tmp"
  if have visudo; then
    as_root visudo -cf "$dest" >/dev/null 2>&1 || {
      echo "$PROG: $dest failed visudo; removing" >&2
      as_root rm -f "$dest"
      return 1
    }
  fi
  echo "sudoers: $dest"
}

user_conf() {
  name=$1
  home=$(getent passwd "$name" 2>/dev/null | cut -d: -f6)
  if [ -z "$home" ]; then
    home=/home/$name
  fi
  dest=$home/.andromeda.conf
  if [ -f "$dest" ]; then
    echo "conf exists: $dest (not overwritten)"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  as_root sh -c "cat > '$dest'" <<EOF
# Andromeda config — generated by $PROG
# role=$ROLE host=$HOSTN os=$OS_ID pkg=$PKG init=$INIT user=$name

STARDUST_ROLE=$ROLE
STARDUST_ROOT=$STARDUST
PLATFORMS=$PLATFORMS
OWNER=$OWNER
ADMIN=$ADMIN
HUMAN=$HUMAN
DAEMON=$DAEMON
GROUP=$GROUP
DIR_MODE=0770
BEE=$(command -v bee 2>/dev/null || echo $BEE_BIN)
APACHE_SERVICE=$SVC_APACHE
DB_SERVICE=$SVC_DB
APACHE_RELOAD="$RELOAD_APACHE"
DB_HOST=127.0.0.1
DB_PREFIX=bd_
EOF
  as_root chown "$name:$name" "$dest"
  as_root chmod 0600 "$dest"
  echo "wrote $dest"
}

install_tool() {
  src=$1
  dest=$2
  mode=${3:-0755}
  if [ ! -f "$src" ]; then
    echo "note: skip $dest (no $src next to installer)"
    return 0
  fi
  run_root install -m "$mode" "$src" "$dest"
  echo "installed $dest"
}

write_dropin() {
  dest=$1
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  dir=$(dirname "$dest")
  as_root mkdir -p "$dir"
  tmp=$(mktemp)
  cat > "$tmp"
  as_root install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
  echo "wrote $dest"
}

write_if_absent() {
  dest=$1
  if [ -e "$dest" ]; then
    echo "exists: $dest (unchanged)"
    return 0
  fi
  write_dropin "$dest"
}

ship_tools() {
  install_tool "$BINDIR/crdir" /usr/local/bin/crdir 0755
  install_tool "$BINDIR/newfeature" /usr/local/bin/newfeature 0755
  install_tool "$BINDIR/d7-migrate" /usr/local/bin/d7-migrate 0755
  install_tool "$BINDIR/andromeda" /usr/local/bin/andromeda 0755
  run_root ln -sfn /usr/local/bin/andromeda /usr/local/bin/ande
  install_tool "$BINDIR/andromeda-priv" /usr/local/sbin/andromeda-priv 0750
  install_tool "$BINDIR/andromeda-menu" /usr/local/bin/andromeda-menu 0755
  if [ -f "$HERE/tui/andromeda_ui.py" ]; then
    run_root mkdir -p /usr/local/share/andromeda/tui
    run_root install -m 0644 "$HERE/tui/andromeda_ui.py" /usr/local/share/andromeda/tui/andromeda_ui.py
    echo "installed Textual UI"
  fi
  if [ -x "$TUIDIR/andromeda-tui" ]; then
    install_tool "$TUIDIR/andromeda-tui" /usr/local/bin/andromeda-tui 0755
  elif [ -d "$TUIDIR" ] && [ -f "$TUIDIR/main.go" ] && command -v go >/dev/null 2>&1; then
    echo "building andromeda-tui"
    (cd "$TUIDIR" && GOPROXY=https://proxy.golang.org,direct go build -o andromeda-tui .) && \
      install_tool "$TUIDIR/andromeda-tui" /usr/local/bin/andromeda-tui 0755
  else
    echo "andromeda-tui binary absent (optional; use andromeda-menu)"
  fi
  if [ -f "$HERE/install-andromeda.sh" ]; then
    install_tool "$HERE/install-andromeda.sh" /usr/local/sbin/install-andromeda.sh 0755
    run_root ln -sfn /usr/local/sbin/install-andromeda.sh /usr/local/sbin/andromeda-install.sh
  else
    install_tool "$HERE/andromeda-install.sh" /usr/local/sbin/andromeda-install.sh 0755
  fi
  if [ -d "$LIBSRC" ]; then
    run_root mkdir -p /usr/local/lib/andromeda "$STARDUST/lib"
    for f in "$LIBSRC"/*.sh "$LIBSRC"/d7-catalog.txt; do
      [ -f "$f" ] || continue
      # apps/bee/lib.sh is the real bee runtime; skip the checkout shim
      if [ "$(basename "$f")" = bee.sh ] && [ -f "$HERE/apps/bee/lib.sh" ]; then
        continue
      fi
      run_root install -m 0644 "$f" "/usr/local/lib/andromeda/$(basename "$f")"
      run_root install -m 0644 "$f" "$STARDUST/lib/$(basename "$f")"
    done
    echo "installed andromeda-lib from $LIBSRC"
    if [ -f "$HERE/apps/bee/lib.sh" ]; then
      run_root install -m 0644 "$HERE/apps/bee/lib.sh" /usr/local/lib/andromeda/bee.sh
      run_root install -m 0644 "$HERE/apps/bee/lib.sh" "$STARDUST/lib/bee.sh"
      echo "installed apps/bee/lib.sh as bee.sh"
    fi
  fi
  if [ -f "$MANDIR/crdir.1" ]; then
    run_root mkdir -p /usr/local/share/man/man1
    run_root install -m 0644 "$MANDIR/crdir.1" /usr/local/share/man/man1/crdir.1
    echo "installed man crdir"
  fi
  if [ -f "$MANDIR/andromeda.1" ]; then
    run_root mkdir -p /usr/local/share/man/man1
    run_root install -m 0644 "$MANDIR/andromeda.1" /usr/local/share/man/man1/andromeda.1
    echo "installed man andromeda"
  fi
  if [ -f "$MANDIR/d7-migrate.1" ]; then
    run_root mkdir -p /usr/local/share/man/man1
    run_root install -m 0644 "$MANDIR/d7-migrate.1" /usr/local/share/man/man1/d7-migrate.1
    echo "installed man d7-migrate"
  fi
  DOCSRC=""
  [ -d "$HERE/docs" ] && DOCSRC=$HERE/docs
  if [ -n "$DOCSRC" ]; then
    run_root mkdir -p /usr/local/share/andromeda/docs "$STARDUST/docs"
    for f in "$DOCSRC"/*.txt "$DOCSRC"/*.md; do
      [ -f "$f" ] || continue
      run_root install -m 0644 "$f" "/usr/local/share/andromeda/docs/$(basename "$f")"
      run_root install -m 0644 "$f" "$STARDUST/docs/$(basename "$f")"
    done
    echo "installed docs from $DOCSRC"
  fi
}

tune_php_fpm() {
  # One pool as www-data. Event MPM. Do not create per-product pools.
  pool=""
  for d in /etc/php/*/fpm/pool.d; do
    [ -d "$d" ] || continue
    pool=$d/andromeda.conf
    break
  done
  if [ -z "$pool" ]; then
    echo "note: no php-fpm pool.d — skip FPM"
    return 0
  fi
  body="; Andromeda — single pool, user $DAEMON
[andromeda]
user = $DAEMON
group = $GROUP
listen = /run/php/andromeda-fpm.sock
listen.owner = $DAEMON
listen.group = $DAEMON
pm = ondemand
pm.max_children = 20
pm.process_idle_timeout = 10s
"
  printf '%s\n' "$body" | write_dropin "$pool"
  if have a2enmod; then
    run_root a2dismod mpm_prefork >/dev/null 2>&1 || true
    run_root a2enmod mpm_event >/dev/null 2>&1 || true
    run_root a2enmod proxy_fcgi setenvif >/dev/null 2>&1 || true
  fi
  echo "php-fpm pool $pool (Event MPM). Confirm sites use SetHandler proxy:unix:/run/php/andromeda-fpm.sock|fcgi://localhost/"
}

tune_extras() {
  # Security updates only; never reboot this host from apt.
  if [ -d /etc/apt/apt.conf.d ]; then
    printf '%s\n' \
      'Unattended-Upgrade::Automatic-Reboot "false";' \
      'Unattended-Upgrade::Mail "";' \
      | write_dropin /etc/apt/apt.conf.d/52andromeda-unattended
  fi
  if have etckeeper && [ ! -d /etc/.git ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ etckeeper init"
    else
      as_root etckeeper init 2>/dev/null || true
      echo "etckeeper: /etc is a git repo"
    fi
  fi
  for s in haveged irqbalance smartd smartmontools; do
    [ -x "/etc/init.d/$s" ] || continue
    svc_start "$s"
  done
  if have msmtp || have msmtp-mta; then
    echo "note: copy /etc/msmtprc for NOTIFY= mail (msmtp-mta is installed)"
  fi
  echo "extras: apache2-utils php-intl/bcmath/imagick/apcu mariadb-backup logwatch goaccess age jq pv"
}

tune_php() {
  # Shared limits on every SAPI. Hardening and live OPcache only on FPM/apache2.
  # CLI must keep exec/passthru so Bee, cron, and site-check work.
  shared="; Andromeda PHP — shared (8-core / 32G and small VPS)
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
opcache.interned_strings_buffer = 16
"
  if [ "$ROLE" = live ] || [ "$ROLE" = test ]; then
    opc_web="opcache.validate_timestamps = 0
opcache.revalidate_freq = 0
"
  else
    opc_web="opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
"
  fi
  web="; Andromeda PHP — FPM / apache2 only (not CLI)
disable_functions = passthru,popen,proc_open,proc_close,dl,pcntl_exec,pcntl_fork
allow_url_fopen = On
session.cookie_httponly = 1
session.use_strict_mode = 1
$opc_web"
  if [ "$ROLE" = live ] || [ "$ROLE" = test ]; then
    web="${web}session.cookie_secure = 1
"
  fi
  cli="; Andromeda PHP — CLI only
; do not set disable_functions here — Bee needs the process functions
opcache.enable_cli = 0
opcache.validate_timestamps = 1
"
  written=0
  if [ -d /etc/php ]; then
    for d in /etc/php/*/apache2/conf.d /etc/php/*/cli/conf.d /etc/php/*/fpm/conf.d; do
      [ -d "$d" ] || continue
      printf '%s\n' "$shared" | write_dropin "$d/30-andromeda.ini"
      case $d in
        */cli/conf.d)
          printf '%s\n' "$cli" | write_dropin "$d/35-andromeda-cli.ini"
          ;;
        *)
          printf '%s\n' "$web" | write_dropin "$d/35-andromeda-harden.ini"
          ;;
      esac
      written=1
    done
  fi
  if [ "$written" -eq 0 ] && [ -d /etc/php.d ]; then
    printf '%s\n' "$shared" | write_dropin /etc/php.d/30-andromeda.ini
    written=1
    echo "note: single /etc/php.d — FPM harden not split; check php --ini"
  fi
  if [ "$written" -eq 0 ]; then
    echo "note: no PHP conf.d found; set memory_limit by hand"
  else
    echo "PHP: shared 30-andromeda.ini; FPM/apache harden 35-andromeda-harden.ini; CLI 35-andromeda-cli.ini"
  fi
}

tune_vps() {
  # Public VPS (test/live). Skip laptop and devel workstations.
  # ip_forward stays 1 — WireGuard needs it. Do not disable IPv6 here.
  if [ "$LOCALHOST" -eq 1 ] || [ "$ROLE" = devel ]; then
    echo "VPS harden skipped (localhost/devel)"
    return 0
  fi
  sysctl_body="# Andromeda VPS — do not set ip_forward=0 (WireGuard)
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.ip_forward = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
kernel.randomize_va_space = 2
"
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    sysctl_body="${sysctl_body}net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
"
  fi
  printf '%s\n' "$sysctl_body" | write_dropin /etc/sysctl.d/60-andromeda.conf
  if [ "$DRYRUN" -eq 0 ] && have sysctl; then
    as_root sysctl --system >/dev/null 2>&1 || as_root sysctl -p /etc/sysctl.d/60-andromeda.conf >/dev/null 2>&1 || true
  fi
  printf '%s\n' \
    "www-data soft nofile 65535" \
    "www-data hard nofile 65535" \
    "deploy soft nofile 65535" \
    "deploy hard nofile 65535" \
    | write_dropin /etc/security/limits.d/andromeda.conf
  apache_h="# Andromeda VPS Apache
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Timeout 30
KeepAlive On
KeepAliveTimeout 5
MaxKeepAliveRequests 100
"
  if [ -d /etc/apache2/conf-available ]; then
    printf '%s\n' "$apache_h" | write_dropin /etc/apache2/conf-available/andromeda-harden.conf
    if have a2enconf; then
      run_root a2enconf andromeda-harden >/dev/null 2>&1 || true
    fi
  fi
  echo "VPS harden: sysctl 60-andromeda, limits, Apache tokens/timeouts"
  echo "note: provider disk snapshots are not a CMS backup — keep backup-all + offsite"
}

tune_mysql() {
  body="# Andromeda MariaDB — bind local, modest buffer
[mysqld]
bind-address = 127.0.0.1
skip-networking = 0
innodb_buffer_pool_size = 2G
innodb_log_file_size = 256M
# root stays unix_socket (Debian default). Do not SET PASSWORD for root.
innodb_flush_log_at_trx_commit = 2
max_connections = 80
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
"
  if [ -d /etc/mysql/mariadb.conf.d ]; then
    printf '%s\n' "$body" | write_dropin /etc/mysql/mariadb.conf.d/90-andromeda.cnf
  elif [ -d /etc/mysql/conf.d ]; then
    printf '%s\n' "$body" | write_dropin /etc/mysql/conf.d/90-andromeda.cnf
  elif [ -d /etc/my.cnf.d ]; then
    printf '%s\n' "$body" | write_dropin /etc/my.cnf.d/90-andromeda.cnf
  else
    echo "note: no MariaDB conf.d; set bind-address = 127.0.0.1 by hand"
  fi
}

tune_logrotate() {
  body="$STARDUST/state/tasks.log
$STARDUST/state/backup-all.log
$STARDUST/state/cron-all.log
$STARDUST/backups/*/*/*/*.log
/var/log/apache2/*.log
{
  weekly
  rotate 8
  missingok
  notifempty
  compress
  sharedscripts
  postrotate
    if [ -x /etc/init.d/$SVC_APACHE ]; then /etc/init.d/$SVC_APACHE reload >/dev/null 2>&1 || true; fi
  endscript
}
"
  if [ -d /etc/logrotate.d ]; then
    printf '%s\n' "$body" | write_dropin /etc/logrotate.d/andromeda
  fi
}

write_cron() {
  dest=/etc/cron.d/andromeda
  body="# Andromeda — nightly backup + per-site Bee cron
# m h dom mon dow user command
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 3 * * * $OWNER /usr/local/bin/andromeda backup-all >/srv/andromeda/state/backup-all.log 2>&1
7,22,37,52 * * * * $OWNER /usr/local/bin/andromeda cron-all >/srv/andromeda/state/cron-all.log 2>&1
"
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  printf '%s\n' "$body" | write_dropin "$dest"
  as_root chmod 0644 "$dest" 2>/dev/null || true
  echo "cron $dest (backup 03:15, bee cron :07/:22/:37/:52)"
}

write_state() {
  dest=$STARDUST/state/state.json
  if [ -f "$dest" ]; then
    echo "state exists: $dest"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  as_root sh -c "cat > '$dest'" <<EOF
{"role":"$ROLE","platforms":[]}
EOF
  as_root chown "$OWNER:$GROUP" "$dest"
  as_root chmod 0660 "$dest"
  echo "wrote $dest"
}

# First-run for packaged extras. Skip when that app already has a config.
bootstrap_deps() {
	  echo "bootstrap extras (skip when config already exists)"

  if have php-fpm || [ -x /etc/init.d/php-fpm ] || ls /etc/init.d/php*-fpm >/dev/null 2>&1; then
    for s in php8.2-fpm php8.3-fpm php8.4-fpm php7.4-fpm php-fpm; do
      if [ -x "/etc/init.d/$s" ] || [ -d "/lib/systemd/system/$s.service" ]; then
        svc_start "$s"
        break
      fi
    done
  fi

  if have mysql || have mariadb; then
    if [ "$DRYRUN" -eq 0 ]; then
      if mysql -N -e "SELECT 1" >/dev/null 2>&1; then
        echo "mariadb: local socket OK"
      else
        echo "note: mariadb not answering on the unix socket yet — start it, then re-run"
      fi
    fi
  fi

  if have etckeeper; then
    if [ -d /etc/.git ]; then
      echo "etckeeper: /etc already a repo (unchanged)"
    elif [ "$DRYRUN" -eq 1 ]; then
      echo "+ etckeeper init"
    else
      as_root etckeeper init >/dev/null 2>&1 || true
      as_root etckeeper commit -m "andromeda first run" >/dev/null 2>&1 || true
      echo "etckeeper: initialized /etc"
    fi
  fi

  if have needrestart && [ -d /etc/needrestart/conf.d ]; then
    printf '%s
' '$nrconf{restart} = "l";' \
      | write_if_absent /etc/needrestart/conf.d/andromeda.conf
  fi

  if have logwatch; then
    printf '%s
' "Detail = Low" "MailTo = root" \
      | write_if_absent /etc/logwatch/conf/logwatch.conf
  fi

  if have goaccess && [ ! -f /etc/goaccess/goaccess.conf ]; then
    echo "note: goaccess installed — run: goaccess /var/log/apache2/access.log"
  fi

  if have smartd || [ -x /etc/init.d/smartd ] || [ -x /etc/init.d/smartmontools ]; then
    :
  fi
  if have irqbalance || [ -x /etc/init.d/irqbalance ]; then
    :
  fi
  if have haveged || [ -x /etc/init.d/haveged ]; then
    :
  fi

  age_key="$STARDUST/state/secrets/age.key"
  if have age-keygen; then
    if as_root test -f "$age_key"; then
      echo "age: $age_key exists (unchanged)"
    elif [ "$DRYRUN" -eq 1 ]; then
      echo "+ age-keygen -o $age_key"
    else
      as_root mkdir -p "$STARDUST/state/secrets"
      as_root age-keygen -o "$age_key"
      as_root chown "$OWNER:andromeda" "$age_key"
      as_root chmod 0640 "$age_key"
      echo "age: wrote $age_key"
    fi
  fi

  if have msmtp || have msmtp-mta; then
    if [ -f /etc/msmtprc ]; then
      echo "msmtp: /etc/msmtprc exists (unchanged)"
    else
      printf '%s
' \
        "# Andromeda msmtp — fill host/user/password, then: chmod 0640 /etc/msmtprc" \
        "defaults" \
        "auth           on" \
        "tls            on" \
        "tls_starttls   on" \
        "logfile        /var/log/msmtp.log" \
        "account        default" \
        "host           mail.example" \
        "port           587" \
        "from           andromeda@example" \
        "user           andromeda@example" \
        "password       CHANGE-ME" \
        | write_if_absent /etc/msmtprc.example
      if [ "$DRYRUN" -eq 0 ] && [ -t 0 ]; then
        nmail=$(prompt_line "NOTIFY email — where backup/fail mail goes (empty skip)" "" \
          "Andromeda can mail after backup-all or a failed site-check.
This only sets NOTIFY= in /etc/andromeda.conf.
You still copy /etc/msmtprc.example to /etc/msmtprc and put real SMTP there.")
        if [ -n "$nmail" ] && [ -f /etc/andromeda.conf ]; then
          if grep -q '^NOTIFY=' /etc/andromeda.conf; then
            as_root sed -i "s|^NOTIFY=.*|NOTIFY=$nmail|" /etc/andromeda.conf
          else
            as_root sh -c "printf 'NOTIFY=%s\n' '$nmail' >> /etc/andromeda.conf"
          fi
          echo "NOTIFY=$nmail — copy /etc/msmtprc.example to /etc/msmtprc and edit SMTP"
        fi
      else
        echo "msmtp: wrote /etc/msmtprc.example (not live until you copy it)"
      fi
    fi
  fi

  if have git && [ "$DRYRUN" -eq 0 ]; then
    as_root git config --system --get safe.directory "$PLATFORMS" >/dev/null 2>&1 \
      || as_root git config --system --add safe.directory "$PLATFORMS" || true
    as_root -u "$OWNER" git config --global init.defaultBranch devel 2>/dev/null || true
  fi

  if [ "$LOCALHOST" -eq 0 ] && { [ "$ROLE" = test ] || [ "$ROLE" = live ]; }; then
    if have certbot; then
      echo "certbot: installed — obtain certs after site-add, not during install"
    fi
  fi
}


write_etc_conf() {
  dest=/etc/andromeda.conf
  if [ -f "$dest" ]; then
    echo "conf exists: $dest (not overwritten)"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $dest"
    return 0
  fi
  as_root sh -c "cat > '$dest'" <<EOF
# System-wide Andromeda defaults (per-user ~/.andromeda.conf overrides)
STARDUST_ROLE=$ROLE
STARDUST_ROOT=$STARDUST
PLATFORMS=$PLATFORMS
OWNER=$OWNER
ADMIN=$ADMIN
HUMAN=$HUMAN
DAEMON=$DAEMON
GROUP=$GROUP
DIR_MODE=0770
BEE=$BEE_BIN
APACHE_SERVICE=$SVC_APACHE
DB_SERVICE=$SVC_DB
APACHE_RELOAD="$RELOAD_APACHE"
DB_HOST=127.0.0.1
DB_PREFIX=bd_
KEEP_BACKUPS=7
NOTIFY=
HOOKS=$STARDUST/hooks
CSF_ALLOW="10.8.0.0/24 192.168.1.0/24"
EOF
  as_root chmod 0644 "$dest"
  echo "wrote $dest"
}

csf_set() {
  # csf_set KEY VALUE — replace KEY = in /etc/csf/csf.conf
  key=$1
  val=$2
  conf=/etc/csf/csf.conf
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ csf $key = $val"
    return 0
  fi
  [ -f "$conf" ] || return 1
  as_root sed -i "s|^${key} = .*|${key} = \"$val\"|" "$conf"
}

setup_csf() {
  if [ "$LOCALHOST" -eq 1 ]; then
    echo "localhost: skip CSF / WireGuard firewall policy"
    return 0
  fi
  policy=$STARDUST/state/csf-policy.txt
  tcp_in="80"
  if [ "$ROLE" = test ] || [ "$ROLE" = live ]; then
    tcp_in="80,443"
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ write $policy (SSH via WG/LAN only, UDP 51820, TCP $tcp_in)"
  else
    as_root sh -c "cat > '$policy'" <<EOF
# Andromeda CSF policy — remote admin only over WireGuard
# SSH is not in TCP_IN. Allow SSH from these sources in csf.allow:
#   10.8.0.0/24     WireGuard (default)
#   192.168.1.0/24  private LAN (override CSF_ALLOW)
TCP_IN=$tcp_in
UDP_IN=51820
TCP6_IN=
UDP6_IN=51820
TESTING=1
RESTRICT_SYSLOG=3
EOF
    as_root chown "$OWNER:$GROUP" "$policy"
    echo "wrote $policy"
  fi

  if [ "$DO_CSF" -eq 0 ]; then
    echo "note: CSF not applied (pass -F to install/apply)"
    return 0
  fi

  if ! have csf && [ ! -x /usr/sbin/csf ]; then
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ download + install CSF from download.configserver.com"
    else
      work=$(as_root mktemp -d)
      as_root wget -q -O "$work/csf.tgz" https://download.configserver.com/csf.tgz || {
        echo "$PROG: could not fetch CSF tarball; install CSF by hand then re-run -F" >&2
        return 1
      }
      as_root tar -xzf "$work/csf.tgz" -C "$work"
      if [ -x "$work/csf/install.sh" ]; then
        as_root sh "$work/csf/install.sh"
      fi
    fi
  fi

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ apply CSF policy TCP_IN=$tcp_in UDP_IN=51820 TESTING=1"
    echo "+ csf.allow ${CSF_ALLOW:-10.8.0.0/24 192.168.1.0/24}"
    return 0
  fi

  if [ ! -f /etc/csf/csf.conf ]; then
    echo "$PROG: CSF conf missing after install" >&2
    return 1
  fi

  csf_set TCP_IN "$tcp_in"
  csf_set UDP_IN "51820"
  csf_set TCP_OUT "20,21,22,25,53,80,110,113,443,587,993,995,9418"
  csf_set UDP_OUT "53,113,123,51820"
  csf_set TESTING "1"
  csf_set RESTRICT_SYSLOG "3"
  # Drop 22 from the public inbound list if a stock install put it back.
  if grep -q 'TCP_IN = ".*22' /etc/csf/csf.conf; then
    csf_set TCP_IN "$tcp_in"
  fi

  for src in ${CSF_ALLOW:-10.8.0.0/24 192.168.1.0/24}; do
    if ! grep -q "$src" /etc/csf/csf.allow 2>/dev/null; then
      as_root sh -c "echo '$src # Andromeda SSH/WG' >> /etc/csf/csf.allow"
    fi
  done

  if have csf; then
    as_root csf -r || true
  fi
  echo "CSF applied with TESTING=1. After you confirm WG SSH still works:"
  echo "  sudo sed -i 's/^TESTING = .*/TESTING = \"0\"/' /etc/csf/csf.conf && sudo csf -r"
}

# Long flags getopts cannot see.
NEWARGS=""
for arg in "$@"; do
  case $arg in
    --localhost|-lh)
      LOCALHOST=1
      ROLE=devel
      DO_CSF=0
      ;;
    --human)
      # next token consumed below if present as --human=NAME form
      ;;
    --human=*)
      HUMAN=${arg#--human=}
      ;;
    *)
      NEWARGS="$NEWARGS $arg"
      ;;
  esac
done
# shellcheck disable=SC2086
eval set -- $NEWARGS

while getopts 'nFm:u:g:a:H:h' opt; do
  case $opt in
    n) DRYRUN=1 ;;
    F) DO_CSF=1 ;;
    m) ROLE=$OPTARG ;;
    u) OWNER=$OPTARG ;;
    a) ADMIN=$OPTARG ;;
    H) HUMAN=$OPTARG ;;
    g) GROUP=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$LOCALHOST" -eq 1 ]; then
  ROLE=devel
  DO_CSF=0
fi

if [ -z "$HUMAN" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    HUMAN=$SUDO_USER
  elif [ "$(id -u)" -ne 0 ] && [ -n "${USER:-}" ] && [ "$USER" != root ]; then
    HUMAN=$USER
  fi
fi
if [ "$HUMAN" = "$OWNER" ] || [ "$HUMAN" = "$ADMIN" ]; then
  HUMAN=""
fi

ROLE=$(normalize_role "$ROLE")
if [ -z "$ROLE" ]; then
  echo "$PROG: unknown role. Use devel, test, or live." >&2
  exit 2
fi

detect_os

ensure_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "install gh"
    if [ "$DRYRUN" -eq 1 ]; then
      echo "+ apt-get install -y gh"
    else
      run_root apt-get install -y gh || {
        echo "$PROG: cannot install gh" >&2
        return 1
      }
    fi
  fi
  if gh auth status >/dev/null 2>&1; then
    echo "gh: authenticated"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ gh auth login"
    return 0
  fi
  echo "gh is not logged in. Complete the login. The install waits."
  gh auth login
  gh auth status >/dev/null 2>&1 || {
    echo "$PROG: gh auth did not complete" >&2
    return 1
  }
  echo "gh: authenticated"
}

ensure_git_config() {
  name=$(git config --global user.name || true)
  email=$(git config --global user.email || true)
  if [ -z "$name" ]; then
    printf "git user.name: "
    read -r name
    git config --global user.name "$name"
  fi
  if [ -z "$email" ]; then
    printf "git user.email: "
    read -r email
    git config --global user.email "$email"
  fi
  echo "git: $(git config --global user.name) <$(git config --global user.email)>"
}

ensure_gh || exit 1
ensure_git_config
detect_init
detect_group
detect_services

# www-admin is the file group. A login of that name is opt-in via -a,
# and only when the name is not the group.
if [ -n "$ADMIN" ] && [ "$ADMIN" = "$GROUP" ]; then
  echo "note: -a $ADMIN is the file group; not creating a login of that name"
  ADMIN=""
fi
if [ -n "$ADMIN" ]; then
  echo "extra admin login: $ADMIN"
else
  echo "file group: $GROUP (no extra admin login; pass -a NAME to add one)"
fi
if [ -z "$HUMAN" ]; then
  echo "note: no invoking login to add to Andromeda groups (pass -H NAME)"
else
  echo "operator login: $HUMAN (groups only: $GROUP,andromeda,$OWNER — not sudo)"
fi

HOSTN=$(hostname 2>/dev/null || echo unknown)
echo "$PROG role=$ROLE localhost=$LOCALHOST host=$HOSTN os=$OS_ID pkg=$PKG init=$INIT owner=$OWNER admin=${ADMIN:--} human=${HUMAN:--} group=$GROUP dryrun=$DRYRUN"

ensure_git_user() {
  if id git >/dev/null 2>&1; then
    echo "user ok: git"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ adduser --system --group --disabled-password git"
    return 0
  fi
  if have adduser; then
    run_root adduser --system --shell /bin/bash --gecos "Git Daemon User" --group --disabled-password git || return 1
  else
    run_root groupadd --system git 2>/dev/null || true
    run_root useradd -r -m -d /home/git -s /bin/bash -g git -c "Git Daemon User" git || return 1
  fi
  echo "system user: git"
}

# --- run app install phases -------------------------------------------
# Helpers live in this file. Each apps/<name>/install.sh is one phase.
# Order comes from apps/MANIFEST (not directory sort). modules/NN-*.sh
# remain as thin shims that source the same files.

run_app_phase() {
  app=$1
  inst=$HERE/apps/$app/install.sh
  if [ ! -f "$inst" ]; then
    echo "$PROG: apps/$app/install.sh missing" >&2
    return 1
  fi
  echo "==> app $app"
  # shellcheck disable=SC1090
  . "$inst"
}

ensure_git_user || { echo "$PROG: cannot create git user" >&2; exit 1; }
ran=0
if [ -f "$HERE/apps/MANIFEST" ]; then
  while IFS= read -r app || [ -n "$app" ]; do
    case $app in
      ''|\#*) continue ;;
    esac
    [ -f "$HERE/apps/$app/install.sh" ] || continue
    if ! run_app_phase "$app"; then
      echo "$PROG: app $app failed" >&2
      exit 1
    fi
    ran=$((ran + 1))
  done < "$HERE/apps/MANIFEST"
elif [ -d "$HERE/modules" ]; then
  echo "$PROG: apps/MANIFEST missing — falling back to modules/"
  for module in "$HERE/modules/"[0-9][0-9]-*.sh; do
    [ -f "$module" ] || continue
    echo "==> $(basename "$module")"
    # shellcheck disable=SC1090
    if ! . "$module"; then
      echo "$PROG: module $(basename "$module") failed" >&2
      exit 1
    fi
    ran=$((ran + 1))
  done
fi

if [ "$ran" -eq 0 ]; then
  echo "$PROG: no app install phases found (apps/*/install.sh)" >&2
  exit 1
fi

install_charm

write_wg_sudoers
echo "done."

# Shell wrapper so @host:plat/site is not eaten.
shell_name=$(basename "${SHELL:-/bin/sh}")
rc=""
case $shell_name in
  zsh) rc="$HOME/.zshrc" ;;
  bash) rc="$HOME/.bashrc" ;;
esac
# Global zsh function. @ is eaten before any binary runs, so this
# must live in zsh, on the system path, not in the checkout.
wrap="$HOME/.zsh_andromeda"
cat > "$wrap" << 'WRAP'
andromeda() {
  noglob command andromeda "$@"
}
WRAP
if [ "$shell_name" = "zsh" ]; then
  line="source \"$HOME/.zsh_andromeda\""
  if [ -n "$rc" ] && ! grep -q '.zsh_andromeda' "$rc" 2>/dev/null; then
    echo "$line" >> "$rc"
  fi
  echo "shell: zsh"
  echo "file:  $wrap"
  echo "then:  source $wrap"
  else
    echo "shell: bash"
    echo "@ is not special in bash. No wrapper needed."
    echo "cmd:   andromeda site pull @bjorn:ecom/kl_test -> @knarr:ecom/kl_devel"
  fi
fi

echo "$OWNER is a system account (nologin, locked). No passwd."
if [ -n "$HUMAN" ]; then
  echo "refresh groups: exec su - $HUMAN"
  echo "confirm:        id $HUMAN   # must list $GROUP and andromeda, not require sudo"
fi
echo "check host:    andromeda doctor"
echo "list sites:    andromeda list"
echo "Bee: bee --root=$PLATFORMS/<platform>/web --site=<product> <cmd>"
echo "reload apache with: $RELOAD_APACHE"
