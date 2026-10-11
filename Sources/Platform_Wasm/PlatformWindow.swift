//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(WASI)
import NucleantWindow

/// The browser counterpart to macOS's `NSWindow`-derived `PlatformWindow`,
/// iOS's `UIWindow` one and Linux's Wayland/X11 one: a window on the page —
/// a `<canvas>` — that paces frames off requestAnimationFrame and forwards
/// pointer, keyboard and touch input to its `win_delegate`.
///
/// Kept generic (not existential) for the same reason as the others —
/// `NucleantWindow` has an associated `Node`, so a concrete `WindowBase` type
/// is needed to call its members. What the page calls into lives one layer
/// down in `BrowserWindow`.
///
/// ## Vulkan
///
/// Build the render engine with
/// `VulkanRenderEngine(canvasSelector: window.canvasSelector, getSize: …)`,
/// sizing it from `bufferWidth` / `bufferHeight` — the canvas's drawing
/// buffer in device pixels, rather than the CSS pixels the delegate
/// callbacks use.
public final class PlatformWindow<WindowBase>: BrowserWindowHandler
    where WindowBase: NucleantWindow & BrowserWindowDelegate {

    /// Called by `close()`. A page can't close itself the way a desktop
    /// window can, so this is the app's own hook for what closing means.
    public var on_close: (() -> Void)?

    /// Strongly held by the owner; referenced weakly here so the window
    /// doesn't retain its delegate. Same contract as the other platforms.
    public weak var win_delegate: WindowBase?

    /// The page side of this window — internal so the module's tests can
    /// address it by id the way the page does.
    let window: BrowserWindow

    // MARK: - Init

    /// - Parameters:
    ///   - width: requested width in CSS pixels. The page's own styling may
    ///     size the canvas differently; the real size arrives through
    ///     `on_size`.
    ///   - height: requested height in CSS pixels.
    ///   - title: the page title while this window is the page's main one.
    ///
    /// No origin: where the canvas sits is up to the page's layout.
    public init(width: Int, height: Int, title: String = "Nucleant") throws {
        window = BrowserWindow(width: Double(width), height: Double(height), title: title)
        window.handler = self
        // Tick from creation, matching the display link the other platforms
        // start in init. It no-ops until `win_delegate` is set.
        startFrameLoop()
    }

    deinit {
        window.handler = nil
        window.destroy()
        BrowserFrameLoop.update()
    }

    // MARK: - Window

    public func setTitle(_ title: String) {
        window.setTitle(title)
    }

    /// Asks the browser to show the canvas fullscreen, or to leave it. Like
    /// every platform's, the new size arrives through `on_size` once it's
    /// been decided. Browsers grant fullscreen only during a user gesture.
    public func setFullscreen(_ fullscreen: Bool) {
        window.setFullscreen(fullscreen)
    }

    /// Gives the canvas keyboard focus — the counterpart of
    /// `makeKeyAndOrderFront`. It is on the page from init.
    public func show() {
        startFrameLoop()
        window.focus()
    }

    /// Removes the canvas from the page.
    public func close() {
        window.destroy()
        BrowserFrameLoop.update()
        on_close?()
    }

    // MARK: - Geometry

    /// Logical size, in CSS pixels — the space `on_size` and every input
    /// coordinate are expressed in.
    public var width: Double { window.width }
    public var height: Double { window.height }

    /// Device pixels per CSS pixel (`devicePixelRatio`) — the browser
    /// analogue of `CAMetalLayer.contentsScale`.
    public var scale: Double { window.scale }

    /// Render-target size in device pixels — what the swapchain is sized to.
    public var bufferWidth: UInt32 { window.bufferWidth }
    public var bufferHeight: UInt32 { window.bufferHeight }

    /// The CSS selector of the canvas, for `VulkanRenderEngine(canvasSelector:getSize:)`.
    public var canvasSelector: String { window.canvasSelector }

    /// The id the page knows the canvas by — the window a `BrowserFrame` is
    /// placed over.
    public var windowID: UInt32 { window.id }

    // MARK: - Frame loop

    /// Starts delivering `onFrame` — the browser stand-in for
    /// `startDisplayLink()`. Idempotent; init already calls it.
    public func startFrameLoop() {
        window.ticking = true
        BrowserFrameLoop.update()
    }

    /// Stops delivering `onFrame`. The counterpart of `stopDisplayLink()`.
    public func stopFrameLoop() {
        window.ticking = false
        BrowserFrameLoop.update()
    }

    // MARK: - BrowserWindowHandler

    func browserWindowDidTick(dt: Double) {
        win_delegate?.onFrame(dt)
    }

    func browserWindowDidResize(width: Double, height: Double) {
        // Logical (CSS) size, matching macOS's `windowDidResize` reporting the
        // content bounds; the render surface follows separately off
        // `bufferWidth`/`bufferHeight`, which the engine reads every frame.
        win_delegate?.on_size(w: width, h: height)
    }

    func browserPointerDown(at location: SIMD2<Double>) {
        win_delegate?.mouseDown(location: location)
    }

    func browserPointerUp(at location: SIMD2<Double>) {
        win_delegate?.mouseUp(location: location)
    }

    func browserPointerDragged(at location: SIMD2<Double>) {
        win_delegate?.mouseDragged(location: location)
    }

    func browserPointerMoved(to location: SIMD2<Double>) {
        win_delegate?.mouseMoved(location: location)
    }

    func browserRightPointerDown(at location: SIMD2<Double>) {
        win_delegate?.rightMouseDown(location: location)
    }

    func browserRightPointerUp(at location: SIMD2<Double>) {
        win_delegate?.rightMouseUp(location: location)
    }

    func browserScrolled(dx: Double, dy: Double) {
        win_delegate?.scrollWheel(deltaX: dx, deltaY: dy)
    }

    func browserKeyDown(key: UInt16, chars: String?) {
        win_delegate?.keyDown(key: key, chars: chars)
    }

    func browserKeyUp(key: UInt16, chars: String?) {
        win_delegate?.keyUp(key: key, chars: chars)
    }

    func browserTouchDown(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchDown(id: id, location: location)
    }

    func browserTouchMoved(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchMoved(id: id, location: location)
    }

    func browserTouchUp(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchUp(id: id, location: location)
    }

    func browserTouchCancelled(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchCancelled(id: id, location: location)
    }
}
#endif
