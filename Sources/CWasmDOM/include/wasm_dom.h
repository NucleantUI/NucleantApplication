// The browser page, as seen from wasm: the DOM half of Platform_Wasm.
//
// Every function here is an import of the "nucleant_dom" module, implemented
// by Web/nucleant-app.js — the browser counterpart of what libwayland-client
// or AppKit provide on the other platforms. A window is a <canvas> element
// with the id "nucleant-window-<id>" (that string is the CSS selector the
// render engine's VK_NUCLEANT_webgpu_surface takes). Events travel the other
// way, as calls into the exports Platform_Wasm declares (BrowserEvents.swift).

#ifndef CWasmDOM_wasm_dom_h
#define CWasmDOM_wasm_dom_h

#if defined(__wasm__)

#include <stdint.h>

#define NWD_IMPORT(name) __attribute__((import_module("nucleant_dom"), import_name(#name)))

/// Adds a window to the page: a focusable <canvas> of `width` × `height` CSS
/// pixels. Returns its id (never 0).
NWD_IMPORT(windowCreate)        uint32_t nwd_window_create(const char *title, uint32_t titleLength, double width, double height);
NWD_IMPORT(windowDestroy)       void     nwd_window_destroy(uint32_t window);
NWD_IMPORT(windowSetTitle)      void     nwd_window_set_title(uint32_t window, const char *title, uint32_t length);
/// [CSS width, CSS height, device pixels per CSS pixel, canvas width, canvas height]
NWD_IMPORT(windowGetMetrics)    void     nwd_window_get_metrics(uint32_t window, double *metrics);
NWD_IMPORT(windowSetFullscreen) void     nwd_window_set_fullscreen(uint32_t window, uint32_t fullscreen);
NWD_IMPORT(windowFocus)         void     nwd_window_focus(uint32_t window);
/// How the canvas is sized: at the size it was created at, or (`fills` 1)
/// filling its container and following it, which needs a container with a
/// height of its own. Either way kept within [min, max] CSS pixels; 0 and
/// Infinity mean no limit. The new size arrives as a resize.
NWD_IMPORT(windowSetLayout)     void     nwd_window_set_layout(uint32_t window, uint32_t fills, double minWidth, double minHeight, double maxWidth, double maxHeight);

/// A string of the event being delivered: 0 is the key's `code`
/// ("KeyA", "ArrowLeft"), 1 its `key` ("a", "Enter"). Copies at most
/// `capacity` UTF-8 bytes and returns the full length.
NWD_IMPORT(eventString)         uint32_t nwd_event_string(uint32_t which, char *buffer, uint32_t capacity);

/// Starts / stops the requestAnimationFrame loop that calls the
/// `nucleant_frame` export once per display refresh.
NWD_IMPORT(frameLoopStart)      void     nwd_frame_loop_start(void);
NWD_IMPORT(frameLoopStop)       void     nwd_frame_loop_stop(void);

/// The page's `prefers-color-scheme`: 1 dark, 0 light. Each later change
/// arrives as a call of the `nucleant_color_scheme_changed` export.
NWD_IMPORT(colorSchemeIsDark)   uint32_t nwd_color_scheme_is_dark(void);

/// The address the page serves the mounted resource file at `path` from
/// (resources.json), as an absolute URL; empty when `path` is not under the
/// mounted resources. Copies at most `capacity` UTF-8 bytes and returns the
/// full length, as `eventString` does.
NWD_IMPORT(resourceURL)         uint32_t nwd_resource_url(const char *path, uint32_t pathLength, char *buffer, uint32_t capacity);

// MARK: - Frames
//
// A web page laid over a window: an <iframe> the page positions over the
// window's canvas, in the window's CSS pixels. Hidden until placed. A page
// from the app's own origin can be scripted (`frameEvaluate`) and is given a
// query function — `window[queryName]` and `window[queryName + "Cancel"]`,
// shaped like CEF's `window.cefQuery` — whose calls arrive through the
// `nucleant_browser_frame_query` export and are answered through
// `frameQueryAnswer`. Loads and console output arrive through exports too
// (BrowserFrame.swift).

/// A new, hidden frame. `background` is its CSS background, ARGB; an empty
/// `queryName` gives the page no query function. Returns its id (never 0).
NWD_IMPORT(frameCreate)         uint32_t nwd_frame_create(uint32_t background, const char *queryName, uint32_t queryNameLength);
NWD_IMPORT(frameDestroy)        void     nwd_frame_destroy(uint32_t frame);
/// Over `window`: [x, y, width, height] of the frame, then [x, y, width,
/// height] of the part of it that shows — CSS pixels from the canvas's
/// top-left. Nothing shows when the second is empty.
NWD_IMPORT(frameSetGeometry)    void     nwd_frame_set_geometry(uint32_t frame, uint32_t window, const double *geometry);
NWD_IMPORT(frameSetHidden)      void     nwd_frame_set_hidden(uint32_t frame, uint32_t hidden);
/// Navigates to `url`, absolute or relative to the page.
NWD_IMPORT(frameLoad)           void     nwd_frame_load(uint32_t frame, const char *url, uint32_t length);
/// Runs `script` in the frame's page, once the current call has returned.
NWD_IMPORT(frameEvaluate)       void     nwd_frame_evaluate(uint32_t frame, const char *script, uint32_t length);
/// 0 back, 1 forward, 2 reload, 3 reload past the cache, 4 stop.
NWD_IMPORT(frameNavigate)       void     nwd_frame_navigate(uint32_t frame, uint32_t action);
/// The page's zoom, 1 being 100%.
NWD_IMPORT(frameSetZoom)        void     nwd_frame_set_zoom(uint32_t frame, double factor);
/// Answers `query`: its onSuccess gets `text` when `success` is 1, else its
/// onFailure gets `code` and `text`. A failure, or any answer to a query
/// that isn't persistent, finishes it.
NWD_IMPORT(frameQueryAnswer)    void     nwd_frame_query_answer(uint32_t frame, uint32_t query, uint32_t success, int32_t code, const char *text, uint32_t length);

#endif /* __wasm__ */

#endif /* CWasmDOM_wasm_dom_h */
