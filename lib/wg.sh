# shellcheck shell=sh
# WireGuard on demand. Use it if it is up. Start it if it is not.
# Only stop a tunnel this process started.
#
# Detect "already up" without sudo. sudo is only for wg-quick up/down.
# sudoers allows wg and wg-quick at their real paths. It does not allow
# grep or cat of the conf.

WG_STARTED=0

wg_bin() {
  command -v wg 2>/dev/null || true
}

wg_quick_bin() {
  command -v wg-quick 2>/dev/null || true
}

# True when the wg0 interface exists. No sudo.
wg_is_up() {
  if [ -d /sys/class/net/wg0 ]; then
    return 0
  fi
  if command -v ip >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wg_up() {
  # Under proot there is no /dev/net/tun and no CAP_NET_ADMIN, so a wg
  # interface can never exist. Reach hosts directly over SSH instead:
  # set TUNNEL_<HOST>=<public-host> and SSH_PORT in /etc/andromeda.conf.
  if [ "${ANDROMEDA_PROOT:-0}" -eq 1 ]; then
    echo "proot: wg impossible (no tun) — using direct SSH"
    WG_STARTED=0
    return 0
  fi
  if wg_is_up; then
    echo "wg already up"
    WG_STARTED=0
    return 0
  fi

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "$PROG: no /etc/wireguard/wg0.conf" >&2
    return 1
  fi

  quick=$(wg_quick_bin)
  if [ -z "$quick" ]; then
    echo "$PROG: wg-quick not found" >&2
    return 1
  fi

  # Endpoint check only when the conf is readable. Do not sudo grep it.
  if [ -r /etc/wireguard/wg0.conf ]; then
    if ! grep -q "^Endpoint = [^:][^:]*:[0-9]" /etc/wireguard/wg0.conf; then
      echo "$PROG: Endpoint line missing or wrong in /etc/wireguard/wg0.conf" >&2
      echo "$PROG: want Endpoint = 162.246.254.168:51820" >&2
      return 1
    fi
  fi

  echo "wg up"
  if ! sudo -n "$quick" up wg0 >/tmp/andromeda-wg.out 2>/tmp/andromeda-wg.err; then
    if grep -q "password is required" /tmp/andromeda-wg.err 2>/dev/null; then
      echo "$PROG: sudo wants a password for $quick" >&2
      echo "$PROG: /etc/sudoers.d/andromeda-wg must allow NOPASSWD for:" >&2
      echo "$PROG:   $quick" >&2
      wg=$(wg_bin)
      [ -n "$wg" ] && echo "$PROG:   $wg" >&2
      echo "$PROG: group www-admin. After adding yourself: exec su - \$USER" >&2
    else
      cat /tmp/andromeda-wg.err >&2
    fi
    rm -f /tmp/andromeda-wg.out /tmp/andromeda-wg.err
    return 1
  fi
  rm -f /tmp/andromeda-wg.out /tmp/andromeda-wg.err
  WG_STARTED=1
}

wg_down() {
  if [ "$WG_STARTED" -ne 1 ]; then
    return 0
  fi
  if ! wg_is_up; then
    WG_STARTED=0
    return 0
  fi
  quick=$(wg_quick_bin)
  if [ -z "$quick" ]; then
    WG_STARTED=0
    return 0
  fi
  echo "wg down"
  sudo -n "$quick" down wg0 >/dev/null 2>&1 || true
  WG_STARTED=0
}
