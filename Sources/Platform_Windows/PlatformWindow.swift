//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(Windows)
import NucleantWindow
import WinSDK

/// The Windows counterpart to macOS's `NSWindow`-derived `PlatformWindow`
/// and Linux's Wayland/X11 one: a top-level Win32 window that ticks frames
/// off the message loop and forwards mouse, keyboard and touch input to its
/// `win_delegate`.
///
/// Kept generic (not existential) for the same reason as the others —
/// `NucleantWindow` has an associated `Node`, so a concrete `WindowBase` type
/// is needed to call its members. The window procedure, which can't live in
/// a generic context, sits one layer down in `Win32Window`.
///
/// ## Vulkan
///
/// `VulkanRenderEngine(win32Instance:win32Window:getExtent:)` takes
/// `win32Instance` and `win32Window`. Size the swapchain from
/// `bufferWidth`/`bufferHeight`, which are in device pixels rather than the
/// points the delegate callbacks use.
public final class PlatformWindow<WindowBase>: Win32WindowHandler
    where WindowBase: NucleantWindow & Win32WindowDelegate {

    /// Called when the window is asked to close (the title bar's ✕, Alt+F4,
    /// File › Close). Set it to take over what closing means; leave it nil
    /// and the window destroys itself and, once it was the last, stops the
    /// event loop — the `applicationShouldTerminateAfterLastWindowClosed`
    /// behaviour macOS has.
    public var on_close: (() -> Void)?

    /// Called when the window loses the keys to another window — another
    /// app's, or the taskbar's. A tray item's window goes away then.
    public var on_deactivate: (() -> Void)?

    /// What kind of window it is.
    public enum Role {
        /// A window of the app's: framed, with the app's menu bar, placed by
        /// Windows and shown by `show()`.
        case window
        /// A tray item's window: no frame, over every other window, not on
        /// the taskbar, and hidden until the app shows it at its item
        /// (`show(near:)`).
        case trayPanel
    }

    public let role: Role

    /// Strongly held by the owner; referenced weakly here so the window
    /// doesn't retain its delegate. Same contract as the other platforms.
    public weak var win_delegate: WindowBase?

    private let window: Win32Window

    // MARK: - Init

    /// - Parameters:
    ///   - width: the content's width in points. Windows places the window
    ///     and puts its title bar, frame and menu bar around this.
    ///   - height: the content's height in points.
    ///   - title: shown in the title bar and on the taskbar.
    ///   - role: a window of the app's, or a tray item's.
    public init(width: Int, height: Int, title: String = "Nucleant", role: Role = .window) throws {
        self.role = role
        window = try Win32Window(
            width: Double(width), height: Double(height), title: title, isTrayPanel: role == .trayPanel
        )
        window.handler = self
        // Start ticking immediately, matching the other platforms. It no-ops
        // until `win_delegate` is set. A tray item's window draws nothing
        // until it is shown.
        if role == .window {
            startFrameLoop()
        }
    }

    deinit {
        window.handler = nil
        window.destroy()
    }

    // MARK: - Window

    public func setTitle(_ title: String) {
        window.setTitle(title)
    }

    public func minimize() {
        window.minimize()
    }

    /// Maximizes or restores. The new size arrives through `on_size`.
    public func setMaximized(_ maximized: Bool) {
        window.setMaximized(maximized)
    }

    /// Covers the window's monitor, or goes back to the window it was. The
    /// new size arrives through `on_size`.
    public func setFullscreen(_ fullscreen: Bool) {
        window.setFullscreen(fullscreen)
    }

    /// Shows the window and activates it — the counterpart of
    /// `makeKeyAndOrderFront`.
    public func show() {
        window.startFrameLoop()
        window.show()
    }

    public func close() {
        window.destroy()
        on_close?()
    }

    /// Whether it is on screen: shown, and not hidden since.
    public var isVisible: Bool { window.isVisible }

    /// Takes the window off the screen, keeping it for `show()` to bring
    /// back. It draws no frames meanwhile.
    public func hide() {
        stopFrameLoop()
        window.hide()
    }

    /// Shows a tray item's window dropping from the item at `anchor`, in
    /// screen pixels: on the side of it that faces the rest of the screen,
    /// inside its monitor's work area (`TrayAnchor.dropDownOrigin`), with
    /// the keys.
    public func show(near anchor: TrayAnchor) {
        window.startFrameLoop()
        window.show(near: anchor)
    }

    /// Resizes the content to `width` × `height` points, as a tray item's
    /// window follows its content. The new size reaches `on_size`.
    public func setContentSize(width: Double, height: Double) {
        window.setContentSize(width: width, height: height)
    }

    /// Brings the window in front of the others and gives it the keys.
    public func activate() {
        window.activate()
    }

    // MARK: - Geometry

    /// Logical size, in points — the space `on_size` and every input
    /// coordinate are expressed in.
    public var width: Double { window.width }
    public var height: Double { window.height }

    /// Device pixels per point: the window's DPI over 96. The Windows
    /// analogue of `CAMetalLayer.contentsScale`, and like it, it changes when
    /// the window moves to a monitor with another scale.
    public var scale: Double { window.scale }

    /// Render-target size in device pixels — what the swapchain is sized to.
    public var bufferWidth: UInt32 { window.bufferWidth }
    public var bufferHeight: UInt32 { window.bufferHeight }

    // MARK: - Vulkan handles

    /// The module the window class belongs to, for VK_KHR_win32_surface.
    public var win32Instance: HINSTANCE { Win32EventLoop.shared.instance }

    /// The window, for VK_KHR_win32_surface.
    public var win32Window: HWND { window.handle }

    // MARK: - Frame loop

    /// Starts ticking `onFrame` off the event loop — the Windows stand-in for
    /// `startDisplayLink()`. Idempotent; init already calls it.
    public func startFrameLoop() {
        window.startFrameLoop()
    }

    /// Stops driving frames. The counterpart of `stopDisplayLink()`.
    public func stopFrameLoop() {
        window.stopFrameLoop()
    }

    // MARK: - Win32WindowHandler

    func win32WindowDidTick(dt: Double) {
        win_delegate?.onFrame(dt)
    }

    func win32WindowDidResize(width: Double, height: Double) {
        // Points, matching macOS's `windowDidResize` (content bounds, not the
        // window frame) — the render surface follows separately off
        // `bufferWidth`/`bufferHeight`.
        win_delegate?.on_size(w: width, h: height)
    }

    func win32WindowDidRequestClose() {
        if let on_close {
            on_close()
        } else {
            // Only stop the event loop once this was the last live window —
            // closing one of several shouldn't end the app.
            window.destroy()
            if Win32EventLoop.shared.hasNoLiveWindows {
                Win32EventLoop.shared.stop()
            }
        }
    }

    func win32WindowDidDeactivate() {
        on_deactivate?()
    }

    func win32PointerDown(at location: SIMD2<Double>) {
        win_delegate?.mouseDown(location: location)
    }

    func win32PointerUp(at location: SIMD2<Double>) {
        win_delegate?.mouseUp(location: location)
    }

    func win32PointerDragged(at location: SIMD2<Double>) {
        win_delegate?.mouseDragged(location: location)
    }

    func win32PointerMoved(to location: SIMD2<Double>) {
        win_delegate?.mouseMoved(location: location)
    }

    func win32RightPointerDown(at location: SIMD2<Double>) {
        win_delegate?.rightMouseDown(location: location)
    }

    func win32RightPointerUp(at location: SIMD2<Double>) {
        win_delegate?.rightMouseUp(location: location)
    }

    func win32Scrolled(dx: Double, dy: Double) {
        win_delegate?.scrollWheel(deltaX: dx, deltaY: dy)
    }

    func win32KeyDown(key: UInt16, chars: String?) {
        win_delegate?.keyDown(key: key, chars: chars)
    }

    func win32KeyUp(key: UInt16, chars: String?) {
        win_delegate?.keyUp(key: key, chars: chars)
    }

    func win32TouchDown(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchDown(id: id, location: location)
    }

    func win32TouchMoved(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchMoved(id: id, location: location)
    }

    func win32TouchUp(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchUp(id: id, location: location)
    }

    func win32TouchCancelled(id: Int, at location: SIMD2<Double>) {
        win_delegate?.touchCancelled(id: id, location: location)
    }
}
#endif
