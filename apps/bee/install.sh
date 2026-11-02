#!/bin/sh
# modules/50-bee.sh — Bee from landNull/bee, not Composer
# Contract: /usr/local/bin/bee -> /usr/local/src/bee/bee.php
# Upstream 1.x-1.x ships bee.php (no file named "bee").

echo "STEP 50: Bee CLI"

bee_src() {
  if [ -f "$BEE_DST/bee.php" ]; then
    echo "$BEE_DST/bee.php"
  elif [ -f "$BEE_DST/bee" ]; then
    echo "$BEE_DST/bee"
  else
    echo ""
  fi
}

if [ "$DRYRUN" -eq 1 ]; then
  echo "+ git clone --depth 1 --branch 1.x-1.x $BEE_SRC $BEE_DST"
  echo "+ ln -sfn $BEE_DST/bee.php $BEE_BIN"
elif [ -d "$BEE_DST/.git" ]; then
  echo "bee refresh $BEE_DST from $BEE_SRC"
  run_root git -C "$BEE_DST" remote set-url origin "$BEE_SRC" || true
  run_root git -C "$BEE_DST" fetch --depth 1 origin 1.x-1.x || true
  run_root git -C "$BEE_DST" checkout -B 1.x-1.x origin/1.x-1.x || true
  src=$(bee_src)
  [ -n "$src" ] && run_root ln -sfn "$src" "$BEE_BIN"
  echo "bee updated: $BEE_BIN -> $src"
elif have bee && [ -x "$(command -v bee)" ]; then
  echo "bee ok: $(command -v bee) (not our checkout — leave it)"
else
  run_root mkdir -p /usr/local/src
  if [ ! -d "$BEE_DST/.git" ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      run_root gh repo clone landNull/bee "$BEE_DST" -- --depth 1 --branch 1.x-1.x
    else
      run_root git clone --depth 1 --branch 1.x-1.x "$BEE_SRC" "$BEE_DST"
    fi
  fi
  src=$(bee_src)
  if [ -n "$src" ]; then
    run_root chmod 0755 "$src"
    run_root ln -sfn "$src" "$BEE_BIN"
    echo "bee installed: $BEE_BIN -> $src"
  else
    echo "$PROG: cloned Bee but neither bee.php nor bee in $BEE_DST" >&2
    return 1
  fi
fi
