#!/bin/sh
# Assemble the complete static site payload under wasm/dist/site. This script
# deliberately knows nothing about the PocketZot client checkout: consumers
# copy or extract its offline/ and gamedata/ directories during deployment.
set -eu

cd "$(dirname "$0")/.."
SOURCE=$PWD
RAW_DIST=${POCKETZOT_RAW_DIST:-$SOURCE/wasm/dist}
GAMEDATA=${POCKETZOT_GAMEDATA_DIR:-$SOURCE/webserver/game_data/static}
BUILD_HEADER=${POCKETZOT_BUILD_HEADER:-$SOURCE/build.h}
CRAWL_BASE_FILE=${POCKETZOT_CRAWL_BASE_FILE:-$SOURCE/wasm/crawl-base}
SITE_ARG=${1:-${POCKETZOT_SITE_OUT:-$RAW_DIST/site}}

fail() {
    echo "error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

need_file() {
    [ -f "$1" ] && [ -s "$1" ] || fail "required build output missing or empty: $1"
}

for command in basename cat cp cut dirname gzip git mkdir mktemp mv node rm sed shasum; do
    need_command "$command"
done

[ -d "$RAW_DIST" ] || fail "raw wasm output directory not found: $RAW_DIST"
[ -d "$GAMEDATA" ] || fail "gamedata directory not found: $GAMEDATA"
RAW_DIST=$(cd "$RAW_DIST" && pwd -P)
GAMEDATA=$(cd "$GAMEDATA" && pwd -P)

need_file "$RAW_DIST/crawl.js"
need_file "$RAW_DIST/crawl.wasm"
need_file "$RAW_DIST/crawl.data"
need_file "$RAW_DIST/prewarm/manifest.json"
need_file "$RAW_DIST/prewarm/prewarm.bin"
need_file "$BUILD_HEADER"
need_file "$CRAWL_BASE_FILE"

GAMEDATA_FILES="enums.js feat.png tileinfo-feat.js floor.png tileinfo-floor.js gui.png tileinfo-gui.js icons.png tileinfo-icons.js main.png tileinfo-main.js player.png tileinfo-player.js wall.png tileinfo-wall.js tileinfo-dngn.js status-icon-sizes.js"
for file in $GAMEDATA_FILES; do
    need_file "$GAMEDATA/$file"
done

VERSION=$(sed -n 's/#define CRAWL_VERSION_SHORT "\([^"]*\)"/\1/p' "$BUILD_HEADER")
CRAWL_VERSION=$(sed -n 's/#define CRAWL_VERSION_LONG "\([^"]*\)"/\1/p' "$BUILD_HEADER")
CRAWL_BASE=$(sed -n '1p' "$CRAWL_BASE_FILE")
[ -n "$VERSION" ] || fail "CRAWL_VERSION_SHORT missing from $BUILD_HEADER"
[ -n "$CRAWL_VERSION" ] || fail "CRAWL_VERSION_LONG missing from $BUILD_HEADER"
case "$VERSION$CRAWL_VERSION" in
    *[!A-Za-z0-9._+-]*) fail "build header contains an unsafe version string" ;;
esac
case "$CRAWL_BASE" in
    *[!0-9A-Fa-f]*|'') fail "invalid Crawl base commit in $CRAWL_BASE_FILE" ;;
esac
BASE_LENGTH=${#CRAWL_BASE}
[ "$BASE_LENGTH" -eq 40 ] || [ "$BASE_LENGTH" -eq 64 ] || fail "invalid Crawl base commit in $CRAWL_BASE_FILE"

if [ -n "${POCKETZOT_SOURCE_COMMIT:-}" ]; then
    SOURCE_COMMIT=$POCKETZOT_SOURCE_COMMIT
else
    SOURCE_COMMIT=$(git -C "$SOURCE/../.." rev-parse HEAD) || fail "cannot determine engine commit"
fi
case "$SOURCE_COMMIT" in
    *[!0-9A-Fa-f]*|'') fail "invalid engine commit: $SOURCE_COMMIT" ;;
esac
COMMIT_LENGTH=${#SOURCE_COMMIT}
[ "$COMMIT_LENGTH" -eq 40 ] || [ "$COMMIT_LENGTH" -eq 64 ] || fail "invalid engine commit: $SOURCE_COMMIT"

# Preserve the client cache key used by existing releases: SHA-1 of the raw
# wasm, data package, and prewarm blob concatenated in that order.
BUILD=$(cat "$RAW_DIST/crawl.wasm" "$RAW_DIST/crawl.data" "$RAW_DIST/prewarm/prewarm.bin" | shasum -a 1 | cut -c1-12)
case "$BUILD" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "could not derive a valid build id" ;;
esac

SITE_PARENT=$(dirname "$SITE_ARG")
SITE_NAME=$(basename "$SITE_ARG")
[ "$SITE_NAME" != . ] && [ "$SITE_NAME" != .. ] && [ -n "$SITE_NAME" ] || fail "unsafe site output: $SITE_ARG"
mkdir -p "$SITE_PARENT"
SITE_PARENT=$(cd "$SITE_PARENT" && pwd -P)
SITE=$SITE_PARENT/$SITE_NAME
[ "$SITE" != / ] && [ "$SITE" != "$SOURCE" ] && [ "$SITE" != "$RAW_DIST" ] || fail "unsafe site output: $SITE"

STAGE=$(mktemp -d "$SITE_PARENT/.pocketzot-site.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/offline/prewarm" "$STAGE/gamedata/local"

cp "$RAW_DIST/crawl.js" "$STAGE/offline/crawl.js"
gzip -9n -c "$RAW_DIST/crawl.wasm" > "$STAGE/offline/crawl.wasm.gz"
gzip -9n -c "$RAW_DIST/crawl.data" > "$STAGE/offline/crawl.data.gz"
cp "$RAW_DIST/prewarm/manifest.json" "$STAGE/offline/prewarm/manifest.json"
gzip -9n -c "$RAW_DIST/prewarm/prewarm.bin" > "$STAGE/offline/prewarm/prewarm.bin.gz"
printf '{"build":"%s","version":"%s"}\n' "$BUILD" "$VERSION" > "$STAGE/offline/version.json"

for file in $GAMEDATA_FILES; do
    cp "$GAMEDATA/$file" "$STAGE/gamedata/local/$file"
done

node "$SOURCE/wasm/create-release-manifest.mjs" \
    "$STAGE" "$SOURCE_COMMIT" "$CRAWL_VERSION" "$CRAWL_BASE"

# The complete package is ready before the previous generated package is
# touched. A failure above therefore leaves a known-good package in place.
rm -rf "$SITE"
mv "$STAGE" "$SITE"
trap - EXIT HUP INT TERM

echo "packaged PocketZot site assets:"
echo "  build:   $BUILD"
echo "  Crawl:   $CRAWL_VERSION"
echo "  base:    $CRAWL_BASE"
echo "  output:  $SITE"
