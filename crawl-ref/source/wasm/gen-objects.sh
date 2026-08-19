#!/bin/sh
# Derives the wasm object list from the upstream Makefile's own WEBTILES link
# command (ground truth, survives upstream object-list changes). Run from
# crawl-ref/source after a successful native `make WEBTILES=y` (which also
# produces the generated sources the wasm build compiles).
set -e
cd "$(dirname "$0")/.."
make WEBTILES=y -n -W main.o crawl 2>/dev/null \
  | tr ' ' '\n' \
  | grep '\.o$' \
  | grep -v '^-' \
  | awk '!seen[$0]++' \
  > wasm/objects.txt
count=$(wc -l < wasm/objects.txt | tr -d ' ')
echo "wasm/objects.txt: $count objects"
