#!/bin/bash
# Install the pinned librayforce.so for the rayforce janet module
# (jennystats/rayforce.janet). Fetches the RayforceDB/rayforce tag
# tarball, verifies sha256, stages the installed headers with the
# engine's own `make install-headers` target (upstream #849/#1055) and
# CROSS-CHECKS the staged tree against the pins (7/7 byte-identical; a
# drift is a hard failure BEFORE any compile), proves a C client
# compiles against the staged layout, then builds the static archive
# with this binding's own CFLAGS (portable: no -march=native, no
# fast-math family - every precise-numeric claim in the contract is
# about THIS binary) and links the shared object from the release
# objects. Idempotent; re-run rebuilds. Deps: gcc + make + curl + tar
# (the engine itself is zero-dependency: libc, libm, pthreads).
#
# DEST may be overridden to install a second pin alongside the current
# one: DEST=$HOME/.local/lib/rayforce-v302 ./install-rayforce.sh
# The module resolves $RAYFORCE_LIB first, then ~/.local/lib/rayforce.
# HEADER_DEST (default ~/.local/include) takes the staged headers in the
# upstream layout: rayforce.h at the root plus the rayforce/ tree, ready
# for -I$HEADER_DEST -I$HEADER_DEST/rayforce/src.
set -e
VERSION="3.0.2"
URL="https://api.github.com/repos/RayforceDB/rayforce/tarball/v${VERSION}"
TARBALL_SHA256="c769cbb3d884e40c35222a4a6599f23bf253fd065370ac24069de5fbf305c161"
DEST="${DEST:-$HOME/.local/lib/rayforce}"
HEADER_DEST="${HEADER_DEST:-$HOME/.local/include}"

