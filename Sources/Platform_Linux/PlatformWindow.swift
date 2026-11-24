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

    /// What kind of window it is.
    public enum Role {
        /// A window of the app's: decorated, placed by the window manager,
        /// shown by `show()`.
        case window
        /// A tray item's window: no title bar, above the other windows, out
        /// of the taskbar, and hidden until the app shows it at its item
        /// (`show(near:)`). On X11 it is placed there; on Wayland, where a
        /// client places nothing, the compositor puts it where it likes.
        case trayPanel
    }

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

    /// Called when the window loses the keys to another window — another
    /// app's, or the desktop's. A tray item's window goes away then.
    public var on_deactivate: (() -> Void)?

    public let role: Role

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
    ///   - role: a window of the app's, or a tray item's.
    public init(width: Int, height: Int, title: String = "Nucleant", role: Role = .window) throws {
        self.role = role
        let isTrayPanel = role == .trayPanel
        switch LinuxSession.detect() {
        case .wayland:
            let surface = try WaylandSurface(
                width: Double(width), height: Double(height), title: title, isTrayPanel: isTrayPanel
            )
            backend = .wayland(surface)
        case .x11:
            let window = try X11Window(
                width: Double(width), height: Double(height), title: title, isTrayPanel: isTrayPanel
            )
            backend = .x11(window)
        }
        switch backend {
        case .wayland(let surface): surface.handler = self
        case .x11(let window): window.handler = self
        }
        switch role {
        case .window:
            // Start ticking immediately, matching macOS/iOS where the display
            // link runs from init. It no-ops until `win_delegate` is set.
            startFrameLoop()
        case .trayPanel:
            // Hidden until it is shown at its item, and drawing nothing until
            // then. On Wayland the configured surface is mapped by its first
            // buffer, so it is unmapped here.
            if case .wayland(let surface) = backend { surface.hide() }
        }
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

    /// Whether it is on screen: shown, and not hidden since.
    public var isVisible: Bool {
        switch backend {
        case .wayland(let surface): surface.isMapped
        case .x11(let window): window.isMapped
        }
    }

    /// Takes the window off the screen, keeping it — its surface, and what
    /// renders into it — for `show()` to bring back. It draws no frames
    /// meanwhile.
    public func hide() {
        stopFrameLoop()
        switch backend {
        case .wayland(let surface): surface.hide()
        case .x11(let window): window.hide()
        }
    }

    /// Shows a tray item's window dropping from the item at `anchor`, and
    /// gives it the keys. On X11 it goes on the side of the item that faces
    /// the rest of the screen, inside the work area
    /// (`TrayAnchor.dropDownOrigin`); on Wayland the compositor places it.
    public func show(near anchor: TrayAnchor) {
        switch backend {
        case .wayland(let surface):
            surface.show()
            WaylandDisplay.shared.flush()
        case .x11(let window):
            let area = X11Display.shared.workArea
            let origin = anchor.dropDownOrigin(
                width: window.width * window.scale, height: window.height * window.scale,
                in: TrayAnchor(x: area.x, y: area.y, width: area.width, height: area.height)
            )
            // Placed before it is mapped, where the window manager takes the
            // place from its hints; moved by the window manager when it is
            // on screen already, as it grows with its content.
            window.move(x: origin.x, y: origin.y)
            window.startFrameLoop()
            window.show()
            window.activate()
        }
    }

    /// Resizes the window to `width` × `height` points, as a tray item's
    /// window follows its content. The new size reaches `on_size`.
    public func setContentSize(width: Double, height: Double) {
        switch backend {
        case .wayland(let surface): surface.resize(width: width, height: height)
        case .x11(let window): window.resize(width: width * window.scale, height: height * window.scale)
        }
    }

    /// Brings the window in front of the others and gives it the keys, as
    /// far as the window manager lets an app: on Wayland the compositor
    /// decides, and this does nothing.
    public func activate() {
        switch backend {
        case .wayland: break
        case .x11(let window): window.activate()
        }
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

    func waylandSurfaceDidDeactivate() {
        on_deactivate?()
    }

    // MARK: - Phase

    /// Whether `win_delegate` was last told the window is in the
    /// background; a window starts out active.
    private var isInBackground = false

    /// In the background while it is out of sight, active while it is on
    /// screen — behind other windows, or without the keys, included, as on
    /// macOS. Linux has no inactive window: what macOS makes inactive, a
    /// window minimized into the Dock and still drawn there, takes a Linux
    /// window off the screen.
    func waylandSurfaceDidChangeVisibility(isOnScreen: Bool) {
        guard isOnScreen == isInBackground else { return }
        isInBackground = !isOnScreen
        if isOnScreen {
            win_delegate?.on_phase_active()
        } else {
            win_delegate?.on_phase_background()
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
