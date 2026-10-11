//
//  BrowserWindow.swift
//  NucleantApplication
//
//  One window's worth of browser page: the <canvas> element standing in for
//  the window, its size, and the events the page delivers for it.
//
#if os(WASI)
import CWasmDOM

/// What a `BrowserWindow` reports upwards.
///
/// Not generic, for the same reason as Linux's `WaylandSurfaceHandler`: the
/// browser calls into wasm through plain exported functions (BrowserEvents),
/// which find the window by id and cannot carry a generic parameter. So the
/// events come back out of this non-generic class through this protocol,
/// which `PlatformWindow<WindowBase>` implements. Coordinates and sizes are
/// CSS pixels, matching `BrowserWindowDelegate`.
protocol BrowserWindowHandler: AnyObject {
    func browserWindowDidTick(dt: Double)
    func browserWindowDidResize(width: Double, height: Double)

    func browserPointerDown(at location: SIMD2<Double>)
    func browserPointerUp(at location: SIMD2<Double>)
    func browserPointerDragged(at location: SIMD2<Double>)
    func browserPointerMoved(to location: SIMD2<Double>)
    func browserRightPointerDown(at location: SIMD2<Double>)
    func browserRightPointerUp(at location: SIMD2<Double>)
    func browserScrolled(dx: Double, dy: Double)

    func browserKeyDown(key: UInt16, chars: String?)
    func browserKeyUp(key: UInt16, chars: String?)

    func browserTouchDown(id: Int, at location: SIMD2<Double>)
    func browserTouchMoved(id: Int, at location: SIMD2<Double>)
    func browserTouchUp(id: Int, at location: SIMD2<Double>)
    func browserTouchCancelled(id: Int, at location: SIMD2<Double>)
}

/// A window on the page: a focusable `<canvas>` the render engine presents
/// into. Created through `PlatformWindow`; nothing outside this module needs
/// to name it.
final class BrowserWindow {

    /// The id the page knows the canvas by.
    let id: UInt32

    weak var handler: (any BrowserWindowHandler)?

    /// Whether `browserWindowDidTick` is delivered — the counterpart of a
    /// running display link.
    var ticking = false

    /// The previous frame's requestAnimationFrame timestamp, in seconds.
    private var lastFrame: Double?

    /// The size the handler was last told about, so a resize that changes
    /// only the pixel density doesn't relayout.
    private var reportedSize = SIMD2<Double>(0, 0)

    private(set) var destroyed = false

    /// Every live window by id — how an exported event function finds its
    /// window. Weak: the window belongs to its `PlatformWindow`.
    private nonisolated(unsafe) static var live: [UInt32: Weak] = [:]

    private struct Weak {
        weak var window: BrowserWindow?
    }

    static func window(_ id: UInt32) -> BrowserWindow? {
        live[id]?.window
    }

    static var all: [BrowserWindow] {
        live.values.compactMap(\.window)
    }

    static var hasNoLiveWindows: Bool {
        all.isEmpty
    }

    init(width: Double, height: Double, title: String) {
        var title = title
        id = title.withUTF8 { nwd_window_create($0.baseAddress, UInt32($0.count), width, height) }
        Self.live[id] = Weak(window: self)
        reportedSize = SIMD2(self.width, self.height)
    }

    deinit {
        destroy()
    }

    // MARK: - Geometry

    private var metrics: [Double] {
        var values = [Double](repeating: 0, count: 5)
        values.withUnsafeMutableBufferPointer { nwd_window_get_metrics(id, $0.baseAddress) }
        return values
    }

    var width: Double { metrics[0] }
    var height: Double { metrics[1] }
    var scale: Double { metrics[2] }
    var bufferWidth: UInt32 { UInt32(metrics[3]) }
    var bufferHeight: UInt32 { UInt32(metrics[4]) }

    /// The CSS selector of this window's canvas — what
    /// `VulkanRenderEngine(canvasSelector:getSize:)` presents into.
    var canvasSelector: String { "#nucleant-window-\(id)" }

    // MARK: - Window

    func setTitle(_ title: String) {
        var title = title
        title.withUTF8 { nwd_window_set_title(id, $0.baseAddress, UInt32($0.count)) }
    }

    func setFullscreen(_ fullscreen: Bool) {
        nwd_window_set_fullscreen(id, fullscreen ? 1 : 0)
    }

    func focus() {
        nwd_window_focus(id)
    }

    func setLayout(fillsContainer: Bool, minSize: SIMD2<Double>, maxSize: SIMD2<Double>) {
        nwd_window_set_layout(id, fillsContainer ? 1 : 0, minSize.x, minSize.y, maxSize.x, maxSize.y)
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        ticking = false
        Self.live[id] = nil
        nwd_window_destroy(id)
    }

    // MARK: - From the page

    /// One display refresh. Δt from the browser's own frame timestamps, so a
    /// refresh the app missed is counted in the next frame; the first frame
    /// gets one 60 Hz refresh.
    func frame(at timestamp: Double) {
        let dt = lastFrame.map { timestamp - $0 } ?? 1.0 / 60.0
        lastFrame = timestamp
        guard ticking else { return }
        handler?.browserWindowDidTick(dt: dt)
    }

    func resized() {
        let size = SIMD2(width, height)
        guard size != reportedSize else { return }
        reportedSize = size
        handler?.browserWindowDidResize(width: size.x, height: size.y)
    }
}
#endif
