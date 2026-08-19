// PocketZot WASM engine: Module-level message queue (see wasm/pocketzot-ipc.h
// for the C++ side). Loaded via --pre-js, so it runs before the runtime and
// the host (engine.worker.ts in the PocketZot client) can rely on
// Module.pocketzot existing as soon as the factory resolves.

// Headless webtiles invocation. -webtiles-socket only needs to be non-empty
// (keeps the m_sock_name.empty() guards live; no socket is created under
// __EMSCRIPTEN__). /crawl is the persistent IDBFS mount below. A host can
// supply its own argv (wasm/bake-caches.mjs appends --builddb).
// No -dir here: CRAWL_DIR goes in via the environment (preRun below) — the
// env path (initfile.cc get_system_environment) avoids the flag's
// triplicated "Setting crawl_dir..." boot-log line.
Module['arguments'] = Module['arguments'] || [
    '-headless',
    '-webtiles-socket', 'pocketzot',
    '-name', 'local',
];

// Writable game dir (saves, morgue, bones, generated description DBs) on
// IDBFS: hydrate from IndexedDB before main() runs. Persistence is batched,
// NOT autoPersist: the engine calls pocketzot_persist() (pocketzot-ipc.h) at
// consistency points — package::commit() and process exit — so IndexedDB
// only ever sees whole save states, never a mid-write torn one, and normal
// play does zero IDB traffic. dat/ and docs/ arrive read-only via the
// preload .data bundle.
Module['preRun'] = (Module['preRun'] || []).concat(function () {
    // Trailing slash: get_system_environment expects crawl_dir to end with
    // the path delimiter (the -dir flag path appends it; getenv does not).
    ENV.CRAWL_DIR = '/crawl/';
    try { FS.mkdir('/crawl'); } catch (e) { /* exists */ }
    // No IndexedDB (the node cache-bake run): plain MEMFS, nothing persists.
    if (typeof indexedDB === 'undefined')
        return;
    FS.mount(IDBFS, {}, '/crawl');
    addRunDependency('pocketzot-idbfs');
    FS.syncfs(true, function () {
        // Host hook, called after hydration and before main(): the client
        // worker seeds the shipped pre-baked caches (dist/prewarm/) into
        // /crawl here, so first boot skips the in-engine cache build. Async
        // (may fetch); boot proceeds on failure — the engine just rebuilds.
        var seed = Module['pocketzotSeedCaches'];
        if (!seed) { removeRunDependency('pocketzot-idbfs'); return; }
        Promise.resolve(seed(FS))
            .catch(function (e) { console.warn('pocketzot: cache seeding failed', e); })
            .then(function () { removeRunDependency('pocketzot-idbfs'); });
    });
});

Module['pocketzot'] = {
    queue: [],
    wake: null,
    // One control message (the server->binary datagram equivalent),
    // forwarded verbatim: key, menu_hover, menu_scroll, text_input, ...
    pushControl: function (json) {
        this.queue.push(json);
        if (this.wake) {
            var w = this.wake;
            this.wake = null;
            w();
        }
    },
    // Typed-key text. The engine's text_input handler buffers the whole
    // string and drains it through getch before reading the next datagram,
    // so multi-char sequences (e.g. the spell rail's "za") stay atomic.
    pushKeys: function (text) {
        this.pushControl(JSON.stringify({ msg: 'text_input', text: text }));
    },
    // Heap gauge: current wasm memory size in bytes. HEAPU8 is the enclosing
    // module scope's view var — re-created on every ALLOW_MEMORY_GROWTH
    // grow, so its length is always current; undefined until the runtime
    // initializes. Memory never shrinks (MAXIMUM_MEMORY caps it at 512 MB).
    heapBytes: function () {
        return typeof HEAPU8 === 'undefined' || !HEAPU8 ? 0 : HEAPU8.length;
    },
};
