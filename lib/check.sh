# shellcheck shell=sh
# site-check — post-upgrade smoke test. Does not restore on failure.

dump_apache_log() {
  for f in \
    /var/log/apache2/${platform}-${ANDROMEDA_ROLE}-error.log \
    /var/log/apache2/error.log \
    /var/log/httpd/error_log
  do
    if [ -f "$f" ]; then
      echo "---- tail $f"
      tail -n 20 "$f" 2>/dev/null || as_root tail -n 20 "$f" || true
      return 0
    fi
  done
  note "no apache error log found"
}

guess_host() {
  product=$1
  # first $sites['host'] = 'product' in sites.php
  sites=$web/sites/sites.php
  if [ -f "$sites" ]; then
    h=$(sed -n "s/.*sites\['\([^']*\)'\] *= *'$product'.*/\1/p" "$sites" | head -n 1)
    if [ -n "$h" ]; then
      printf '%s' "$h"
      return 0
    fi
  fi
  printf '%s.%s' "$product" "$ANDROMEDA_ROLE"
}

http_check() {
  url=$1
  if ! have curl; then
    note "curl missing — skip HTTP $url"
    return 0
  fi
  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ curl -sS -o /tmp/andromeda-check.body -w %{http_code} $url"
    return 0
  fi
  body=/tmp/andromeda-check.$$.body
  code=$(curl -sS -L --max-time 20 -o "$body" -w '%{http_code}' "$url" || echo 000)
  badpat='Parse error|Fatal error|PDOException|DatabaseException|White Screen|Backdrop already installed'
  if [ "$code" = 000 ]; then
    bad "HTTP $url unreachable"
    dump_apache_log
    rm -f "$body"
    return 1
  fi
  case $code in
    5??)
      bad "HTTP $url -> $code"
      dump_apache_log
      rm -f "$body"
      return 1
      ;;
  esac
  if [ ! -s "$body" ]; then
    bad "HTTP $url empty body ($code)"
    dump_apache_log
    rm -f "$body"
    return 1
  fi
  if grep -Eiq "$badpat" "$body"; then
    bad "HTTP $url body looks like a WSOD / installer ($code)"
    dump_apache_log
    rm -f "$body"
    return 1
  fi
  ok "HTTP $url -> $code"
  rm -f "$body"
  return 0
}

cmd_site_check() {
  host=""
  while [ $# -gt 0 ]; do
    case $1 in
      --host) host=$2; shift 2 ;;
      *) break ;;
    esac
  done
  resolve_site "${1:-}" "${2:-}"
  if [ -z "$host" ]; then
    host=$(guess_host "$product")
  fi

  fail=0
  echo "check $platform/$product host=$host"
  bee=$(bee_bin)

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ $bee --root=$web --site=$product status"
    echo "+ $bee --root=$web --site=$product update-db"
    echo "+ $bee --root=$web --site=$product log"
    echo "+ HTTP http://$host/ and /user/login"
    return 0
  fi

  if as_root -u "$OWNER" "$bee" --root="$web" --site="$product" status >/tmp/andromeda-check.status 2>&1; then
    ok "bee status"
  else
    bad "bee status failed"
    sed -n '1,20p' /tmp/andromeda-check.status >&2 || true
    fail=1
  fi

  # update-db without applying: look at listing. Bee may prompt; feed "n".
  if printf 'n\n' | as_root -u "$OWNER" "$bee" --root="$web" --site="$product" update-db >/tmp/andromeda-check.updb 2>&1; then
    if grep -Eiq 'pending|available update' /tmp/andromeda-check.updb && \
       ! grep -Eiq 'no pending|no database updates|there are no' /tmp/andromeda-check.updb; then
      bad "pending database updates remain"
      fail=1
    else
      ok "no pending updb"
    fi
  else
    note "bee update-db returned non-zero (inspect /tmp/andromeda-check.updb)"
  fi

  if as_root -u "$OWNER" "$bee" --root="$web" --site="$product" log >/tmp/andromeda-check.log 2>&1; then
    if grep -Eiq 'emergency|alert|critical|^error' /tmp/andromeda-check.log; then
      note "watchdog has error-class lines (see bee log)"
    else
      ok "bee log (no obvious critical/error in listing)"
    fi
  else
    note "bee log skipped or failed"
  fi

  http_check "http://$host/" || fail=1
  http_check "http://$host/user/login" || fail=1

  if [ "$fail" -ne 0 ]; then
    snap=$(latest_backup "$platform" "$product" "$ANDROMEDA_ROLE" 2>/dev/null || true)
    echo "check: FAIL $platform/$product"
    notify_fail "site-check FAIL $platform/$product host=$host"
    if [ -n "$snap" ]; then
      echo "last backup: $snap"
      echo "restore is manual: $PROG site-restore --from $snap $platform $product"
    fi
    run_hooks post-check "$platform" "$product" 1
    return 1
  fi
  echo "check: OK $platform/$product"
  run_hooks post-check "$platform" "$product" 0
  return 0
}