# Installed-header pins (the ABI truth) - paths are the `make
# install-headers` layout under the stage root, which is what a C client
# compiles against:
#   staged path -> sha256
declare -A HEADER_SHA=(
  ["rayforce.h"]="7ff204a132dfe4f9a864c3364c862d14f023590f5e2ceee9bceb8662385637d7"
  ["rayforce/include/rayforce/rayforce.h"]="7ff204a132dfe4f9a864c3364c862d14f023590f5e2ceee9bceb8662385637d7"
  ["rayforce/src/ops/ops.h"]="a82e47e96bdea0794fc0123d26a29e2bc0497e92d83716b3ac902a4b239d0bd8"
  ["rayforce/src/io/parquet.h"]="0b34603ada9b8699226be029fc8ba7483be65293a908098b5937222d97acf290"
  ["rayforce/src/mem/heap.h"]="12ad34dbeab45aa61226207491cc21c92f8e999638c2ae972941eeffe25232c5"
  ["rayforce/src/store/hnsw.h"]="18a631c80efa0a841cbd2fbe091727379ec306340f213e3708ccefd8651768c7"
  ["rayforce/src/core/platform.h"]="f18d8913eb262a186546e2ee890e3c3504b07979eaed34c1ce699ea385507790"
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

# Stage the headers a C client needs (upstream #849/#1055). Staged into
# TMP first, so the pins are checked before anything is installed. The
# staged set is the public header plus the internals a binding includes
# directly and the two those reach through their quoted includes.
HEADERS="$TMP/install/include"
make -C "$SRC" install-headers INSTALL_INCLUDE="$HEADERS" RAY_VERSION="$VERSION" >/dev/null

# Installed-header cross-check BEFORE building: the staged tree must
# byte-match the pins. Any diff is a hard failure with both hashes
# printed (compile-against-one-ABI hazard).
for f in rayforce.h rayforce/include/rayforce/rayforce.h \
         rayforce/src/ops/ops.h rayforce/src/io/parquet.h \
         rayforce/src/mem/heap.h rayforce/src/store/hnsw.h \
         rayforce/src/core/platform.h; do
  got="$(sha256sum "$HEADERS/$f" | cut -d' ' -f1)"
  want="${HEADER_SHA[$f]}"
  if [ "$got" != "$want" ]; then
    echo "error: installed-header drift: $f" >&2
    echo "  staged: $got" >&2
    echo "  pin   : $want" >&2
    echo "  (engine v$VERSION headers differ from the installed-header pin - update the pins before building)" >&2
    exit 1
  fi
done
echo "installed-header cross-check: 7/7 byte-identical to the pins"

# Prove the staged layout resolves for a C client: both include roots,
# every header the staging set carries. Compile-only; the linked ABI
# surface is asserted by the nm check after the link.
cat > "$TMP/probe.c" <<'PROBE'
#include <rayforce.h>
#include "ops/ops.h"
#include "io/parquet.h"
#include "mem/heap.h"
#include "store/hnsw.h"
#include "core/platform.h"
int rayforce_installed_headers_probe(void) { return 0; }
PROBE
cc -O2 -I"$HEADERS" -I"$HEADERS/rayforce/src" -c -o "$TMP/probe.o" "$TMP/probe.c"
echo "installed-header probe: C client compiles against the staged layout"

JOBS="$(nproc 2>/dev/null || echo 4)"

# This binding's own build recipe: portable flags, no
# -march=native, no fast-math family, no unroll/align specials. Both
# variables MUST be make command-line arguments: the Makefile hard-
# assigns RELEASE_CFLAGS, so an exported env var is silently ignored
# (caught on the first installer run - the build log showed -O3
# -march=native -fassociative-math).
#
# The single deviation from the upstream recipe is the last variable:
# src/ops/colgather.c (new in v3.0.1) trips -Werror=maybe-uninitialized
# on `off` in acc_put (set through acc_pool_put via ray_data(a->pool),
# which the analyzer cannot see through). Re-verified on v3.0.2: the
# warning still fires, now under BOTH clang and gcc 14.2 (probed
# 2026-11-07: `cc -c -Wall -Wextra -Werror ... colgather.c` fails on
# both; adding -Wno-maybe-uninitialized is clean on both). It is scoped
# to THAT ONE OBJECT through the Makefile's existing FP_STRICT_<stem>
# per-file hook, and it changes diagnostics only - never emitted code,
# optimisation or FP results. Re-evaluate at every pin bump; remove when
# upstream fixes it or the analyzer catches up.
# src/ops/agg_engine.c joins the list 2026-11-09: 'cur[0]' may be used
# uninitialized at line 8712 (agg_run_collect_fn) - clean on the local
# gcc 14.2, fatal on the GitLab runner's gcc (janet-query gate:jpm,
# pipeline 3043782823, twice; same class, same per-file scoping).
# CC is forced to the system compiler (cc): the upstream Makefile defaults
# to clang, which a plain build-essential CI image does not carry - gcc
# is the documented dependency (and the suppression above is needed there
# too on 3.0.2).
make -C "$SRC" lib -j"$JOBS" CC=cc RAY_VERSION="$VERSION" \
  RELEASE_CFLAGS='-fPIC -Wall -Wextra -Werror -Wstrict-prototypes -Wno-unused-parameter -std=c17 -O2' \
  'FP_STRICT_src/ops/colgather:=-Wno-maybe-uninitialized' \
  'FP_STRICT_src/ops/agg_engine:=-Wno-maybe-uninitialized'

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

# Install the staged headers beside the shared object's prefix. Only the
# rayforce paths are replaced; anything else under HEADER_DEST (janet.h)
# is left alone.
mkdir -p "$HEADER_DEST"
rm -rf "$HEADER_DEST/rayforce" "$HEADER_DEST/rayforce.h"
cp -R "$HEADERS/." "$HEADER_DEST/"
echo "headers  : $HEADER_DEST/rayforce.h and $HEADER_DEST/rayforce/"
echo "usage    : (import jennystats/rayforce) - resolution: \$RAYFORCE_LIB, then ~/.local/lib/rayforce"
echo "c client : cc -I$HEADER_DEST -I$HEADER_DEST/rayforce/src ..."
