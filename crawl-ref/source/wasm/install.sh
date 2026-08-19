#!/bin/sh
# Compatibility entry point. Packaging is now self-contained and never writes
# into a sibling PocketZot checkout.
set -eu

if [ "$#" -ne 0 ]; then
    echo "error: install.sh no longer accepts a client path" >&2
    echo "run package-site-assets.sh, then consume wasm/dist/site" >&2
    exit 2
fi

exec "$(dirname "$0")/package-site-assets.sh"
