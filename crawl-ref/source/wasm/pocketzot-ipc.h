/*
 * PocketZot WASM IPC bridge.
 *
 * Under Emscripten the webtiles Unix DGRAM socket is replaced by a JS
 * message queue living on the Emscripten Module object (see wasm/pre.js):
 *
 *   engine -> JS   pocketzot_emit(buf, len)
 *                  calls Module.pocketzotOnOutput(str): one flush of
 *                  newline-terminated JSON lines (identical bytes to what
 *                  finish_message() would have sent over the socket).
 *
 *   JS -> engine   Module.pocketzot.pushControl(json) enqueues one control
 *                  message (the server->binary datagram equivalent);
 *                  pushKeys(text) wraps typed text as {"msg":"text_input"}.
 *                  The engine pops via pocketzot_pop_message() and blocks in
 *                  pocketzot_await_message(), an Asyncify suspension that
 *                  resolves when the queue becomes non-empty.
 *
 * Included exactly once, by tileweb.cc (EM_JS emits real definitions).
 */

#pragma once

#ifdef __EMSCRIPTEN__

#include <emscripten.h>

EM_JS(void, pocketzot_emit, (const char *buf, int len), {
    if (Module['pocketzotOnOutput'])
        Module['pocketzotOnOutput'](UTF8ToString(buf, len));
});

// Returns a malloc'd UTF-8 string (caller frees), or 0 if the queue is empty.
EM_JS(char *, pocketzot_pop_message, (), {
    var q = Module['pocketzot']['queue'];
    if (!q.length)
        return 0;
    var s = q.shift();
    var len = lengthBytesUTF8(s) + 1;
    var p = _malloc(len);
    stringToUTF8(s, p, len);
    return p;
});

EM_JS(bool, pocketzot_has_message, (), {
    return Module['pocketzot']['queue'].length > 0;
});

// Suspends the (Asyncify-instrumented) engine until the queue is non-empty.
EM_ASYNC_JS(void, pocketzot_await_message, (), {
    var pz = Module['pocketzot'];
    if (pz['queue'].length)
        return;
    await new Promise(function(resolve) { pz['wake'] = resolve; });
});

// Flushes the whole IDBFS mount (/crawl) to IndexedDB and blocks (Asyncify)
// until it lands. The mount is NOT autoPersist (wasm/pre.js): the engine
// calls this at consistency points only — package::commit() and end() —
// so a tab death can never leave a torn half-synced save in IndexedDB.
// Callers outside tileweb.cc declare these extern "C" (EM_JS emits one real
// definition, via this header's single include there).
// Returns whether the flush landed: IndexedDB can refuse a write (quota,
// eviction, a broken store), and package::commit() only announces a
// checkpoint to the host when it did -- see pocketzot_checkpoint.
EM_ASYNC_JS(bool, pocketzot_persist, (), {
    return await new Promise(function(resolve) {
        FS.syncfs(false, function(err) {
            if (err)
                console.warn('pocketzot: IDBFS persist failed', err);
            resolve(!err);
        });
    });
});

// Announces to the host that the save package committed AND that the commit
// reached IndexedDB. The host mirrors save state into localStorage to label
// its save slots, which outlives a discarded tab in a way the uncommitted
// turns in wasm memory do not; this line is what tells it the file on disk
// has caught up, so a slot can never advertise progress a resume would not
// produce.
//
// Deliberately emitted from package::commit() and nowhere else. end()'s
// persist is a whole-mount flush on the way out -- the unlinked save after a
// death, morgue/scores/bones, the closed sqlite DBs -- and says nothing about
// the save package, which still holds its last commit; announcing from there
// would have the host label a slot with turns a resume cannot produce, and
// leave it inferring which kind of flush it got from the exit reason. Being
// tied to commit() instead means it covers every consistency point for free:
// level changes, the start-of-game checkpoint, the felid-life and Abyss-shift
// saves, as much as a host-requested checkpoint.
//
// Guarded like pocketzot_emit: an embedder need not install a host callback
// (the cache bake, wasm/bake-caches.mjs, only stubs one).
EM_JS(void, pocketzot_checkpoint, (), {
    if (Module['pocketzotOnOutput'])
        Module['pocketzotOnOutput']('*{"msg":"checkpoint"}\n');
});

#endif // __EMSCRIPTEN__
