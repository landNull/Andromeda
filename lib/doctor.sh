# shellcheck shell=sh

cmd_env() {
  cat <<EOF
ANDROMEDA_ROLE=$ANDROMEDA_ROLE
ANDROMEDA_ROOT=$ANDROMEDA_ROOT
PLATFORMS=$PLATFORMS
OWNER=$OWNER
ADMIN=$ADMIN
HUMAN=$HUMAN
DAEMON=$DAEMON
GROUP=$GROUP
DIR_MODE=$DIR_MODE
BEE=$BEE
APACHE_RELOAD=$APACHE_RELOAD
DB_HOST=$DB_HOST
DB_PREFIX=$DB_PREFIX
KEEP_BACKUPS=$KEEP_BACKUPS
NOTIFY=$NOTIFY
HOOKS=$HOOKS
LIBDIR=$LIBDIR
EOF
}

cmd_list() {
  if [ ! -d "$PLATFORMS" ]; then
    echo "$PROG:$PLATFORMS missing. Run andromeda-install.sh first." >&2
    exit 1
  fi
  found=0
  for p in "$PLATFORMS"/*; do
    [ -d "$p" ] || continue
    name=${p##*/}
    case $name in .*) continue ;; esac
    found=1
    root=""
    if [ -d "$p/web" ]; then
      root="$p/web"
    elif [ -f "$p/index.php" ]; then
      root="$p"
    fi
    products=""
    if [ -n "$root" ] && [ -d "$root/sites" ]; then
      for s in "$root/sites"/*; do
        [ -d "$s" ] || continue
        base=${s##*/}
        case $base in default|all) continue ;; esac
        if [ -f "$s/settings.php" ] \vert{}\vert{} [ -f "$s/settings.local.php" ]; then
          products="$products$base"
        fi
      done
    fi
    gitb=""
    if [ -e "$p/.git" ] && have git; then
      gitb=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi
    printf 'platform  %-20s' "$name"
    [ -n "$gitb" ] && printf ' branch=\%s' "$gitb"
    [ -n "$root" ] && printf ' root=\%s' "$root"
    printf '\n'
    if [ -n "$products" ]; then
      printf '  products%s\n' "$products"
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "(no platforms yet under $PLATFORMS)"
  fi
}


cmd_platform_list() {
  quiet=0
  fmt=""
  while [ $# -gt 0 ]; do
    case $1 in
      -q) quiet=1; shift ;;
      --format) fmt=$2; shift 2 ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  if [ ! -d "$PLATFORMS" ]; then
    echo "$PROG: $PLATFORMS missing" >&2
    exit 1
  fi
  tty=0
  [ -t 1 ] && tty=1
  found=0
  if [ "$tty" -eq 1 ] && [ "$quiet" -eq 0 ] && [ "$fmt" != json ]; then
    printf '%-20s %s\n' PLATFORM BRANCH
  fi
  for p in "$PLATFORMS"/*; do
    [ -d "$p" ] || continue
    name=${p##*/}
    case $name in .*) continue ;; esac
    found=1
    gitb=""
    if [ -e "$p/.git" ] && have git; then
      gitb=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi
    if [ "$fmt" = json ]; then
      printf '{"platform":"%s","branch":"%s"}\n' "$name" "$gitb"
    elif [ "$quiet" -eq 1 ] || [ "$tty" -eq 0 ]; then
      printf '%s\n' "$name"
    else
      printf '%-20s %s\n' "$name" "$gitb"
    fi
  done
  [ "$found" -eq 0 ] && exit 0
}

cmd_site_list() {
  quiet=0
  fmt=""
  role=""
  while [ $# -gt 0 ]; do
    case $1 in
      -q) quiet=1; shift ;;
      --format) fmt=$2; shift 2 ;;
      --role) role=$2; shift 2 ;;
      -*) echo "$PROG: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  if [ ! -d "$PLATFORMS" ]; then
    echo "$PROG: $PLATFORMS missing" >&2
    exit 1
  fi
  tty=0
  [ -t 1 ] && tty=1
  found=0
  if [ "$tty" -eq 1 ] && [ "$quiet" -eq 0 ] && [ "$fmt" != json ]; then
    printf '%-20s %-16s %s\n' PLATFORM SITE ROLE
  fi
  for p in "$PLATFORMS"/*; do
    [ -d "$p/web/sites" ] || continue
    name=${p##*/}
    for s in "$p/web/sites"/*; do
      [ -d "$s" ] || continue
      base=${s##*/}
      case $base in default|all) continue ;; esac
      if [ -f "$s/settings.php" ] || [ -f "$s/settings.local.php" ]; then
        found=1
        if [ "$fmt" = json ]; then
          printf '{"platform":"%s","site":"%s","role":"%s"}\n' "$name" "$base" "${role:-$ANDROMEDA_ROLE}"
        elif [ "$quiet" -eq 1 ] || [ "$tty" -eq 0 ]; then
          printf '%s/%s\n' "$name" "$base"
        else
          printf '%-20s %-16s %s\n' "$name" "$base" "${role:-$ANDROMEDA_ROLE}"
        fi
      fi
    done
  done
  [ "$found" -eq 0 ] && exit 0
}

