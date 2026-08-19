#!/bin/sh
# Emit the complete corresponding source (GPLv2 §3) for a built engine
# release: the tracked tree at HEAD plus every initialized contrib
# submodule (git archive omits gitlinks), named by the same
# content-derived build id package-site-assets.sh stamps into version.json — so every
# deployed crawl.wasm maps to exactly one tarball.
#
# Run after a successful build (wasm/dist + build.h supply the id and
# version). Refuses a dirty tree: the tarball must match what was built.
#
#   ./wasm/make-source-tarball.sh [outdir]    # default outdir: wasm/dist
set -eu
cd "$(dirname "$0")/.."   # crawl-ref/source
SRC=$PWD
ROOT=$(cd ../.. && pwd)
OUT=${1:-$SRC/wasm/dist}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "error: the engine tree is dirty — commit or remove local files before packaging source" >&2
    exit 1
fi

# Same derivation as package-site-assets.sh (keep in sync): content hash of
# the three raw shipped artifacts, concatenated in this order.
for artifact in wasm/dist/crawl.wasm wasm/dist/crawl.data wasm/dist/prewarm/prewarm.bin build.h; do
    [ -s "$artifact" ] || { echo "error: required build output missing or empty: $artifact" >&2; exit 1; }
done
BUILD=$(cat wasm/dist/crawl.wasm wasm/dist/crawl.data wasm/dist/prewarm/prewarm.bin | shasum -a 1 | cut -c1-12)
VERSION=$(sed -n 's/#define CRAWL_VERSION_LONG "\([^"]*\)"/\1/p' build.h)
[ -n "$VERSION" ] || { echo "error: CRAWL_VERSION_LONG missing from build.h — build first" >&2; exit 1; }
case "$VERSION" in
    *[!A-Za-z0-9._+-]*) echo "error: build.h contains an unsafe Crawl version" >&2; exit 1 ;;
esac
NAME="pocketzot-engine-src-$VERSION-$BUILD"
CRAWL_BASE=$(sed -n '1p' wasm/crawl-base)
OUTPUT=$OUT/$NAME.tar.gz
OUTPUT_TMP=$OUT/.$NAME.tar.gz.tmp.$$

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"; rm -f "$OUTPUT_TMP"' EXIT HUP INT TERM
PKG="$STAGE/$NAME"
mkdir "$PKG"

git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$PKG"

# A history-free tree can't `git describe`, so gen_ver.pl needs the
# release_ver fallback (upstream stamps it into source packages the same
# way). Take the string from build.h so the tarball rebuilds with exactly
# the version the shipped artifacts report.
printf '%s\n' "$VERSION" > "$PKG/crawl-ref/source/util/release_ver"

# Include every pinned dependency. Some are only used by the native WEBTILES
# bootstrap that generates headers and tile atlases, while others are linked
# into wasm; all are part of the reproducible build environment.
SUBMODULES=$(git -C "$ROOT" config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')
[ -n "$SUBMODULES" ] || { echo "error: no dependency submodules found" >&2; exit 1; }
for p in $SUBMODULES; do
    expected=$(git -C "$ROOT" ls-tree HEAD -- "$p" | awk '{print $3}')
    actual=$(git -C "$ROOT/$p" rev-parse HEAD 2>/dev/null || true)
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || {
        echo "error: submodule $p is absent or not at its pinned commit" >&2
        exit 1
    }
    mkdir -p "$PKG/$p"
    git -C "$ROOT/$p" archive --format=tar HEAD | tar -xf - -C "$PKG/$p"
done

{
    echo "PocketZot engine — complete corresponding source"
    echo
    echo "game version:  $VERSION"
    echo "build id:      $BUILD  (matches version.json of the deployed artifacts)"
    echo "engine commit: $(git -C "$ROOT" rev-parse HEAD)"
    echo "upstream base: $CRAWL_BASE"
    echo
    echo "Build instructions: crawl-ref/source/wasm/README.md. Vendored pins:"
    for p in $SUBMODULES; do
        echo "  $(git -C "$ROOT/$p" rev-parse HEAD) $p"
    done
} > "$PKG/SOURCE.txt"

EPOCH=$(git -C "$ROOT" show -s --format=%ct HEAD)
TAR_FILE=$STAGE/$NAME.tar
tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner \
    -cf "$TAR_FILE" -C "$STAGE" "$NAME"
gzip -9n -c "$TAR_FILE" > "$OUTPUT_TMP"
mv "$OUTPUT_TMP" "$OUTPUT"
ls -lh "$OUTPUT" | awk '{print $9 " (" $5 ")"}'
