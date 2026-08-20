#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
SOURCE=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Publishing must remain an explicit opt-in. Help is a no-tool, no-build path
# so this catches an accidental CLI inversion without compiling the engine.
./wasm/release.sh --help > "$TMP/release-help" 2>&1
grep -F -- '--publish' "$TMP/release-help" >/dev/null
if grep -F -- '--no-publish' "$TMP/release-help" >/dev/null; then
    echo "error: release help still advertises publishing by default" >&2
    exit 1
fi
if ./wasm/release.sh --no-publish > "$TMP/removed-option" 2>&1; then
    echo "error: removed --no-publish option was accepted" >&2
    exit 1
fi

RAW=$TMP/raw
GAMEDATA=$TMP/gamedata
SITE=$TMP/site
HEADER=$TMP/build.h
BASE_FILE=$TMP/crawl-base
mkdir -p "$RAW/prewarm" "$GAMEDATA"

# Data stamps must be portable across GNU/Linux and BSD/macOS, and must
# mirror `find -type f` by ignoring symlinks.
MTIME_TREE=$TMP/mtime-tree
mkdir -p "$MTIME_TREE/nested"
printf 'older\n' > "$MTIME_TREE/older"
printf 'newer\n' > "$MTIME_TREE/nested/newer"
printf 'newest but linked\n' > "$TMP/symlink-target"
node - "$MTIME_TREE/older" "$MTIME_TREE/nested/newer" "$TMP/symlink-target" <<'NODE'
const fs = require('node:fs')
const paths = process.argv.slice(2)
fs.utimesSync(paths[0], 1_700_000_100, 1_700_000_100)
fs.utimesSync(paths[1], 1_700_000_200, 1_700_000_200)
fs.utimesSync(paths[2], 1_700_000_300, 1_700_000_300)
NODE
ln -s "$TMP/symlink-target" "$MTIME_TREE/linked"
[ "$(node wasm/latest-mtime.mjs "$MTIME_TREE")" = 1700000200 ]

printf 'javascript glue\n' > "$RAW/crawl.js"
printf 'wasm bytes\n' > "$RAW/crawl.wasm"
printf 'data bytes\n' > "$RAW/crawl.data"
printf '{"stamp":"123"}\n' > "$RAW/prewarm/manifest.json"
printf 'prewarm bytes\n' > "$RAW/prewarm/prewarm.bin"
{
    printf '#define CRAWL_VERSION_SHORT "0.35-a0"\n'
    printf '#define CRAWL_VERSION_LONG "0.35-a0-848-gd8b905dbbe"\n'
} > "$HEADER"
printf 'd8b905dbbe11af1a27670d0a61a53a580348959f\n' > "$BASE_FILE"

GAMEDATA_FILES="enums.js feat.png tileinfo-feat.js floor.png tileinfo-floor.js gui.png tileinfo-gui.js icons.png tileinfo-icons.js main.png tileinfo-main.js player.png tileinfo-player.js wall.png tileinfo-wall.js tileinfo-dngn.js status-icon-sizes.js"
for file in $GAMEDATA_FILES; do
    printf 'fixture %s\n' "$file" > "$GAMEDATA/$file"
done

package() {
    POCKETZOT_RAW_DIST=$RAW \
    POCKETZOT_GAMEDATA_DIR=$GAMEDATA \
    POCKETZOT_BUILD_HEADER=$HEADER \
    POCKETZOT_CRAWL_BASE_FILE=$BASE_FILE \
    POCKETZOT_SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567 \
        ./wasm/package-site-assets.sh "$SITE"
}

package >/dev/null
BUILD=$(cat "$RAW/crawl.wasm" "$RAW/crawl.data" "$RAW/prewarm/prewarm.bin" | shasum -a 1 | cut -c1-12)

