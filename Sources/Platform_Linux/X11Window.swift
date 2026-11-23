//
//  X11Window.swift
//  NucleantApplication
//
//  A single X11 top-level window — the counterpart of `WaylandSurface`.
//  Unlike Wayland, X11 has no per-surface frame-callback protocol to pace
//  rendering off; `pumpFallbackTick` (driven by `X11Display.tickWindows`,
//  every event-loop turn) is the only frame clock here, not a fallback for
//  one.
//
#if os(Linux)
import CXCB
import Glibc

final class X11Window {

    weak var handler: WaylandSurfaceHandler?

    private let connection: OpaquePointer
    let handle: xcb_window_t

    private(set) var width: Double
    private(set) var height: Double
    /// X11 has no standard fractional-scale protocol the way Wayland does;
    /// callers wanting HiDPI-aware scaling would read `Xft.dpi` themselves.
    /// 1:1 points-to-pixels here, same as `WaylandSurface` before a compositor
    /// reports otherwise.
    let scale: Double = 1.0
    var bufferWidth: UInt32 { UInt32(max(width, 0)) }
    var bufferHeight: UInt32 { UInt32(max(height, 0)) }

    private var lastFrameTime: Double?
    private var frameLoopRunning = false

    /// A tray item's window: no title bar, above the other windows, not in
    /// the taskbar, and placed by the app.
    let isTrayPanel: Bool

    /// Mapped — on screen, as far as this client is concerned.
    private(set) var isMapped = false

    init(width: Double, height: Double, title: String, isTrayPanel: Bool = false) throws {
        try X11Display.shared.connect()
        guard let connection = X11Display.shared.connectionHandle,
              let screen = X11Display.shared.screen
        else {
            throw X11Error.noDisplay
        }
        self.connection = connection
        self.width = width
        self.height = height
        self.isTrayPanel = isTrayPanel

        let window = xcb_generate_id(connection)
        self.handle = window

        let valueMask: UInt32 = XCB_CW_EVENT_MASK.rawValue
        var eventMask: UInt32 = XCB_EVENT_MASK_EXPOSURE.rawValue
            | XCB_EVENT_MASK_STRUCTURE_NOTIFY.rawValue
            | XCB_EVENT_MASK_BUTTON_PRESS.rawValue
            | XCB_EVENT_MASK_BUTTON_RELEASE.rawValue
            | XCB_EVENT_MASK_POINTER_MOTION.rawValue
            | XCB_EVENT_MASK_KEY_PRESS.rawValue
            | XCB_EVENT_MASK_KEY_RELEASE.rawValue
            | XCB_EVENT_MASK_FOCUS_CHANGE.rawValue

        withUnsafeMutablePointer(to: &eventMask) { eventMaskPtr in
            _ = xcb_create_window(
                connection,
                UInt8(XCB_COPY_FROM_PARENT),
                window,
                screen.root,
                0, 0,
                UInt16(max(width, 1)), UInt16(max(height, 1)),
                0,
                UInt16(XCB_WINDOW_CLASS_INPUT_OUTPUT.rawValue),
                screen.root_visual,
                valueMask,
                eventMaskPtr
            )
        }

        // WM_PROTOCOLS / WM_DELETE_WINDOW: without this the WM just kills the
        // X connection on close instead of giving us a client message to
        // react to, same purpose as xdg_wm_base's close-request on Wayland.
        var deleteAtom = X11Display.shared.wmDeleteWindowAtom
        withUnsafeMutablePointer(to: &deleteAtom) { atomPtr in
            _ = xcb_change_property(
                connection,
                UInt8(XCB_PROP_MODE_REPLACE.rawValue),
                window,
                X11Display.shared.wmProtocolsAtom,
                UInt32(XCB_ATOM_ATOM.rawValue),
                32,
                1,
                atomPtr
            )
        }

        setTitle(title)
        identifyApp()
        if isTrayPanel {
            describeTrayPanel()
        }
        X11Display.shared.register(self, for: window)
    }

    /// Which app the window is: `WM_CLASS`, what docks, taskbars and the
    /// window switcher group an app's windows under and match to its
    /// launcher, and `_NET_WM_PID` with `WM_CLIENT_MACHINE`, the process
    /// it is — without them every window is an app of its own. The class
    /// is the executable's name, as a .desktop file's `StartupWMClass`
    /// names it.
    private func identifyApp() {
        let name = linuxAppID
        let instanceAndClass = Array(name.utf8) + [0] + Array(name.utf8) + [0]
        instanceAndClass.withUnsafeBufferPointer { buffer in
            _ = xcb_change_property(
                connection, UInt8(XCB_PROP_MODE_REPLACE.rawValue), handle,
                UInt32(XCB_ATOM_WM_CLASS.rawValue), UInt32(XCB_ATOM_STRING.rawValue), 8,
                UInt32(buffer.count), buffer.baseAddress
            )
        }
        var host = [CChar](repeating: 0, count: 256)
        if gethostname(&host, host.count - 1) == 0 {
            let machine = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            machine.withUnsafeBufferPointer { buffer in
                _ = xcb_change_property(
                    connection, UInt8(XCB_PROP_MODE_REPLACE.rawValue), handle,
                    UInt32(XCB_ATOM_WM_CLIENT_MACHINE.rawValue), UInt32(XCB_ATOM_STRING.rawValue), 8,
                    UInt32(buffer.count), buffer.baseAddress
                )
            }
        }
        setProperty(X11Display.shared.atom("_NET_WM_PID"), type: UInt32(XCB_ATOM_CARDINAL.rawValue),
                    [UInt32(getpid())])
    }

