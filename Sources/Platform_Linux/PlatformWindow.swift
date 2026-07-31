//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(Linux)
import NucleantWindow
import CWayland
import CXCB

/// The Linux counterpart to macOS's `NSWindow`-derived `PlatformWindow` and
/// iOS's `UIWindow` one: a toplevel that paces frames off its windowing
/// system and forwards pointer, keyboard and touch input to its
/// `win_delegate`. Picks Wayland or X11 at init time via `LinuxSession.detect()`
/// — most desktop Linux is still X11 by default, so this is what makes
/// windows real, WM-managed, movable top-levels there instead of requiring a
/// Wayland session that mightn't exist.
///
/// Kept generic (not existential) for the same reason as the other two —
/// `NucleantWindow` has an associated `Node`, so a concrete `WindowBase` type
/// is needed to call its members. The C-callback plumbing that can't live in
/// a generic context sits one layer down in `WaylandSurface` / `X11Window`.
///
/// ## Vulkan
///
/// There is no `CAMetalLayer` here to hand a render engine. Each backend has
/// its own native surface handle shape (`VkWaylandSurfaceCreateInfoKHR` wants
/// `wl_display*`/`wl_surface*`; `VkXcbSurfaceCreateInfoKHR` wants
/// `xcb_connection_t*`/`xcb_window_t`) — `vulkanSurfaceKind` is what a caller
/// switches on to know which `VulkanRenderEngine` initializer to use. Size the
/// swapchain from `bufferWidth`/`bufferHeight`, which are in device pixels
/// rather than the logical points the delegate callbacks use.
public final class PlatformWindow<WindowBase>: WaylandSurfaceHandler
    where WindowBase: NucleantWindow & WaylandWindowDelegate {

    /// Which native surface handles to build a `VulkanRenderEngine` from.
    public enum VulkanSurfaceKind {
        case wayland(display: OpaquePointer?, surface: OpaquePointer?)
        case xcb(connection: OpaquePointer?, window: xcb_window_t)
    }

    /// Called when the windowing system relays a close request (the
    /// titlebar's ✕). Set it to take over what closing means; leave it nil
    /// and the window tears itself down and stops the event loop, which is
    /// the `applicationShouldTerminateAfterLastWindowClosed` behaviour macOS
    /// has.
    public var on_close: (() -> Void)?

    /// Strongly held by the owner; referenced weakly here so the window
    /// doesn't retain its delegate. Same contract as macOS/iOS.
    public weak var win_delegate: WindowBase?

    private enum Backend {
        case wayland(WaylandSurface)
        case x11(X11Window)
    }
    private let backend: Backend

    // MARK: - Init

    /// - Parameters:
    ///   - width: requested width in logical points. The windowing system
    ///     gets the final say — a tiling window manager will hand back its
    ///     own size through `on_size` before the first frame.
    ///   - height: requested height in logical points.
    ///   - title: shown in the titlebar and the task switcher.
    ///
    /// There is no origin parameter: neither Wayland nor (in practice, given
    /// a window manager) X11 clients get to position their own windows.
    /// Placement belongs to the compositor/WM, by design.
    public init(width: Int, height: Int, title: String = "Nucleant") throws {
        switch LinuxSession.detect() {
        case .wayland:
            let surface = try WaylandSurface(width: Double(width), height: Double(height), title: title)
            backend = .wayland(surface)
        case .x11:
            let window = try X11Window(width: Double(width), height: Double(height), title: title)
            backend = .x11(window)
        }
        switch backend {
        case .wayland(let surface): surface.handler = self
        case .x11(let window): window.handler = self
        }
        // Start ticking immediately, matching macOS/iOS where the display
        // link runs from init. It no-ops until `win_delegate` is set.
        startFrameLoop()
    }

    deinit {
        switch backend {
        case .wayland(let surface):
            surface.handler = nil
            surface.destroy()
        case .x11(let window):
            window.handler = nil
            window.destroy()
        }
    }

    // MARK: - Window

    public func setTitle(_ title: String) {
        switch backend {
        case .wayland(let surface): surface.setTitle(title)
        case .x11(let window): window.setTitle(title)
        }
    }

    public func minimize() {
        switch backend {
        case .wayland(let surface): surface.minimize()
        case .x11(let window): window.minimize()
        }
    }

    /// Asks the windowing system to maximize or restore. The new size arrives
    /// through `on_size` once it's been decided — nothing changes
    /// synchronously here.
    public func setMaximized(_ maximized: Bool) {
        switch backend {
        case .wayland(let surface): surface.setMaximized(maximized)
        case .x11(let window): window.setMaximized(maximized)
        }
    }

    /// Asks the windowing system to go fullscreen or leave it. Same
    /// asynchronous contract as `setMaximized`.
    public func setFullscreen(_ fullscreen: Bool) {
        switch backend {
        case .wayland(let surface): surface.setFullscreen(fullscreen)
        case .x11(let window): window.setFullscreen(fullscreen)
        }
    }

    /// Flushes the connection so the window is up before whatever the caller
    /// does next. The counterpart of `makeKeyAndOrderFront` /
    /// `makeKeyAndVisible` — but only nominally on Wayland: a Wayland window
    /// becomes visible when its first buffer is attached, i.e. on the first
    /// present, not on demand. X11's `xcb_map_window` here is the real thing.
    public func show() {
        switch backend {
        case .wayland(let surface):
            surface.startFrameLoop()
            WaylandDisplay.shared.flush()
        case .x11(let window):
            window.startFrameLoop()
            window.show()
        }
    }

    public func close() {
        switch backend {
        case .wayland(let surface): surface.destroy()
        case .x11(let window): window.destroy()
        }
        on_close?()
    }

    // MARK: - Geometry

    /// Logical size, in points — the space `on_size` and every input
    /// coordinate are expressed in.
    public var width: Double {
        switch backend {
        case .wayland(let surface): surface.width
        case .x11(let window): window.width
        }
    }
    public var height: Double {
        switch backend {
        case .wayland(let surface): surface.height
        case .x11(let window): window.height
        }
    }

    /// Device pixels per logical point. The Wayland/X11 analogue of
    /// `CAMetalLayer.contentsScale`.
    public var scale: Double {
        switch backend {
        case .wayland(let surface): surface.scale
        case .x11(let window): window.scale
        }
    }

    /// Render-target size in device pixels — what the swapchain is sized to.
    public var bufferWidth: UInt32 {
        switch backend {
        case .wayland(let surface): surface.bufferWidth
        case .x11(let window): window.bufferWidth
        }
    }
    public var bufferHeight: UInt32 {
        switch backend {
        case .wayland(let surface): surface.bufferHeight
        case .x11(let window): window.bufferHeight
        }
    }

    // MARK: - Vulkan handles

    public var vulkanSurfaceKind: VulkanSurfaceKind {
        switch backend {
        case .wayland(let surface):
            return .wayland(display: WaylandDisplay.shared.displayHandle, surface: surface.handle)
        case .x11(let window):
            return .xcb(connection: X11Display.shared.connectionHandle, window: window.handle)
        }
    }

    // MARK: - Frame loop

    /// Starts the compositor/WM frame-callback chain — the Linux stand-in for
    /// `startDisplayLink()`. Idempotent; init already calls it.
    public func startFrameLoop() {
        switch backend {
        case .wayland(let surface): surface.startFrameLoop()
        case .x11(let window): window.startFrameLoop()
        }
    }

    /// Stops driving frames. The counterpart of `stopDisplayLink()`.
    public func stopFrameLoop() {
        switch backend {
        case .wayland(let surface): surface.stopFrameLoop()
        case .x11(let window): window.stopFrameLoop()
        }
    }

    // MARK: - WaylandSurfaceHandler (shared event-forwarding surface for both backends)

    func waylandSurfaceDidTick(dt: Double) {
        win_delegate?.onFrame(dt)
    }

    func waylandSurfaceDidResize(width: Double, height: Double) {
        // Reported in logical points, matching macOS's `windowDidResize`
        // (content bounds, not the window frame) — the render surface follows
        // separately off `bufferWidth`/`bufferHeight`, and this is what
        // drives the widget-tree relayout.
        win_delegate?.on_size(w: width, h: height)
    }

    func waylandSurfaceDidRequestClose() {
        if let on_close {
            on_close()
        } else {
            // Only stop the event loop once *this* was the last live window —
            // otherwise closing one of several open windows would end the
            // whole app instead of just that window, which is the
            // `applicationShouldTerminateAfterLastWindowClosed` behaviour this
            // is meant to match.
            switch backend {
            case .wayland(let surface):
                surface.destroy()
                if WaylandDisplay.shared.hasNoLiveSurfaces {
                    WaylandDisplay.shared.stop()
                }
            case .x11(let window):
                window.destroy()
                if X11Display.shared.hasNoLiveWindows {
                    X11Display.shared.stop()
                }
            }
        }
    }

    func waylandPointerDown(at location: SIMD2<Double>) {
        win_delegate?.mouseDown(location: location)
    }

    func waylandPointerUp(at location: SIMD2<Double>) {
        win_delegate?.mouseUp(location: location)
    }

    func waylandPointerDragged(at location: SIMD2<Double>) {
        win_delegate?.mouseDragged(location: location)
    }

    func waylandPointerMoved(to location: SIMD2<Double>) {
        win_delegate?.mouseMoved(location: location)
    }

    func waylandRightPointerDown(at location: SIMD2<Double>) {
        win_delegate?.rightMouseDown(location: location)
    }

    func waylandRightPointerUp(at location: SIMD2<Double>) {
        win_delegate?.rightMouseUp(location: location)
    }

    func waylandScrolled(dx: Double, dy: Double) {
        win_delegate?.scrollWheel(deltaX: dx, deltaY: dy)
    }

    func waylandKeyDown(key: UInt16, chars: String?) {
        win_delegate?.keyDown(key: key, chars: chars)
    }

    func waylandKeyUp(key: UInt16, chars: String?) {
        win_delegate?.keyUp(key: key, chars: chars)
    }

    func waylandTouchDown(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchDown(id: id, location: location)
    }

    func waylandTouchMoved(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchMoved(id: id, location: location)
    }

    func waylandTouchUp(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchUp(id: id, location: location)
    }

    func waylandTouchCancelled(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchCancelled(id: id, location: location)
    }
}
#endif
