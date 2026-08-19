#!/bin/sh
# Build the offline engine locally, package the static site payload and its
# complete source, then publish both as an atomic (draft-first) GitHub Release.
set -eu

cd "$(dirname "$0")/.."
SOURCE=$PWD
ROOT=$(cd ../.. && pwd)
PUBLISH=1
JOBS=${JOBS:-}

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: ./wasm/release.sh [--no-publish] [--jobs N]

  --no-publish  perform the full clean build and create release files locally
  --jobs N      parallel compiler jobs (default: nproc/getconf result)
EOF
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-publish) PUBLISH=0 ;;
        --jobs)
            [ "$#" -ge 2 ] || usage
            JOBS=$2
            shift
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
    shift
done

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

for command in git make node python3 tar gzip shasum sha256sum grep sed awk; do
    need_command "$command"
done
need_command emcc
need_command em++
[ "$PUBLISH" -eq 0 ] || need_command gh

python3 -c 'import yaml' >/dev/null 2>&1 || fail "PyYAML is required by Crawl's native build"
tar --help 2>/dev/null | grep -q -- '--sort' || fail "GNU tar is required for reproducible release archives"

if [ -z "$JOBS" ]; then
    if command -v nproc >/dev/null 2>&1; then
        JOBS=$(nproc)
    else
        JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    fi
fi
case "$JOBS" in
    ''|*[!0-9]*) fail "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -gt 0 ] || fail "--jobs must be a positive integer"

CRAWL_VERSION=$(sed -n '1p' wasm/crawl-version)
CRAWL_BASE=$(sed -n '1p' wasm/crawl-base)
case "$CRAWL_VERSION" in
    *[!A-Za-z0-9._+-]*|'') fail "wasm/crawl-version contains an invalid version" ;;
esac
printf '%s\n' "$CRAWL_VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z]+[0-9]+)?(-[0-9]+-g[0-9A-Fa-f]+)?$' \
    || fail "wasm/crawl-version is not a complete Crawl git-describe version"
case "$CRAWL_BASE" in
    *[!0-9A-Fa-f]*|'') fail "wasm/crawl-base contains an invalid commit" ;;