cmd_doctor() {
  fail=0
  echo "Andromeda doctor"
  echo "role=${ANDROMEDA_ROLE:-unset} host=$(hostname 2>/dev/null || echo unknown)"

  if id "$OWNER" >/dev/null 2>&1; then ok "user $OWNER"; else bad "user $OWNER missing"; fail=1; fi
  if [ -n "$ADMIN" ]; then
    if id "$ADMIN" >/dev/null 2>&1; then ok "user $ADMIN"; else bad "user $ADMIN missing"; fail=1; fi
  else
    note "no extra admin login (group $GROUP is the web-admin grant)"
  fi
  if getent group "$GROUP" >/dev/null 2>&1; then ok "group $GROUP"; else bad "group $GROUP missing"; fail=1; fi
  if getent group andromeda >/dev/null 2>&1; then ok "group andromeda"; else bad "group andromeda missing"; fail=1; fi
  me=$(id -un)
  groups_me=$(id -nG 2>/dev/null || true)
  note "running as $me groups=$groups_me"
  if echo " $groups_me " | grep -q " sudo "; then
    note "in group sudo — installer did not add this; OS policy"
  fi
  if echo " $groups_me " \vert{} grep -q " $GROUP "; then
    ok "in web group $GROUP (0770 write)"
  else
    bad "not in $GROUP — usermod -aG$GROUP,$OWNER$me"; fail=1
  fi
  if echo " $groups_me " | grep -q " andromeda "; then
    ok "in group andromeda (secrets)"
  else
    note "not in andromeda — secrets stay unreadable"
  fi
  if [ -f /etc/sudoers.d/andromeda-deploy ]; then ok "sudoers deploy+%${GROUP}"; else note "sudoers andromeda-deploy missing"; fi
  owner_home=$(getent passwd "$OWNER" 2>/dev/null | cut -d: -f6)
  if [ -n "$owner_home" ] && [ -d "$owner_home" ]; then
    ok "owner home $owner_home"
  else
    note "owner home missing (expect $ANDROMEDA_ROOT/home)"
  fi

  for d in "$ANDROMEDA_ROOT" "$ANDROMEDA_ROOT/backups" "$ANDROMEDA_ROOT/bin" "$ANDROMEDA_ROOT/state" "$PLATFORMS"; do
    if [ -d "$d" ]; then ok "dir $d"; else bad "dir $d missing"; fail=1; fi
  done

  if have "$BEE" || have bee; then
    ok "bee $(command -v bee 2>/dev/null || command -v "$BEE")"
  else
    bad "bee not on PATH"; fail=1
  fi
  if have crdir; then ok "crdir $(command -v crdir)"; else bad "crdir not on PATH"; fail=1; fi
  if have newfeature; then ok "newfeature $(command -v newfeature)"; else note "newfeature not on PATH"; fi
  if have git; then ok "git"; else bad "git missing"; fail=1; fi
  if git_template_ok "${ANDROMEDA_GIT_TEMPLATE:-}"; then
    ok "git template $ANDROMEDA_GIT_TEMPLATE"
  else
    note "ANDROMEDA_GIT_TEMPLATE empty — platform-add falls back to bee dl-core"
  fi
  if [ -x /usr/local/sbin/andromeda-priv ]; then ok "andromeda-priv"; else note "andromeda-priv missing"; fi
  if have setfacl; then ok "setfacl"; else note "acl package missing"; fi
  if have getfacl && [ -d "$PLATFORMS" ]; then
    eff=$(getfacl -p "$PLATFORMS" 2>/dev/null | grep '#effective' || true)
    if echo "$eff" | grep -q 'r--'; then
      bad "ACL mask effective r-- on $PLATFORMS — run andromeda-priv setacl$PLATFORMS"
      fail=1
    else
      ok "ACL mask on $PLATFORMS not clipped to r--"
    fi
  fi
  if have php-fpm || [ -x /etc/init.d/php*-fpm ] || ls /etc/init.d/php*-fpm >/dev/null 2>&1; then
    ok "php-fpm present"
  else
    note "php-fpm not installed (mod_php still works)"
  fi

  if have apache2ctl || have apachectl || [ -x /etc/init.d/apache2 ] || [ -x /etc/init.d/httpd ]; then
    ok "apache present"
  else
    bad "apache not found"; fail=1
  fi
  if have mysql || have mariadb; then ok "mysql client present"; else bad "mysql/mariadb client missing"; fail=1; fi

  if have csf || [ -x /usr/sbin/csf ]; then
    ok "csf present"
  else
    note "csf not installed (andromeda-install.sh -F)"
  fi
  if [ -d /etc/wireguard ] || have wg; then
    ok "wireguard tools or /etc/wireguard"
  else
    note "wireguard not detected — remote SSH should still be via 10.8.0.0/24"
  fi

  if [ -f /etc/sudoers.d/andromeda-deploy ]; then ok "sudoers deploy"; else note "sudoers deploy snippet missing"; fi
  if [ -n "${LIBDIR:-}" ] && [ -f "$LIBDIR/common.sh" ]; then ok "lib $LIBDIR"; else bad "andromeda-lib missing"; fail=1; fi

  phpbin=$(command -v php 2>/dev/null || true)
  if [ -n "$phpbin" ]; then ok "php $phpbin"; else bad "php missing"; fail=1; fi

  if [ "$fail" -ne 0 ]; then
    echo "doctor: NOT READY"
    return 1
  fi
  echo "doctor: READY"
  return 0
}
