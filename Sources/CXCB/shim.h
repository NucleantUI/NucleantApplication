// CXCB — system libxcb (core protocol only: window creation, properties,
// atoms, event polling). No xcb-icccm/xcb-ewmh: WM_PROTOCOLS/_NET_WM_NAME/etc
// are set with plain xcb_change_property calls in Swift, so those extra
// libraries aren't needed.
#ifndef CXCB_shim_h
#define CXCB_shim_h

#include <xcb/xcb.h>

#endif /* CXCB_shim_h */
