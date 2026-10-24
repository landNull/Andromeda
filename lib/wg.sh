# WireGuard on demand. Up before a remote command, down after.

wg_up() {
  if wg show wg0 >/dev/null 2>&1; then
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
  wg-quick up wg0
}

wg_down() {
  if wg show wg0 >/dev/null 2>&1; then
    echo "wg down"
    wg-quick down wg0 || true
  fi
}
