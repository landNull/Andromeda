# WireGuard on demand. Use it if it is up. Start it if it is not.
# Only stop a tunnel this process started.

WG_STARTED=0

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
  if ! sudo -n grep -q "^Endpoint = [^:][^:]*:[0-9]" /etc/wireguard/wg0.conf; then
    echo "$PROG: cannot read Endpoint in /etc/wireguard/wg0.conf" >&2
    echo "$PROG: want Endpoint = 162.246.254.168:51820" >&2
    return 1
  fi
  echo "wg up"
  sudo -n wg-quick up wg0 || return 1
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
