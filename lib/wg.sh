# WireGuard on demand. Use it if it is up. Start it if it is not.
# Only stop a tunnel this process started.

WG_STARTED=0

wg_up() {
  if wg show wg0 >/dev/null 2>&1; then
    echo "wg already up"
    WG_STARTED=0
    return 0
  fi
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "$PROG: no /etc/wireguard/wg0.conf" >&2
    return 1
  fi
  if ! grep -q "^Endpoint = [^:][^:]*:51820" /etc/wireguard/wg0.conf; then
    echo "$PROG: Endpoint in /etc/wireguard/wg0.conf has no host" >&2
    echo "$PROG: want Endpoint = knarr:51820" >&2
    return 1
  fi
  echo "wg up"
  wg-quick up wg0 || return 1
  WG_STARTED=1
}

wg_down() {
  if [ "$WG_STARTED" -ne 1 ]; then
    return 0
  fi
  if wg show wg0 >/dev/null 2>&1; then
    echo "wg down"
    wg-quick down wg0 || true
  fi
  WG_STARTED=0
}