esac
BASE_LENGTH=${#CRAWL_BASE}
[ "$BASE_LENGTH" -eq 40 ] || [ "$BASE_LENGTH" -eq 64 ] \
    || fail "wasm/crawl-base contains an invalid commit"
export CRAWL_VERSION_OVERRIDE=$CRAWL_VERSION

[ -z "$(git -C "$ROOT" status --porcelain)" ] \
    || fail "engine checkout is dirty; commit or remove local files before building a release"
SUBMODULE_STATUS=$(git -C "$ROOT" submodule status --recursive)
if printf '%s\n' "$SUBMODULE_STATUS" | grep -Eq '^[-+U]'; then
    fail "one or more dependency submodules are absent or not at their pinned commits"
fi

HEAD=$(git -C "$ROOT" rev-parse HEAD)
if git -C "$ROOT" cat-file -e "$CRAWL_BASE^{commit}" 2>/dev/null; then
    git -C "$ROOT" merge-base --is-ancestor "$CRAWL_BASE" "$HEAD" \
        || fail "wasm/crawl-base is not an ancestor of the engine commit"
fi
REPOSITORY=
if [ "$PUBLISH" -eq 1 ]; then
    BRANCH=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ "$BRANCH" = main ] || fail "publishing requires the engine main branch (current: ${BRANCH:-detached HEAD})"

    ORIGIN_URL=$(git -C "$ROOT" remote get-url --push origin)
    case "$ORIGIN_URL" in
        https://github.com/*) REPOSITORY=${ORIGIN_URL#https://github.com/} ;;
        git@github.com:*) REPOSITORY=${ORIGIN_URL#git@github.com:} ;;
        ssh://git@github.com/*) REPOSITORY=${ORIGIN_URL#ssh://git@github.com/} ;;
        *) fail "origin must be a GitHub repository, got: $ORIGIN_URL" ;;
    esac
    REPOSITORY=${REPOSITORY%.git}
    case "$REPOSITORY" in
        */*) ;;
        *) fail "could not derive owner/repository from origin: $ORIGIN_URL" ;;
    esac
    OWNER=${REPOSITORY%%/*}
    REPO_NAME=${REPOSITORY#*/}
    [ -n "$OWNER" ] && [ -n "$REPO_NAME" ] \
        || fail "could not derive owner/repository from origin: $ORIGIN_URL"
    case "$OWNER/$REPO_NAME" in
        */*/*) fail "could not derive owner/repository from origin: $ORIGIN_URL" ;;
    esac
    LOWER_REPOSITORY=$(printf '%s' "$REPOSITORY" | tr '[:upper:]' '[:lower:]')
    case "$LOWER_REPOSITORY" in
        crawl/crawl|pocketzot/pocketzot-engine)
            fail "refusing to publish releases to upstream repository $REPOSITORY"
            ;;
    esac

    gh auth status --hostname github.com >/dev/null
    echo "Checking that $HEAD is pushed to $REPOSITORY main..."
    git -C "$ROOT" fetch --quiet --depth=1 --no-tags origin main
    ORIGIN_HEAD=$(git -C "$ROOT" rev-parse refs/remotes/origin/main)
    [ "$HEAD" = "$ORIGIN_HEAD" ] || fail "HEAD is not exactly origin/main; push the committed build inputs first"
fi

echo "Building PocketZot engine $CRAWL_VERSION with $JOBS jobs..."
make WEBTILES=y clean
make -f wasm/Makefile.emscripten clean
make -j"$JOBS" WEBTILES=y
./wasm/gen-objects.sh
make -f wasm/Makefile.emscripten -j"$JOBS"
node wasm/bake-caches.mjs
./wasm/package-site-assets.sh

SITE=$SOURCE/wasm/dist/site
BUILD=$(sed -n 's/.*"build":"\([0-9a-f]*\)".*/\1/p' "$SITE/offline/version.json")
case "$BUILD" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "packager produced an invalid build id" ;;
esac
PACKAGED_CRAWL_VERSION=$(node -e \
    'const fs=require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).crawlVersion)' \
    "$SITE/release.json")
[ "$PACKAGED_CRAWL_VERSION" = "$CRAWL_VERSION" ] \
    || fail "packaged Crawl version does not match wasm/crawl-version"
PACKAGED_CRAWL_BASE=$(node -e \
    'const fs=require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).crawlBase)' \
    "$SITE/release.json")
[ "$PACKAGED_CRAWL_BASE" = "$CRAWL_BASE" ] \
    || fail "packaged Crawl base does not match wasm/crawl-base"

RELEASE_DIR=$SOURCE/wasm/dist/release
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
./wasm/make-source-tarball.sh "$RELEASE_DIR"

ARCHIVE_NAME=pocketzot-offline-$BUILD.tar.gz
MANIFEST_NAME=pocketzot-offline-$BUILD.json
EPOCH=$(git -C "$ROOT" show -s --format=%ct HEAD)
SITE_TAR=$RELEASE_DIR/.site.tar
tar --sort=name --mtime="@$EPOCH" --owner=0 --group=0 --numeric-owner \
    -cf "$SITE_TAR" -C "$SITE" offline gamedata release.json
gzip -9n -c "$SITE_TAR" > "$RELEASE_DIR/$ARCHIVE_NAME"
rm "$SITE_TAR"
cp "$SITE/release.json" "$RELEASE_DIR/$MANIFEST_NAME"

set -- "$RELEASE_DIR"/pocketzot-engine-src-*.tar.gz
[ "$#" -eq 1 ] && [ -f "$1" ] || fail "source packager did not create exactly one archive"
SOURCE_ARCHIVE=$1
SOURCE_NAME=$(basename "$SOURCE_ARCHIVE")
(
    cd "$RELEASE_DIR"
    sha256sum "$ARCHIVE_NAME" "$MANIFEST_NAME" "$SOURCE_NAME" > SHA256SUMS
    sha256sum -c SHA256SUMS
)

echo "Release candidate ready:"
ls -lh "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/$MANIFEST_NAME" \
    "$SOURCE_ARCHIVE" "$RELEASE_DIR/SHA256SUMS"

