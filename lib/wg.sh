# shellcheck shell=sh
# WireGuard on demand. Use it if it is up. Start it if it is not.
# Only stop a tunnel this process started.
#
# sudoers allows only: wg, wg-quick
# Do not sudo grep or cat the conf. That is not in the rule and will
# always ask for a password.

WG_STARTED=0

wg_sudo_ok() {
  # True when passwordless sudo for wg works.
  sudo -n true >/dev/null 2>&1 && return 0
  sudo -n wg show >/dev/null 2>&1 && return 0
  return 1
}

wg_up() {
  if sudo -n wg show wg0 >/dev/null 2>&1; then
    echo "wg already up"
    WG_STARTED=0
    return 0
  fi

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "$PROG: no /etc/wireguard/wg0.conf" >&2
    return 1
  fi

  # Endpoint check only when the conf is readable without sudo.
  # The designed sudoers rule does not allow grep, so a sudo grep
  # always fails with "a password is required" and hides the real state.
  if [ -r /etc/wireguard/wg0.conf ]; then
    if ! grep -q "^Endpoint = [^:][^:]*:[0-9]" /etc/wireguard/wg0.conf; then
      echo "$PROG: Endpoint line missing or wrong in /etc/wireguard/wg0.conf" >&2
      echo "$PROG: want Endpoint = 162.246.254.168:51820" >&2
      return 1
    fi
  fi

  echo "wg up"
  if ! sudo -n wg-quick up wg0 2>/tmp/andromeda-wg.err; then
    if grep -q "password is required" /tmp/andromeda-wg.err 2>/dev/null; then
      echo "$PROG: sudo wants a password for wg-quick" >&2
      echo "$PROG: install /etc/sudoers.d/andromeda-wg:" >&2
      echo "$PROG:   %www-admin ALL=(root) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick" >&2
      echo "$PROG: confirm you are in group www-admin, then: exec su - \$USER" >&2
    else
      cat /tmp/andromeda-wg.err >&2
    fi
    rm -f /tmp/andromeda-wg.err
    return 1
  fi
  rm -f /tmp/andromeda-wg.err
  WG_STARTED=1
}

wg_down() {
  if [ "$WG_STARTED" -ne 1 ]; then
    return 0
  fi
  if sudo -n wg show wg0 >/dev/null 2>&1; then
    echo "wg down"
    sudo -n wg-quick down wg0 || true
  fi
  WG_STARTED=0
}
