# CWayland

The C module `Platform_Linux` imports. It is `libwayland-client` plus the
protocol code libwayland doesn't ship.

## Why anything is vendored here

`libwayland-dev` installs the *core* protocol only (`wayland-client.h`,
`wayland-client-protocol.h`: `wl_display`, `wl_compositor`, `wl_surface`,
`wl_seat`, `wl_pointer`, `wl_keyboard`, `wl_touch`). A bare `wl_surface` is
not a window — it has no title, no size negotiation, no close button. That
comes from **xdg-shell**, which lives in the `wayland-protocols` package as
XML, not as code: each consumer is expected to run `wayland-scanner` over it
as a build step.

SwiftPM has no build step here, and `wayland-protocols` is not installed on
every machine that can otherwise build and run a Wayland client, so the
generated output is checked in:

| file | generated from |
| --- | --- |
| `include/xdg-shell-client-protocol.h`, `xdg-shell-protocol.c` | `protocols/xdg-shell.xml` (stable, `xdg_wm_base` v6) |
| `include/xdg-decoration-client-protocol.h`, `xdg-decoration-protocol.c` | `protocols/xdg-decoration-unstable-v1.xml` |

xdg-decoration is what asks the compositor for a server-side titlebar.
It's optional at runtime — compositors that don't implement it (GNOME)
simply don't advertise the global, and the window comes up undecorated.

## Regenerating

Needs `libwayland-bin` (for `wayland-scanner`). Run from this directory:

```sh
wayland-scanner client-header protocols/xdg-shell.xml include/xdg-shell-client-protocol.h
wayland-scanner private-code   protocols/xdg-shell.xml xdg-shell-protocol.c
wayland-scanner client-header protocols/xdg-decoration-unstable-v1.xml include/xdg-decoration-client-protocol.h
wayland-scanner private-code   protocols/xdg-decoration-unstable-v1.xml xdg-decoration-protocol.c
```

To move to a newer protocol revision, replace the XML in `protocols/` with
the copy from `/usr/share/wayland-protocols/...` and rerun the above.

## Build requirements

`apt install libwayland-dev` (headers + `libwayland-client.so`, which the
target links by name). `libwayland-bin` is only needed to regenerate.
