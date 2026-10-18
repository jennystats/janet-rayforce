#!/bin/bash
# Install the pinned librayforce.so for the rayforce janet module
# (modules/jennystats/rayforce.janet). Fetches the RayforceDB/rayforce v2.11.5
# tag tarball, verifies sha256, CROSS-CHECKS the four vendored headers
# (ops.h parquet.h heap.h rayforce.h - a drift is a hard failure
# BEFORE any compile: the binding would compile against one ABI while
# the pins document another), then builds the static
# archive with this binding's own CFLAGS (portable: no -march=native, no
# fast-math family - every precise-numeric claim in the contract is
# about THIS binary) and links the shared object from the release
# objects. Idempotent; re-run rebuilds. Deps: gcc + make + curl + tar
# (the engine itself is zero-dependency: libc, libm, pthreads).
set -e
VERSION="2.11.5"
URL="https://api.github.com/repos/RayforceDB/rayforce/tarball/v${VERSION}"
TARBALL_SHA256="fec660bb01cfd53cbc816da82e89c61c7fc803ce4c56f64fb3ee83cc04079406"
DEST="$HOME/.local/lib/rayforce"

# Vendored-header pins (the ABI truth):
#   upstream path -> sha256
declare -A HEADER_SHA=(
  ["include/rayforce.h"]="27ca40288575aad8869b2503327241bdf1e8457565d5ec2c4c07da8d24107949"
  ["src/ops/ops.h"]="9c278449665d7c41b486bd728957fa29f91d6c0f2c03f91ed677a30c0ef39c8c"
  ["src/io/parquet.h"]="0b34603ada9b8699226be029fc8ba7483be65293a908098b5937222d97acf290"
  ["src/mem/heap.h"]="cc2c955e5423dec8ba1b12bd43722e0997192a9e44007df5cd262af37846d1a5"
)

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
make -C "$SRC" lib -j"$JOBS" RAY_VERSION="$VERSION" \
  RELEASE_CFLAGS='-fPIC -Wall -Wextra -Werror -Wstrict-prototypes -Wno-unused-parameter -std=c17 -O2'

cc -shared -o "$TMP/librayforce.so" $(/usr/bin/find "$SRC/src" -name '*.rel.o') \
  -lm -lpthread -Wl,--gc-sections

mkdir -p "$DEST"
install -m 644 "$TMP/librayforce.so" "$DEST/librayforce.so"
echo "installed: $DEST/librayforce.so"
echo "usage    : (import jennystats/rayforce) - resolution: \$RAYFORCE_LIB, then the path above"
