// What the browser's stand-in for libdispatch (Sources/DispatchWasm) needs
// from outside Swift: the page's timer and the monotonic clock.

#ifndef CDispatchWasm_dispatch_wasm_h
#define CDispatchWasm_dispatch_wasm_h

#if defined(__wasm__)

#include <stdint.h>
#include <wasi/api.h>

/// Asks the page to call the `nucleant_main_queue_run` export in `delay`
/// milliseconds — 0 for as soon as the current call into the module has
/// returned. Implemented by Web/nucleant-app.js; an earlier request than one
/// already pending replaces it.
__attribute__((import_module("nucleant_dom"), import_name("mainQueueWake")))
void ndw_main_queue_wake(double delay);

/// Nanoseconds on the monotonic clock — the one `DispatchTime` counts in, and
/// the one Swift's `ContinuousClock` deadlines are expressed on.
static inline uint64_t ndw_monotonic_nanoseconds(void) {
    __wasi_timestamp_t now = 0;
    (void)__wasi_clock_time_get(__WASI_CLOCKID_MONOTONIC, 1, &now);
    return now;
}

#endif /* __wasm__ */

#endif /* CDispatchWasm_dispatch_wasm_h */