[ -f "$SITE/offline/crawl.js" ]
[ -f "$SITE/offline/crawl.wasm.gz" ]
[ -f "$SITE/offline/crawl.data.gz" ]
[ -f "$SITE/offline/prewarm/prewarm.bin.gz" ]
[ -f "$SITE/gamedata/local/manifest.json" ]
[ -f "$SITE/release.json" ]
gzip -dc "$SITE/offline/crawl.wasm.gz" | cmp -s - "$RAW/crawl.wasm"
gzip -dc "$SITE/offline/crawl.data.gz" | cmp -s - "$RAW/crawl.data"
gzip -dc "$SITE/offline/prewarm/prewarm.bin.gz" | cmp -s - "$RAW/prewarm/prewarm.bin"

node - "$SITE/release.json" "$SITE/gamedata/local/manifest.json" "$BUILD" <<'NODE'
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const [releasePath, gamedataPath, build] = process.argv.slice(2)
const release = JSON.parse(fs.readFileSync(releasePath, 'utf8'))
const gamedata = JSON.parse(fs.readFileSync(gamedataPath, 'utf8'))

if (release.schema !== 1 || release.build !== build) throw new Error('wrong release identity')
if (release.version !== '0.35-a0') throw new Error('wrong short version')
if (release.crawlVersion !== '0.35-a0-848-gd8b905dbbe') throw new Error('wrong long version')
if (release.crawlBase !== 'd8b905dbbe11af1a27670d0a61a53a580348959f') throw new Error('wrong Crawl base')
if (release.engineCommit !== '0123456789abcdef0123456789abcdef01234567') throw new Error('wrong commit')
if (!release.files.every(file => /^[0-9a-f]{64}$/.test(file.sha256) && file.bytes > 0)) {
  throw new Error('invalid file checksum entry')
}
for (const file of release.files) {
  const contents = fs.readFileSync(path.join(path.dirname(releasePath), file.path))
  const checksum = crypto.createHash('sha256').update(contents).digest('hex')
  if (contents.byteLength !== file.bytes || checksum !== file.sha256) {
    throw new Error(`bad manifest metadata for ${file.path}`)
  }
}
const paths = release.files.map(file => file.path)
if (paths.includes('release.json')) throw new Error('manifest hashes itself')
if (!paths.includes('offline/crawl.wasm.gz')) throw new Error('missing wasm entry')
if (!paths.includes('gamedata/local/status-icon-sizes.js')) throw new Error('missing gamedata entry')
if (gamedata.files.length !== 17) throw new Error('wrong gamedata file count')
if (gamedata.files.join('\n') !== [...gamedata.files].sort().join('\n')) {
  throw new Error('gamedata manifest is not sorted')
}
NODE

# Running twice over identical inputs must produce byte-identical files.
cp -R "$SITE" "$TMP/first-site"
package >/dev/null
diff -r "$TMP/first-site" "$SITE" >/dev/null

# Input validation happens before replacement, preserving a valid package.
BEFORE=$(sha256sum "$SITE/release.json")
rm "$RAW/prewarm/prewarm.bin"
if package >/dev/null 2>&1; then
    echo "error: packager accepted a missing prewarm blob" >&2
    exit 1
fi
[ "$BEFORE" = "$(sha256sum "$SITE/release.json")" ] || {
    echo "error: failed packaging replaced the previous site package" >&2
    exit 1
}

# The standalone manifest generator must reject links in release payloads.
rm "$SITE/release.json"
rm "$SITE/gamedata/local/manifest.json"
ln -s offline/crawl.js "$SITE/link"
if node wasm/create-release-manifest.mjs "$SITE" \
    0123456789abcdef0123456789abcdef01234567 \
    0.35-a0-848-gd8b905dbbe \
    d8b905dbbe11af1a27670d0a61a53a580348959f >/dev/null 2>&1; then
    echo "error: manifest generator accepted a symlink" >&2
    exit 1
fi

# Snapshot builds take their Crawl identity from the explicit override, not
# this repository's unrelated engine release tags.
CRAWL_VERSION_OVERRIDE=0.35-a0-848-gd8b905dbbe \
    perl util/gen_ver.pl "$TMP/override-build.h"
grep -F '#define CRAWL_VERSION_LONG "0.35-a0-848-gd8b905dbbe"' \
    "$TMP/override-build.h" >/dev/null

echo "release tooling fixtures passed"
