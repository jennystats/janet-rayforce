#!/bin/sh
# run_tests.sh - janet-rayforce smoke suite. SKIP semantics: absent libs
# skip, present-but-broken is a FAIL, never a skip.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "$JANET_PATH" ] || export JANET_PATH="$HOME/.local/lib/janet"
export JANET_PATH="$DIR:$JANET_PATH"

has_rayforce() { { [ -n "$RAYFORCE_LIB" ] || [ -f "$HOME/.local/lib/rayforce/librayforce.so" ]; } && { [ -n "$JANET_NUM_LIB" ] || [ -f "$HOME/.local/lib/janet-num/libjn.so" ]; }; }

fail=0
if has_rayforce; then
  if janet "$DIR/test/smoke-rayforce.janet" > /dev/null 2>&1; then
    echo "PASS smoke-rayforce.janet"
  else
    echo "FAIL smoke-rayforce.janet"
    janet "$DIR/test/smoke-rayforce.janet"
    fail=1
  fi
else
  echo "SKIP smoke-rayforce.janet (no librayforce or libjn - run libs/install-rayforce.sh and libs from janet-num)"
fi

if [ "$fail" -eq 0 ]; then echo "RESULT: pass"; else echo "RESULT: fail"; exit 1; fi
