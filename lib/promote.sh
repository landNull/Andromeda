# shellcheck shell=sh
# promote PLATFORM --to test|live
# Fast-forward the checkout to origin/<branch-for-that-role>. Not for role=devel.

cmd_promote() {
  to=""
  name=""
  while [ $# -gt 0 ]; do
    case $1 in
      --to)
        if [ -z "${2:-}" ]; then
          echo "$PROG: --to needs test or live" >&2
          exit 2
        fi
        to=$2
        shift 2
        ;;
      -*)
        echo "$PROG: unknown flag $1" >&2
        echo "usage: $PROG promote PLATFORM --to test|live" >&2
        exit 2
        ;;
      *)
        if [ -n "$name" ]; then
          echo "$PROG: unexpected extra argument '$1'" >&2
          exit 2
        fi
        name=$1
        shift
        ;;
    esac
  done

  name=$(slug "$name")
  to=$(printf '%s' "$to" | tr '[:upper:]' '[:lower:]')

  if [ -z "$name" ] || [ -z "$to" ]; then
    echo "usage: $PROG promote PLATFORM --to test|live" >&2
    echo "Example: $PROG promote mysite --to test" >&2
    echo "Run on the test/live checkout, not on a devel workstation." >&2
    exit 2
  fi

  case $to in
    test|live) ;;
    devel)
      echo "$PROG: refuse --to devel (devel is where you commit, not where you promote)" >&2
      exit 2
      ;;
    *)
      echo "$PROG: --to must be test or live (got '$to')" >&2
      exit 2
      ;;
  esac

  if [ "$ANDROMEDA_ROLE" = devel ]; then
    echo "$PROG: this host role is devel. promote is for test/live hosts." >&2
    echo "$PROG: commit and push from devel, then run promote on the target host." >&2
    exit 1
  fi

  if ! have git; then
    echo "$PROG: git not on PATH" >&2
    exit 1
  fi

  dest=""
  if [ -d "$PLATFORMS/${name}-${to}/web" ]; then
    dest="${name}-${to}"
  elif [ -d "$PLATFORMS/$name/web" ]; then
    dest="$name"
  else
    echo "$PROG: no checkout $PLATFORMS/${name}-${to} or $PLATFORMS/$name" >&2
    echo "$PROG: create it first: $PROG platform-add ${name}-${to} --git URL --branch $(branch_for_role "$to")" >&2
    exit 1
  fi

  root=$PLATFORMS/$dest
  if [ ! -e "$root/.git" ]; then
    echo "$PROG: $root is not a git checkout" >&2
    exit 1
  fi

  if ! git -C "$root" remote get-url origin >/dev/null 2>&1; then
    echo "$PROG: $root has no 'origin' remote" >&2
    exit 1
  fi

  dirty=$(git -C "$root" status --porcelain 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "$PROG: $root has uncommitted changes — commit or stash before promote" >&2
    git -C "$root" status --short >&2 || true
    exit 1
  fi

  br=$(branch_for_role "$to")
  echo "promote $name -> $to branch=$br checkout=$dest origin=$(git -C "$root" remote get-url origin)"

  if [ "$DRYRUN" -eq 1 ]; then
    echo "+ git -C $root fetch origin"
    echo "+ git -C $root checkout $br"
    echo "+ git -C $root merge --ff-only origin/$br"
    echo "+ platform-upgrade $dest --no-pull"
    return 0
  fi

  if ! as_root -u "$OWNER" git -C "$root" fetch origin; then
    echo "$PROG: git fetch origin failed (SSH key for the git host?)" >&2
    exit 1
  fi

  if ! git -C "$root" rev-parse --verify "origin/$br" >/dev/null 2>&1; then
    echo "$PROG: origin/$br does not exist after fetch" >&2
    echo "$PROG: push that branch from the devel host first." >&2
    exit 1
  fi

  if ! as_root -u "$OWNER" git -C "$root" checkout "$br"; then
    if ! as_root -u "$OWNER" git -C "$root" checkout -B "$br" "origin/$br"; then
      echo "$PROG: cannot checkout branch $br" >&2
      exit 1
    fi
  fi

  if ! as_root -u "$OWNER" git -C "$root" merge --ff-only "origin/$br"; then
    echo "$PROG: fast-forward failed — local $br and origin/$br have diverged" >&2
    echo "$PROG: inspect: git -C $root log --oneline --left-right HEAD...origin/$br" >&2
    echo "$PROG: no merge commit will be made. Fix on the git host, then retry." >&2
    exit 1
  fi

  if ! cmd_platform_upgrade --no-pull "$dest"; then
    echo "$PROG: promote git step succeeded; platform-upgrade failed" >&2
    echo "$PROG: $PROG last   and   $PROG site-restore if a product is broken" >&2
    exit 1
  fi

  echo "promote $name -> $to OK"
}