    /// What makes the window manager treat it as a tray item's window: no
    /// decorations (Motif's hints, which every window manager still reads),
    /// kept above the other windows and out of the taskbar and the pager
    /// (EWMH's initial state). A managed window rather than an
    /// override-redirect one, so it takes the keys like any other.
    private func describeTrayPanel() {
        let display = X11Display.shared
        // flags: MWM_HINTS_DECORATIONS; functions, decorations, input mode,
        // status: none.
        let motif: [UInt32] = [2, 0, 0, 0, 0]
        setProperty(display.atom("_MOTIF_WM_HINTS"), type: display.atom("_MOTIF_WM_HINTS"), motif)
        setProperty(display.atom("_NET_WM_WINDOW_TYPE"), type: UInt32(XCB_ATOM_ATOM.rawValue),
                    [display.atom("_NET_WM_WINDOW_TYPE_UTILITY")])
        setProperty(display.atom("_NET_WM_STATE"), type: UInt32(XCB_ATOM_ATOM.rawValue), [
            display.atom("_NET_WM_STATE_ABOVE"),
            display.atom("_NET_WM_STATE_SKIP_TASKBAR"),
            display.atom("_NET_WM_STATE_SKIP_PAGER"),
        ])
    }

    private func setProperty(_ property: xcb_atom_t, type: xcb_atom_t, _ values: [UInt32]) {
        guard property != 0 else { return }
        values.withUnsafeBufferPointer { buffer in
            _ = xcb_change_property(
                connection, UInt8(XCB_PROP_MODE_REPLACE.rawValue), handle, property, type, 32,
                UInt32(buffer.count), buffer.baseAddress
            )
        }
    }

    deinit {
        destroy()
    }

    // MARK: - Window

    func setTitle(_ title: String) {
        // WM_NAME as well, for what reads only ICCCM's: a STRING is
        // Latin-1, so the UTF-8 title stands in only where it is ASCII.
        let legacy = title.unicodeScalars.allSatisfy(\.isASCII) ? title : linuxAppID
        legacy.utf8CString.withUnsafeBufferPointer { buf in
            _ = xcb_change_property(
                connection, UInt8(XCB_PROP_MODE_REPLACE.rawValue), handle,
                UInt32(XCB_ATOM_WM_NAME.rawValue), UInt32(XCB_ATOM_STRING.rawValue), 8,
                UInt32(buf.count - 1), buf.baseAddress
            )
        }
        title.utf8CString.withUnsafeBufferPointer { buf in
            let len = buf.count - 1 // exclude the trailing NUL xcb doesn't want counted
            _ = xcb_change_property(
                connection,
                UInt8(XCB_PROP_MODE_REPLACE.rawValue),
                handle,
                X11Display.shared.netWmNameAtom,
                X11Display.shared.utf8StringAtom,
                8,
                UInt32(len),
                buf.baseAddress
            )
        }
    }

    /// Minimize/maximize/fullscreen all need the window manager's cooperation
    /// via EWMH client messages (`_NET_WM_STATE`, `WM_CHANGE_STATE`) that
    /// aren't wired up yet — a plain top-level window is enough to get real,
    /// WM-decorated, movable windows working; these are no-ops until that's
    /// added.
    func minimize() {}
    func setMaximized(_ maximized: Bool) {}
    func setFullscreen(_ fullscreen: Bool) {}

    func show() {
        isMapped = true
        _ = xcb_map_window(connection, handle)
        _ = xcb_flush(connection)
    }

    /// Off the screen, until `show()`. Unmapped, it is withdrawn: the
    /// window manager forgets it, and places it again when it is mapped.
    func hide() {
        guard isMapped else { return }
        isMapped = false
        _ = xcb_unmap_window(connection, handle)
        _ = xcb_flush(connection)
    }

