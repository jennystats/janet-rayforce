#!/bin/bash
# Install the pinned librayforce.so for the rayforce janet module
# (jennystats/rayforce.janet). Fetches the RayforceDB/rayforce tag
# tarball, verifies sha256, CROSS-CHECKS the four vendored headers
# (ops.h parquet.h heap.h rayforce.h - a drift is a hard failure
# BEFORE any compile: the binding would compile against one ABI while
# the pins document another), then builds the static
# archive with this binding's own CFLAGS (portable: no -march=native, no
# fast-math family - every precise-numeric claim in the contract is
# about THIS binary) and links the shared object from the release
# objects. Idempotent; re-run rebuilds. Deps: gcc + make + curl + tar
# (the engine itself is zero-dependency: libc, libm, pthreads).
#
# DEST may be overridden to install a second pin alongside the current
# one: DEST=$HOME/.local/lib/rayforce-v301 ./install-rayforce.sh
# The module resolves $RAYFORCE_LIB first, then ~/.local/lib/rayforce.
set -e
VERSION="3.0.1"
URL="https://api.github.com/repos/RayforceDB/rayforce/tarball/v${VERSION}"
TARBALL_SHA256="3a42998400ed4136558e65ec3386e26548994db76e0c3ed8f9b52f2c4487e335"
DEST="${DEST:-$HOME/.local/lib/rayforce}"

# Vendored-header pins (the ABI truth):
#   upstream path -> sha256
declare -A HEADER_SHA=(
  ["include/rayforce.h"]="c73c85c94f3dacdf9b437114f1794233823c50c0fb6d122cd925650e65bb5158"
  ["src/ops/ops.h"]="a82e47e96bdea0794fc0123d26a29e2bc0497e92d83716b3ac902a4b239d0bd8"
  ["src/io/parquet.h"]="0b34603ada9b8699226be029fc8ba7483be65293a908098b5937222d97acf290"
  ["src/mem/heap.h"]="34a9ce98abc5c37c111b70ed77d41a321bd9f7b93f8d92d8657e51a2e96b68ae"
)

# Release-object suffix. v2.11.5 emitted *.rel.o; v3.0.1 emits *.lib.o.
# The link step below globs this, so a stale value silently links an
# EMPTY shared object (exit 0, unusable .so) instead of failing.
REL_OBJ_SUFFIX="lib.o"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS/$ARCH" in
  Linux/x86_64) ;;
  Darwin/*)
    echo "error: macOS is compile-plausible but unverified (contract section 10); build route: xcode-select --install, then this script with the darwin link line adapted" >&2
    exit 1 ;;
  *)
    echo "error: unsupported platform $OS/$ARCH - Windows route: WSL2 (documented)" >&2
    exit 1 ;;
esac

command -v cc >/dev/null || { echo "error: no C compiler - Debian/Ubuntu: apt install build-essential; Fedora: dnf install gcc make" >&2; exit 1; }
command -v make >/dev/null || { echo "error: make not found - Debian/Ubuntu: apt install build-essential; Fedora: dnf install make" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching rayforce v$VERSION ..."
curl -fsSL -o "$TMP/rayforce.tar.gz" "$URL"
echo "$TARBALL_SHA256  $TMP/rayforce.tar.gz" | sha256sum -c -

SRC="$TMP/rayforce"
mkdir -p "$SRC"
tar xzf "$TMP/rayforce.tar.gz" -C "$SRC" --strip-components=1

# Vendored-header cross-check BEFORE building: the tarball's four headers
# must byte-match the pinned copies. Any diff is a hard failure
# with both hashes printed (compile-against-one-ABI hazard).
for f in include/rayforce.h src/ops/ops.h src/io/parquet.h src/mem/heap.h; do
  got="$(sha256sum "$SRC/$f" | awk '{print $1}')"
  want="${HEADER_SHA[$f]}"
  if [ "$got" != "$want" ]; then
    echo "error: vendored-header drift: $f" >&2
    echo "  tarball: $got" >&2
    echo "  pin   : $want" >&2
    echo "  (engine v$VERSION headers differ from the vendored-header pin - update the pins before building)" >&2
    exit 1
  fi
done
echo "vendored-header cross-check: 4/4 byte-identical to the pins"

JOBS="$(nproc 2>/dev/null || echo 4)"

# This binding's own build recipe: portable flags, no
# -march=native, no fast-math family, no unroll/align specials. Both
# variables MUST be make command-line arguments: the Makefile hard-
# assigns RELEASE_CFLAGS, so an exported env var is silently ignored
# (caught on the first installer run - the build log showed -O3
# -march=native -fassociative-math).
#
# The single deviation from the v2.11.5 recipe is the last variable:
# v3.0.1's new src/ops/colgather.c trips clang's -Werror=maybe-uninitialized
# on `off` in acc_put (set through acc_pool_put via ray_data(a->pool), which
# the analyzer cannot see through). gcc is clean; this box's cc is clang.
# It is scoped to THAT ONE OBJECT through the Makefile's existing
# FP_STRICT_<stem> per-file hook, and it changes diagnostics only - never
# emitted code, optimisation or FP results. Re-evaluate at every pin bump;
# remove when upstream fixes it or the analyzer catches up.
make -C "$SRC" lib -j"$JOBS" RAY_VERSION="$VERSION" \
  RELEASE_CFLAGS='-fPIC -Wall -Wextra -Werror -Wstrict-prototypes -Wno-unused-parameter -std=c17 -O2' \
  'FP_STRICT_src/ops/colgather:=-Wno-maybe-uninitialized'

# Link the shared object from the release objects. A glob that matches
# nothing must be a hard failure, not an empty archive: guard the count.
OBJS=("$SRC"/src/*/*."$REL_OBJ_SUFFIX")
if [ "${#OBJS[@]}" -eq 0 ] || [ ! -e "${OBJS[0]}" ]; then
  echo "error: no *.$REL_OBJ_SUFFIX release objects found after build" >&2
  echo "  (upstream changed the object suffix again - update REL_OBJ_SUFFIX)" >&2
  exit 1
fi

cc -shared -o "$TMP/librayforce.so" $(/usr/bin/find "$SRC/src" -name "*.$REL_OBJ_SUFFIX") \
  -lm -lpthread -Wl,--gc-sections

# A shared object with no ray_ symbols links successfully from an empty
# object set; assert the ABI surface is actually there.
if ! nm -D --defined-only "$TMP/librayforce.so" | awk '{print $3}' | /usr/bin/grep -qx 'ray_version_major'; then
  echo "error: linked librayforce.so exports no ray_ symbol - refusing to install" >&2
  exit 1
fi

mkdir -p "$DEST"
install -m 644 "$TMP/librayforce.so" "$DEST/librayforce.so"
echo "installed: $DEST/librayforce.so"
echo "usage    : (import jennystats/rayforce) - resolution: \$RAYFORCE_LIB, then ~/.local/lib/rayforce"
