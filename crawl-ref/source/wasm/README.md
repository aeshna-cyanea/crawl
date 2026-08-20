# PocketZot WASM engine build

This is a fork of Dungeon Crawl Stone Soup (GPL) that compiles the **webtiles**
game binary to WebAssembly so [PocketZot](https://pocketzot.app) can run DCSS fully
offline in the browser. It is ported directly from the upstream Makefile/source.

## What the port does

The webtiles binary normally talks to a Python/Tornado server over a Unix
DGRAM socket (JSON out) + pty (typed keys in). The port replaces that IPC with
an in-page JS message queue and runs headless:

| Concern | Upstream | Port |
|---|---|---|
| Outbound JSON | `sendto()` datagrams (`tileweb.cc` finish_message) | `pocketzot_emit()` → `Module.pocketzotOnOutput(str)` |
| Inbound control | `recvfrom()` (key/menu/attach/…) | `Module.pocketzot.pushControl(json)` → queue |
| Typed keys | pty write | `Module.pocketzot.pushKeys(text)` → `{msg:text_input}` |
| Blocking wait | `pselect()` on stdin+sock (`await_input`) | `pocketzot_await_message()` — Asyncify suspend |
| Terminal | ncurses | `wasm/fake-curses.h` (inert; headless mode) |

## Patched files

Each patch carries its full rationale as a comment at the site; this is the
map.

- `tileweb.cc` / `tileweb.h` — the IPC swap (`initialise`, `finish_message`,
  `_receive_control_message`, `_await_connection`, `try_await_input`,
  `await_input`); `_send_everything`'s map block gated on `m_view_loaded`;
  the `checkpoint` control message + `_maybe_checkpoint()`, which saves at
  the next moment the player has control (the host asks when the browser
  backgrounds the tab).
- `files.cc` — `file_modtime()` returns the per-build constant
  `POCKETZOT_DAT_STAMP` so the IDBFS-persisted caches survive preloaded
  MEMFS's fresh per-boot mtimes; `save_game()`'s `__ANDROID__` pause-save
  block extended to Emscripten, for the same reason Android has it — a
  mobile OS discards backgrounded apps, so a checkpoint must include the
  level chunk and not just the player.
- `message.cc` — `webtiles_send_messages()` ungated pre-game, so startup
  messages and prompts reach the client.
- `startup.cc` / `database.cc` — the first-launch cache build streams
  progress messages instead of a black screen.
- `package.cc` / `end.cc` — `pocketzot_persist()` (batched IDBFS flush) at
  the two points that need one: `package::commit()`, the save's consistency
  point, and `end()`, a whole-mount flush on the way out. Only the former
  announces the starred `checkpoint` line — rationale in
  `wasm/pocketzot-ipc.h` (`pocketzot_checkpoint`).
- `ui.cc` — `UIRoot::render()` paints even in headless mode, so CRT-drawn
  ui popups reach the webtiles client.
- `crash.cc` — no backtrace support under Emscripten.
- New under `wasm/`: `pocketzot-ipc.h` (EM_JS bridge), `pre.js` (queue +
  headless argv + IDBFS mount + cache-seed hook), `fake-curses.h`,
  `include/term.h` (empty stub), `Makefile.emscripten`, `gen-objects.sh`,
  `latest-mtime.mjs` (portable cache-invalidation stamp), `bake-caches.mjs`
  (pre-warms first-boot caches), and the package/release scripts documented
  below.

## Building

The normal release path is one command, run locally with `emcc` and `em++` on
`PATH` (an activated emsdk or a distribution Emscripten package both work):

```sh
cd crawl-ref/source

# Full clean build and local release candidate; does not contact GitHub.
./wasm/release.sh

# Full clean build, then upload and publish a release on the origin fork.
./wasm/release.sh --publish
```

Both forms build natively, cross-compile, bake caches, package site assets,
make the complete corresponding source archive, and write checksums. The local
build does not require GitHub CLI. The `--publish` form additionally requires
an installed and authenticated `gh` command. It refuses
a dirty checkout, missing or wrong submodules, a detached/non-`master` branch,
an unpushed commit, an upstream `origin`, an existing release, or missing
build tools. GitHub receives a draft first; it becomes public only after all
four assets are present.

Set `JOBS=N` or pass `--jobs N` to control local CPU use. Engine compilation
does not run in GitHub Actions.

For development, the equivalent manual build is:

```sh
# Host prerequisites: native Crawl dependencies, PyYAML, and emsdk active.
cd crawl-ref/source
export CRAWL_VERSION_OVERRIDE=$(cat wasm/crawl-version)

# Native bootstrap generates headers, rltiles data, levcomp, and DBs.
make -j8 WEBTILES=y
# Derive the wasm object list from that native link line.
./wasm/gen-objects.sh
# Cross-compile (the Asyncify link is the slow step).
make -f wasm/Makefile.emscripten -j8
# Pre-warm first-boot caches; rerun after any dat/ or engine change.
node wasm/bake-caches.mjs
# Assemble a self-contained site payload under wasm/dist/site.
./wasm/package-site-assets.sh
```

Outputs (`wasm/dist/`): `crawl.js` (~217 KB glue), `crawl.wasm` (~23 MB),
`crawl.data` (~11.6 MB preloaded `dat/`+`docs/`; `dat/tiles` excluded),
and `prewarm/` (~11 MB of pre-baked caches + manifest).

`bake-caches.mjs` runs the worker-only browser module under Node with
`-builddb`, captures the generated description databases and des cache, and
packs them into `prewarm.bin`. It loads `crawl.wasm` and `crawl.data` through
Node's filesystem API and injects them into the module; the shipped
`crawl.js` remains browser-worker-only and continues to fetch those files over
HTTP. This explicit instantiation is required by Emscripten 6, whose async
worker output no longer consumes `Module.wasmBinary` by default.

The value baked into `POCKETZOT_DAT_STAMP` is computed by
`latest-mtime.mjs`. Do not replace it with BSD-only `stat -f %m`: on GNU/Linux
that command reports filesystem statistics rather than a file modification
time and produces an invalid compiler definition.

`package-site-assets.sh` creates `wasm/dist/site/offline/` and
`wasm/dist/site/gamedata/local/`, plus `release.json` with the Crawl version,
engine commit, build ID, sizes, and SHA-256 of every shipped file. It never
writes into a PocketZot client checkout. A client build can extract the
released site archive at its output root. The argument-free `install.sh` is a
compatibility alias for this self-contained packaging step; it rejects the old
client-checkout argument to prevent accidental cross-repository writes.

`wasm/dist/release/` contains:

- `pocketzot-offline-<build>.tar.gz` — the deployable site payload;
- `pocketzot-offline-<build>.json` — the payload manifest;
- `pocketzot-engine-src-<version>-<build>.tar.gz` — complete corresponding
  source, including every pinned dependency submodule;
- `SHA256SUMS` — checksums for those three assets.

The release tag is `engine-<build>`, where `<build>` remains the client's
12-character content cache key derived from the raw wasm, data, and prewarm
files.

### Version provenance

This repository is a direct fork of `crawl/crawl`, but local clones are
intentionally shallow and PocketZot's own commits sit after the upstream base.
Neither a shallow `git describe` nor one run at the engine commit therefore
provides the desired Crawl identity. `wasm/crawl-base` records the exact
upstream commit and `wasm/crawl-version` records its upstream `git describe`
identity. `release.sh` exports the latter as `CRAWL_VERSION_OVERRIDE`, and the
native Makefile uses it consistently for `build.h`, `.ver`, and WebTiles
metadata. Update and verify both files whenever rebasing the port onto a newer
Crawl commit; no build or deploy step needs Crawl's full local history.

Run the fast release-tool fixtures without compiling the engine:

```sh
./wasm/test-release-tools.sh
```

Build-flag rationale lives in `Makefile.emscripten` next to the flags.

## Runtime

Headless argv (`wasm/pre.js`, host-overridable): `-headless
-webtiles-socket pocketzot -name local`; the crawl dir arrives as
`ENV.CRAWL_DIR = '/crawl/'`. `/crawl` is an IDBFS mount (saves, morgue,
bones, generated caches) with batched persistence — the model is documented
in `pre.js` and `pocketzot-ipc.h`, the shipped prewarm pack in
`bake-caches.mjs`. A host must send the webtiles `attach` handshake after
boot (as upstream's `connection.py` does): without it `has_receivers()`
stays false and the engine never emits `map`/`player`.
