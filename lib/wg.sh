# WireGuard on demand. Up before a remote command, down after.

wg_up() {
  if wg show wg0 >/dev/null 2>&1; then
    return 0
  fi
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "$PROG: no /etc/wireguard/wg0.conf" >&2
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
