#!/bin/sh
# Installs the WASM engine artifacts into a PocketZot checkout (deploy-time
# content; both target dirs are gitignored there). Usage:
#   wasm/install.sh [path-to-pocketzot]   (default: ../../../pocketzot)
set -e
cd "$(dirname "$0")/.."
TARGET="${1:-../../../pocketzot}"
[ -d "$TARGET/public" ] || { echo "no public/ under $TARGET"; exit 1; }

OFF="$TARGET/public/offline"
mkdir -p "$OFF" "$TARGET/public/gamedata/local"

# The big artifacts ship gzipped (-9: crawl.wasm 23 MB -> ~7, crawl.data
# 11.6 -> ~4, prewarm.bin 11.3 -> ~4). The client worker gunzips via
# DecompressionStream, detecting gzip by magic bytes — so a plain-file
# fallback keeps working and a CDN that transparently decompresses does no
# harm. Remove any uncompressed copies from earlier installs so deploys
# don't ship both.
cp wasm/dist/crawl.js "$OFF/"
gzip -9c wasm/dist/crawl.wasm > "$OFF/crawl.wasm.gz"
gzip -9c wasm/dist/crawl.data > "$OFF/crawl.data.gz"
rm -f "$OFF/crawl.wasm" "$OFF/crawl.data"

# Pre-baked first-boot caches (wasm/bake-caches.mjs); optional but expected —
# without them every fresh device pays the in-engine cache build once.
rm -rf "$OFF/prewarm"
if [ -d wasm/dist/prewarm ]; then
    mkdir -p "$OFF/prewarm"
    cp wasm/dist/prewarm/manifest.json "$OFF/prewarm/"
    gzip -9c wasm/dist/prewarm/prewarm.bin > "$OFF/prewarm/prewarm.bin.gz"
else
    echo "warning: wasm/dist/prewarm missing — run: node wasm/bake-caches.mjs"
fi

# Build id for the client's artifact cache (engine.worker.ts keys its Cache
# API storage on this and refetches when it changes). Content-derived so a
# rebuild that changes nothing keeps caches warm. `version` is the game
# version the pack was built from (the git tag: "0.34.1" stable, "0.35-a0"
# trunk) — the client's readiness UI names the pack with it; display-only,
# omitted if build.h is missing.
BUILD=$(cat wasm/dist/crawl.wasm wasm/dist/crawl.data wasm/dist/prewarm/prewarm.bin 2>/dev/null | shasum | cut -c1-12)
# tr guard: the value is spliced into JSON unescaped, so strip anything
# outside the characters real tags use (a stray quote would make the client
# misread the whole deploy as unreachable).
VERSION=$(sed -n 's/#define CRAWL_VERSION_SHORT "\(.*\)"/\1/p' build.h 2>/dev/null | tr -cd 'A-Za-z0-9._+-')
if [ -n "$VERSION" ]; then
    printf '{"build":"%s","version":"%s"}\n' "$BUILD" "$VERSION" > "$OFF/version.json"
else
    echo "warning: build.h missing — version.json ships without a game version"
    printf '{"build":"%s"}\n' "$BUILD" > "$OFF/version.json"
fi

# The engine's own enums.js: flag decoding for the bundled version, served
# same-origin at /gamedata/local/ (see PocketZot's LocalConnection.httpBase).
cp webserver/game_data/static/enums.js "$TARGET/public/gamedata/local/"
# Tile atlases + tileinfo modules for offline tiles mode — the same files a
# live server serves, refreshed by the native build. The client's TileLoader
# resolves version 'local' to /gamedata/local/<name>.png + tileinfo-<name>.js
# (tileinfo-dngn.js is the meta-module dispatching to floor/wall/feat).
for tex in feat floor gui icons main player wall; do
    cp "webserver/game_data/static/$tex.png" \
       "webserver/game_data/static/tileinfo-$tex.js" \
       "$TARGET/public/gamedata/local/"
done
cp webserver/game_data/static/tileinfo-dngn.js "$TARGET/public/gamedata/local/"
# Generated per-icon width table (status_icon_size) — the client's primary
# source for status-icon fan-out widths (icon-sizes.ts getStatusIconSizer);
# without it offline games warn and fall back to the bundled 0.34 table.
cp webserver/game_data/static/status-icon-sizes.js "$TARGET/public/gamedata/local/"

# Manifest of the gamedata set, for the client's explicit offline download
# (artifact-store.ts downloadOfflineData): the atlas set can change across
# engine versions, so the client must not hardcode it. Derived from what was
# actually installed rather than the loop above, so the two can't drift.
(cd "$TARGET/public/gamedata/local" && ls *.png *.js | LC_ALL=C sort | \
    awk 'BEGIN{printf "{\"files\":["} NR>1{printf ","} {printf "\"%s\"", $0} END{printf "]}\n"}' \
    > manifest.json)
echo "installed (build $BUILD):"
ls -la "$OFF/" | tail -n +2
