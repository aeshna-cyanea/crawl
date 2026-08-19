#!/bin/sh
# Emit the complete corresponding source (GPLv2 §3) for a built engine
# release: the tracked tree at HEAD plus every initialized contrib
# submodule (git archive omits gitlinks), named by the same
# content-derived build id install.sh stamps into version.json — so every
# deployed crawl.wasm maps to exactly one tarball.
#
# Run after a successful build (wasm/dist + build.h supply the id and
# version). Refuses a dirty tree: the tarball must match what was built.
#
#   ./wasm/make-source-tarball.sh [outdir]    # default outdir: wasm/dist
set -e
cd "$(dirname "$0")/.."   # crawl-ref/source
SRC=$PWD
ROOT=$(cd ../.. && pwd)
OUT=${1:-$SRC/wasm/dist}
OUT=$(cd "$OUT" && pwd)

if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "error: tracked files are modified — commit first, the tarball must match the built tree" >&2
    exit 1
fi

# Same derivation as install.sh (keep in sync): content hash of the shipped
# artifacts. shasum of empty input = da39a3ee… ⇒ nothing was built.
BUILD=$(cat wasm/dist/crawl.wasm wasm/dist/crawl.data wasm/dist/prewarm/prewarm.bin 2>/dev/null | shasum | cut -c1-12)
if [ "$BUILD" = "da39a3ee5e6b" ]; then
    echo "error: wasm/dist artifacts missing — build first (see wasm/README.md)" >&2
    exit 1
fi
VERSION=$(sed -n 's/#define CRAWL_VERSION_SHORT "\(.*\)"/\1/p' build.h 2>/dev/null | tr -cd 'A-Za-z0-9._+-')
NAME="pocketzot-engine-src-${VERSION:+$VERSION-}$BUILD"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$NAME"
mkdir "$PKG"

git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$PKG"

# A history-free tree can't `git describe`, so gen_ver.pl needs the
# release_ver fallback (upstream stamps it into source packages the same
# way). Take the string from build.h so the tarball rebuilds with exactly
# the version the shipped artifacts report.
VER_LONG=$(sed -n 's/#define CRAWL_VERSION_LONG "\(.*\)"/\1/p' build.h)
if [ -z "$VER_LONG" ]; then
    echo "error: CRAWL_VERSION_LONG missing from build.h — build first" >&2
    exit 1
fi
printf '%s\n' "$VER_LONG" > "$PKG/crawl-ref/source/util/release_ver"

# Vendored deps the WEBTILES/wasm build actually uses — everything else
# (the sdl2 family, freetype, pcre, luajit, fonts) serves crawl's local
# tiles build only and is omitted. The guard below cross-checks this list
# against the libs the native build really produced, so a future upstream
# dependency change fails the run instead of silently shipping short.
SUBMODULES="lua libpng sqlite zlib"
for lib in contrib/install/*/lib/*.a; do
    [ -e "$lib" ] || { echo "error: contrib/install libs missing — run the native build first" >&2; exit 1; }
    case $(basename "$lib") in
        liblua*)     need=lua ;;
        libpng*)     need=libpng ;;
        libsqlite3*) need=sqlite ;;
        libz*)       need=zlib ;;
        *)           need="UNKNOWN($(basename "$lib"))" ;;
    esac
    case " $SUBMODULES " in
        *" $need "*) ;;
        *) echo "error: native build used $lib but its submodule '$need' is not in SUBMODULES — update the list" >&2
           exit 1 ;;
    esac
done
for m in $SUBMODULES; do
    p="crawl-ref/source/contrib/$m"
    mkdir -p "$PKG/$p"
    git -C "$ROOT/$p" archive --format=tar HEAD | tar -xf - -C "$PKG/$p"
done

{
    echo "PocketZot engine — complete corresponding source"
    echo
    echo "game version:  ${VERSION:-unknown}"
    echo "build id:      $BUILD  (matches version.json of the deployed artifacts)"
    echo "engine commit: $(git -C "$ROOT" rev-parse HEAD)"
    echo
    echo "Build instructions: crawl-ref/source/wasm/README.md. The wasm link takes zlib"
    echo "and sqlite from Emscripten ports; the vendored submodules below are"
    echo "the ones the build uses — upstream's remaining submodules (sdl2"
    echo "family, freetype, pcre, luajit, fonts) serve crawl's local tiles"
    echo "build only and are omitted. Vendored pins:"
    for m in $SUBMODULES; do
        p="crawl-ref/source/contrib/$m"
        echo "  $(git -C "$ROOT/$p" rev-parse HEAD) $p"
    done
} > "$PKG/SOURCE.txt"

tar -czf "$OUT/$NAME.tar.gz" -C "$STAGE" "$NAME"
ls -lh "$OUT/$NAME.tar.gz" | awk '{print $9 " (" $5 ")"}'