if [ "$PUBLISH" -eq 0 ]; then
    echo "Skipped GitHub upload (--no-publish)."
    exit 0
fi

# Recheck mutable Git state after the long build, before creating anything on
# GitHub. Build products are ignored, so any status here is an actual drift.
[ "$HEAD" = "$(git -C "$ROOT" rev-parse HEAD)" ] || fail "HEAD changed during the build"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail "engine checkout changed during the build"
git -C "$ROOT" fetch --quiet --depth=1 --no-tags origin main
[ "$HEAD" = "$(git -C "$ROOT" rev-parse refs/remotes/origin/main)" ] \
    || fail "origin/main changed during the build; inspect and rerun"

TAG=engine-$BUILD
REMOTE_TAGS=$(git -C "$ROOT" ls-remote --tags origin \
    "refs/tags/$TAG" "refs/tags/$TAG^{}")
if [ -n "$REMOTE_TAGS" ]; then
    REMOTE_TAG_COMMIT=$(printf '%s\n' "$REMOTE_TAGS" | awk '$2 ~ /\^\{\}$/ {print $1}')
    [ -n "$REMOTE_TAG_COMMIT" ] \
        || REMOTE_TAG_COMMIT=$(printf '%s\n' "$REMOTE_TAGS" | awk 'NR == 1 {print $1}')
    [ "$REMOTE_TAG_COMMIT" = "$HEAD" ] \
        || fail "remote tag $TAG already points to a different commit"
else
    if EXISTING_COMMIT=$(git -C "$ROOT" rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null); then
        [ "$EXISTING_COMMIT" = "$HEAD" ] || fail "local tag $TAG points to a different commit"
    else
        git -C "$ROOT" tag -a "$TAG" -m "PocketZot engine $CRAWL_VERSION (build $BUILD)" "$HEAD"
    fi
    git -C "$ROOT" push origin "refs/tags/$TAG"
fi

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    fail "GitHub release $TAG already exists; inspect it instead of overwriting assets"
fi

NOTES=$RELEASE_DIR/RELEASE_NOTES.md
{
    printf 'PocketZot offline engine for Crawl %s.\n\n' "$CRAWL_VERSION"
    printf -- '- Build ID: `%s`\n' "$BUILD"
    printf -- '- Engine commit: `%s`\n' "$HEAD"
    printf -- '- Upstream Crawl base: `%s`\n' "$CRAWL_BASE"
    printf -- '- `%s` extracts to the site-root `offline/` and `gamedata/` directories.\n' "$ARCHIVE_NAME"
    printf -- '- `%s` is the complete corresponding source archive.\n' "$SOURCE_NAME"
    printf '\nVerify downloads with `sha256sum -c SHA256SUMS`.\n'
} > "$NOTES"

DRAFT_MAY_EXIST=1
publish_failed() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$DRAFT_MAY_EXIST" -eq 1 ]; then
        echo "error: release publication failed; $TAG may remain as a private draft on GitHub" >&2
    fi
    exit "$status"
}
trap publish_failed EXIT HUP INT TERM

gh release create "$TAG" \
    "$RELEASE_DIR/$ARCHIVE_NAME" \
    "$RELEASE_DIR/$MANIFEST_NAME" \
    "$SOURCE_ARCHIVE" \
    "$RELEASE_DIR/SHA256SUMS" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --draft \
    --latest=false \
    --title "PocketZot engine $CRAWL_VERSION (build $BUILD)" \
    --notes-file "$NOTES"

UPLOADED=$(gh release view "$TAG" --repo "$REPOSITORY" --json assets --jq '.assets[].name')
for asset in "$ARCHIVE_NAME" "$MANIFEST_NAME" "$SOURCE_NAME" SHA256SUMS; do
    printf '%s\n' "$UPLOADED" | grep -Fx "$asset" >/dev/null \
        || fail "draft release is missing uploaded asset $asset"
done

gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest=false
DRAFT_MAY_EXIST=0
trap - EXIT HUP INT TERM

echo "Published https://github.com/$REPOSITORY/releases/tag/$TAG"
echo "Pin the web client to tag $TAG and verify it with SHA256SUMS."
