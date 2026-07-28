// CWayland — the C surface Platform_Linux talks Wayland through.
//
// libwayland only ships the core protocol (wl_display, wl_compositor,
// wl_seat and friends) as headers; everything else — xdg-shell, which is
// what actually makes a surface a desktop window — is XML that
// wayland-scanner turns into code. Distros package that XML
// (wayland-protocols), not the generated output, and it isn't installed
// everywhere, so the generated client headers + private code are vendored
// here instead. The XML they came from is kept in ../protocols; see
// ../README.md for the regeneration command.
//
// The umbrella-directory module SwiftPM builds from include/ picks up the
// vendored protocol headers on its own; this shim adds the two system
// headers Swift needs but nothing else here pulls in: wayland-client.h for
// the core protocol, and input-event-codes.h for the BTN_*/KEY_* codes
// wl_pointer and wl_keyboard report raw.

#ifndef CWayland_shim_h
#define CWayland_shim_h

#include <wayland-client.h>
#include <linux/input-event-codes.h>

#include "xdg-shell-client-protocol.h"
#include "xdg-decoration-client-protocol.h"

// Interface descriptors, by address.
//
// wl_registry_bind stores the `const struct wl_interface *` it's handed
// inside the proxy it creates, so that pointer has to stay valid for the
// proxy's whole life. Each descriptor is a C global with exactly that
// lifetime — but Swift imports a `const struct` global as an immutable
// value, and taking its address there (`withUnsafePointer(to:)`) is free to
// hand back a pointer to a temporary copy that dies at the end of the call.
// These accessors take the address on the C side, where it's unambiguously
// the global's own, so Swift never has to.
//
// They double as the source of the interface *names* the registry's `global`
// event is matched against (`->name`), which keeps those strings from being
// re-spelled as literals in Swift.

static inline const struct wl_interface *nucleant_wl_compositor_interface(void) {
    return &wl_compositor_interface;
}

static inline const struct wl_interface *nucleant_wl_seat_interface(void) {
    return &wl_seat_interface;
}

// Not used by Platform_Linux — the window layer never touches shared memory,
// since a renderer supplies the buffers. WaylandProbe binds it to paint
// without one.
static inline const struct wl_interface *nucleant_wl_shm_interface(void) {
    return &wl_shm_interface;
}

static inline const struct wl_interface *nucleant_xdg_wm_base_interface(void) {
    return &xdg_wm_base_interface;
}

static inline const struct wl_interface *nucleant_zxdg_decoration_manager_v1_interface(void) {
    return &zxdg_decoration_manager_v1_interface;
}

#endif /* CWayland_shim_h */
