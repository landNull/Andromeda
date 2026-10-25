# shellcheck shell=sh
# test — preflight any command. Heal what is safe, then run only if the check passes.

cmd_test() {
  # test <command...>
  # Extracts a platform/product when present, runs site-debug, heals
  # healable failures, re-checks, and only then runs the real command.
  if [ $# -eq 0 ]; then
    echo "usage: $PROG test <command> [args…]" >&2
    exit 2
  fi
  plat=""
  prod=""
  # Look for two consecutive non-flag tokens after a site-related verb.
  prev=""
  for a in "$@"; do
    case $a in
      -*) continue ;;
      site|pull|heal|check|backup|restore|clone|add|debug) prev=$a; continue ;;
    esac
    if [ -z "$plat" ]; then
      plat=$a
    elif [ -z "$prod" ]; then
      prod=$a
      break
    fi
    prev=$a
  done

  echo "test: preflight $*"
  if [ -n "${ANDROMEDA_SPEAK:-}" ]; then
    printf 'SPEAK: Preflighting %s\n' "$*"
  fi
  if [ -n "$plat" ] && [ -n "$prod" ] && [ -d "$PLATFORMS/$plat" ]; then
    echo "test: site $plat/$prod"
    out=$(cmd_site_debug "$plat" "$prod" 2>&1) || true
    echo "$out"
    if printf '%s\n' "$out" | grep -q "FAIL"; then
      echo "test: failures found, attempting heal"
      cmd_site_heal "$plat" "$prod" || true
      out=$(cmd_site_debug "$plat" "$prod" 2>&1) || true
      echo "$out"
      if printf '%s\n' "$out" | grep -q "FAIL"; then
        echo "test: still failing after heal — refusing to run" >&2
        if [ -n "${ANDROMEDA_SPEAK:-}" ]; then
          printf 'SPEAK: Still failing after heal. Refusing to run.\n'
          printf '%s\n' '{"module":"test","status":"fail","what":"still failing after heal"}'
        fi
        return 1
      fi
    fi
    echo "test: site OK"
    if [ -n "${ANDROMEDA_SPEAK:-}" ]; then
      printf 'SPEAK: Site OK. Running the command.\n'
    fi
  else
    echo "test: no site target, running doctor"
    cmd_doctor || return 1
  fi

  echo "test: running $*"
  # Re-enter the dispatcher with the original command.
  # Avoid recursion if the user already typed "test".
  case ${1:-} in
    test) shift ;;
  esac
  cmd=$1
  shift
  # Re-apply verb-first so "test pull site A to B" becomes site-pull.
  case $cmd in
    pull) case ${1:-} in site) cmd=site-pull; shift ;; esac ;;
    heal) case ${1:-} in site) cmd=site-heal; shift ;; all) cmd=heal-all; shift ;; esac ;;
    check) case ${1:-} in site) cmd=site-check; shift ;; esac ;;
  esac
  dispatch "$@"
}