    /// Puts the window's top-left corner at `x`, `y` in root-window pixels.
    ///
    /// Unmapped, the window is the client's to move: configured there, and
    /// said in the size hints as the user's choice — what a window manager
    /// honours when it maps the window rather than placing it itself.
    /// Mapped, it is the window manager's, which is asked with
    /// `_NET_MOVERESIZE_WINDOW`: a configure request is relative to the
    /// frame the window was put in, and lands somewhere else.
    func move(x: Double, y: Double) {
        let left = Int32(x.rounded()), top = Int32(y.rounded())
        if isMapped {
            let display = X11Display.shared
            var event = xcb_client_message_event_t()
            event.response_type = UInt8(XCB_CLIENT_MESSAGE)
            event.format = 32
            event.window = handle
            event.type = display.atom("_NET_MOVERESIZE_WINDOW")
            // Gravity: the window's own (0); x and y given (bits 8, 9);
            // source: a pager (bit 13), as for `activate()`.
            let flags: UInt32 = 0 | 1 << 8 | 1 << 9 | 2 << 12
            event.data.data32 = (flags, UInt32(bitPattern: left), UInt32(bitPattern: top), 0, 0)
            sendToRoot(&event)
            return
        }
        var hints = [UInt32](repeating: 0, count: 18)
        hints[0] = 1 | 2 | 4 | 8        // USPosition, USSize, PPosition, PSize
        hints[1] = UInt32(bitPattern: left)
        hints[2] = UInt32(bitPattern: top)
        hints[3] = UInt32(max(width, 1))
        hints[4] = UInt32(max(height, 1))
        setProperty(UInt32(XCB_ATOM_WM_NORMAL_HINTS.rawValue), type: UInt32(XCB_ATOM_WM_SIZE_HINTS.rawValue), hints)
        let values: [UInt32] = [UInt32(bitPattern: left), UInt32(bitPattern: top)]
        values.withUnsafeBufferPointer { buffer in
            _ = xcb_configure_window(
                connection, handle,
                UInt16(XCB_CONFIG_WINDOW_X.rawValue | XCB_CONFIG_WINDOW_Y.rawValue),
                buffer.baseAddress
            )
        }
        _ = xcb_flush(connection)
    }

    /// A client message for the window manager, which listens on the root
    /// window.
    private func sendToRoot(_ event: inout xcb_client_message_event_t) {
        withUnsafePointer(to: &event) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<xcb_client_message_event_t>.size) {
                _ = xcb_send_event(
                    connection, 0, X11Display.shared.rootWindow,
                    XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT.rawValue | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY.rawValue,
                    $0
                )
            }
        }
        _ = xcb_flush(connection)
    }

    /// Resizes the window to `width` × `height` pixels. Taken as its size at
    /// once, rather than when the server confirms it — the swapchain reads
    /// it for the next frame.
    func resize(width: Double, height: Double) {
        let values: [UInt32] = [UInt32(max(width, 1)), UInt32(max(height, 1))]
        values.withUnsafeBufferPointer { buffer in
            _ = xcb_configure_window(
                connection, handle,
                UInt16(XCB_CONFIG_WINDOW_WIDTH.rawValue | XCB_CONFIG_WINDOW_HEIGHT.rawValue),
                buffer.baseAddress
            )
        }
        _ = xcb_flush(connection)
        handleConfigure(width: width, height: height)
    }

    /// Asks the window manager to raise the window and give it the keys:
    /// `_NET_ACTIVE_WINDOW`, from a pager — the source a window manager's
    /// focus-stealing prevention lets through, as the app is acting on a
    /// click the person made, only not in one of its windows.
    func activate() {
        let display = X11Display.shared
        var event = xcb_client_message_event_t()
        event.response_type = UInt8(XCB_CLIENT_MESSAGE)
        event.format = 32
        event.window = handle
        event.type = display.atom("_NET_ACTIVE_WINDOW")
        event.data.data32 = (2, 0, 0, 0, 0)          // source: pager; time: now
        sendToRoot(&event)
    }

    func destroy() {
        isMapped = false
        X11Display.shared.unregister(handle)
        _ = xcb_destroy_window(connection, handle)
        _ = xcb_flush(connection)
    }

    // MARK: - Frame loop

    func startFrameLoop() {
        frameLoopRunning = true
    }

    func stopFrameLoop() {
        frameLoopRunning = false
    }

    /// Called every `X11Display.pumpEvents` turn — the only clock a plain X11
    /// window has, there being no per-surface frame callback the way
    /// Wayland's `wl_surface.frame` provides.
    func pumpFallbackTick(now: Double) {
        guard frameLoopRunning else { return }
        let dt = lastFrameTime.map { now - $0 } ?? (1.0 / 60.0)
        lastFrameTime = now
        handler?.waylandSurfaceDidTick(dt: dt)
    }

    // MARK: - Events from X11Display

    func handleConfigure(width: Double, height: Double) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        handler?.waylandSurfaceDidResize(width: width, height: height)
    }
}
#endif
