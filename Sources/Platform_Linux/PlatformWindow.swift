//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(Linux)
import NucleantWindow
import CWayland

/// The Linux counterpart to macOS's `NSWindow`-derived `PlatformWindow` and
/// iOS's `UIWindow` one: a Wayland toplevel that paces frames off the
/// compositor and forwards pointer, keyboard and touch input to its
/// `win_delegate`.
///
/// Kept generic (not existential) for the same reason as the other two —
/// `NucleantWindow` has an associated `Node`, so a concrete `WindowBase` type
/// is needed to call its members. The C-callback plumbing that can't live in
/// a generic context sits one layer down in `WaylandSurface`.
///
/// ## Vulkan
///
/// There is no `CAMetalLayer` here to hand a render engine. Wayland's
/// equivalent is the pair of raw handles `displayHandle` (`wl_display *`) and
/// `surfaceHandle` (`wl_surface *`), which is exactly what
/// `VkWaylandSurfaceCreateInfoKHR` takes; size the swapchain from
/// `bufferWidth`/`bufferHeight`, which are in device pixels rather than the
/// logical points the delegate callbacks use.
public final class PlatformWindow<WindowBase>: WaylandSurfaceHandler
    where WindowBase: NucleantWindow & WaylandWindowDelegate {

    /// Called when the compositor relays a close request (the titlebar's ✕).
    /// Set it to take over what closing means; leave it nil and the window
    /// tears itself down and stops the event loop, which is the
    /// `applicationShouldTerminateAfterLastWindowClosed` behaviour macOS has.
    public var on_close: (() -> Void)?

    /// Strongly held by the owner; referenced weakly here so the window
    /// doesn't retain its delegate. Same contract as macOS/iOS.
    public weak var win_delegate: WindowBase?

    private let surface: WaylandSurface

    // MARK: - Init

    /// - Parameters:
    ///   - width: requested width in logical points. The compositor gets the
    ///     final say — a tiling window manager will hand back its own size
    ///     through `on_size` before the first frame.
    ///   - height: requested height in logical points.
    ///   - title: shown in the titlebar and the task switcher.
    ///
    /// There is no origin parameter, unlike macOS's `contentRect`: Wayland
    /// clients cannot position their own windows. Placement is the
    /// compositor's, by design.
    public init(width: Int, height: Int, title: String = "Nucleant") throws {
        surface = try WaylandSurface(
            width: Double(width),
            height: Double(height),
            title: title
        )
        surface.handler = self
        // Start ticking immediately, matching macOS/iOS where the display
        // link runs from init. It no-ops until `win_delegate` is set.
        surface.startFrameLoop()
    }

    deinit {
        surface.handler = nil
        surface.destroy()
    }

    // MARK: - Window

    public func setTitle(_ title: String) {
        surface.setTitle(title)
    }

    public func minimize() {
        surface.minimize()
    }

    /// Asks the compositor to maximize or restore. The new size arrives
    /// through `on_size` once the compositor has decided on it — nothing
    /// changes synchronously here.
    public func setMaximized(_ maximized: Bool) {
        surface.setMaximized(maximized)
    }

    /// Asks the compositor to go fullscreen or leave it, on an output of its
    /// choosing. Same asynchronous contract as `setMaximized`.
    public func setFullscreen(_ fullscreen: Bool) {
        surface.setFullscreen(fullscreen)
    }

    /// Flushes the connection so the window is up before whatever the caller
    /// does next. The counterpart of `makeKeyAndOrderFront` /
    /// `makeKeyAndVisible` — but only nominally: a Wayland window becomes
    /// visible when its first buffer is attached, i.e. on the first present,
    /// not on demand.
    public func show() {
        surface.startFrameLoop()
        WaylandDisplay.shared.flush()
    }

    public func close() {
        surface.destroy()
        on_close?()
    }

    // MARK: - Geometry

    /// Logical size, in points — the space `on_size` and every input
    /// coordinate are expressed in.
    public var width: Double { surface.width }
    public var height: Double { surface.height }

    /// Device pixels per logical point. The Wayland analogue of
    /// `CAMetalLayer.contentsScale`.
    public var scale: Double { surface.scale }

    /// Render-target size in device pixels — what the swapchain is sized to.
    public var bufferWidth: UInt32 { surface.bufferWidth }
    public var bufferHeight: UInt32 { surface.bufferHeight }

    // MARK: - Vulkan handles

    /// `wl_display *` for `VkWaylandSurfaceCreateInfoKHR.display`.
    public var displayHandle: OpaquePointer? { WaylandDisplay.shared.displayHandle }

    /// `wl_surface *` for `VkWaylandSurfaceCreateInfoKHR.surface`.
    public var surfaceHandle: OpaquePointer? { surface.handle }

    // MARK: - Frame loop

    /// Starts the compositor frame-callback chain — the Wayland stand-in for
    /// `startDisplayLink()`. Idempotent; init already calls it.
    public func startFrameLoop() {
        surface.startFrameLoop()
    }

    /// Stops driving frames. The counterpart of `stopDisplayLink()`.
    public func stopFrameLoop() {
        surface.stopFrameLoop()
    }

    // MARK: - WaylandSurfaceHandler

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
            surface.destroy()
            WaylandDisplay.shared.stop()
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
