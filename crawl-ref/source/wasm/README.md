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
  `bake-caches.mjs` (pre-warms first-boot caches), `install.sh`.

## Building

```sh
# 1. host toolchain: emsdk active, PyYAML installed
# 2. native build first, generates headers, rltiles data, levcomp, DBs.
cd crawl-ref/source && make -j8 WEBTILES=y USE_MERGE_BASE=upstream/master
# 3. derive the object list from the upstream link line:
./wasm/gen-objects.sh
# 4. cross-compile to wasm (Asyncify link is the slow step):
make -f wasm/Makefile.emscripten -j8
# 5. pre-warm the first-boot caches (runs the wasm engine once under node
#    with -builddb; must re-run after any dat/ or engine change):
node wasm/bake-caches.mjs
# 6. install artifacts into a PocketZot checkout (gitignored there):
./wasm/install.sh ../../../pocketzot
```

Outputs (`wasm/dist/`): `crawl.js` (~217 KB glue), `crawl.wasm` (~23 MB),
`crawl.data` (~11.6 MB preloaded `dat/`+`docs/`; `dat/tiles` excluded),
`prewarm/` (~11 MB of pre-baked caches + manifest). install.sh also ships
`enums.js` plus the tile atlases + tileinfo modules from
`webserver/game_data/static/` (~8 MB) to the client's
`public/gamedata/local/` — that is what makes tiles mode work offline.

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
