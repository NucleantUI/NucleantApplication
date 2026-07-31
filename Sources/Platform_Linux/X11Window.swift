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

    init(width: Double, height: Double, title: String) throws {
        try X11Display.shared.connect()
        guard let connection = X11Display.shared.connectionHandle,
              let screen = X11Display.shared.screen
        else {
            throw X11Error.noDisplay
        }
        self.connection = connection
        self.width = width
        self.height = height

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
        X11Display.shared.register(self, for: window)
    }

    deinit {
        destroy()
    }

    // MARK: - Window

    func setTitle(_ title: String) {
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
        _ = xcb_map_window(connection, handle)
        _ = xcb_flush(connection)
    }

    func destroy() {
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
