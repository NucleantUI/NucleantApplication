//
//  main.swift
//  WaylandProbe
//
//  A smoke test for Platform_Linux with no renderer attached: opens a real
//  toplevel and prints what the compositor sends back — the negotiated size,
//  the buffer scale, the frame ticks, and every pointer / keyboard / touch
//  event that lands on it.
//
//  Nothing draws. A Wayland window is only mapped once a buffer is attached,
//  which is a renderer's job, so on most compositors this stays invisible and
//  the frame ticks come from the fallback timer rather than from real
//  compositor callbacks — that's the expected result, and it's what makes the
//  input and resize paths testable without Vulkan in the picture.
//
//      swift run WaylandProbe
//
#if os(Linux)
import Foundation
import NucleantVulkan
import NucleantWindow
import Observation
import Platform_Linux

// MARK: - The smallest thing that satisfies NucleantWindow

@Observable
final class ProbeContext: RenderNodeContext {}

@Observable
final class ProbeNode: RenderContainerNode, @unchecked Sendable {
    let id: Int
    let context: ProbeContext
    var needsRender: Bool = false

    init(id: Int, context: ProbeContext) {
        self.id = id
        self.context = context
    }

    func observeContext() {}
    // VkCommandBuffer / VkImageView are opaque-handle typedefs, so they import
    // as OpaquePointer — which is what lets this conform without CVulkan,
    // a module NucleantVulkan doesn't re-export on Linux.
    func update(engine: Engine, cmd: OpaquePointer) {}
    func destroyResources(engine: Engine) {}
    func getImageView() -> OpaquePointer? { nil }
}

final class ProbeWindow: NucleantWindow, WaylandWindowDelegate {
    typealias Node = ProbeNode

    var renderEngine: VulkanRenderEngine<ProbeNode>?
    var win_rect: SIMD4<Int> = .init(0, 0, 960, 640)

    /// Paints a buffer each frame. Without one the surface never maps, and an
    /// unmapped surface gets no compositor frame callbacks — so this is what
    /// makes the difference between measuring the fallback timer and
    /// measuring the real thing.
    var painter: ShmPainter?
    /// Pixel size to paint at, kept in step by `on_size`.
    var bufferSize = SIMD2<Int32>(0, 0)
    /// `on_size` reports logical points; the buffer is in device pixels, and
    /// the window is what knows the scale between them.
    weak var window: PlatformWindow<ProbeWindow>?

    private var frames = 0
    private var totalFrames = 0
    private var lastReport = Date().timeIntervalSince1970

    func present() throws {}

    func onFrame(_ dt: Double) {
        frames += 1
        totalFrames += 1
        painter?.paint(width: bufferSize.x, height: bufferSize.y, frame: totalFrames)

        // Drive one resize on its own, so the configure -> on_size -> buffer
        // path gets exercised even on a compositor where nobody can grab a
        // window edge (a headless weston, a CI box).
        if let window, totalFrames == 60 {
            print("requesting fullscreen…")
            window.setFullscreen(true)
        }
        if let window, totalFrames == 180 {
            print("leaving fullscreen…")
            window.setFullscreen(false)
        }

        let now = Date().timeIntervalSince1970
        let elapsed = now - lastReport
        if elapsed >= 1.0 {
            print("frame ticks: \(frames) in \(String(format: "%.1f", elapsed))s (last dt \(String(format: "%.4f", dt)))")
            frames = 0
            lastReport = now
        }
    }

    func on_size(w: Double, h: Double) {
        win_rect.z = Int(w)
        win_rect.w = Int(h)
        if let window {
            bufferSize = SIMD2(Int32(window.bufferWidth), Int32(window.bufferHeight))
        }
        print("on_size: \(w) x \(h) pt -> \(bufferSize.x) x \(bufferSize.y) px")
    }

    func on_mouse_down(x: Double, y: Double) { print("mouse down \(x), \(y)") }
    func on_mouse_up(x: Double, y: Double) { print("mouse up \(x), \(y)") }
    func on_mouse_dragged(x: Double, y: Double) { print("mouse dragged \(x), \(y)") }
    func on_mouse_moved(x: Double, y: Double) { print("mouse moved \(x), \(y)") }
    func on_right_mouse_down(x: Double, y: Double) { print("right down \(x), \(y)") }
    func on_right_mouse_up(x: Double, y: Double) { print("right up \(x), \(y)") }
    func on_scroll(dx: Double, dy: Double) { print("scroll \(dx), \(dy)") }
    func on_key_down(keyCode: UInt16, characters: String?) {
        print("key down \(keyCode) chars=\(characters?.debugDescription ?? "nil")")
    }
    func on_key_up(keyCode: UInt16, characters: String?) { print("key up \(keyCode)") }
    func on_touch_down(id: Int, x: Double, y: Double) { print("touch \(id) down \(x), \(y)") }
    func on_touch_moved(id: Int, x: Double, y: Double) { print("touch \(id) moved \(x), \(y)") }
    func on_touch_up(id: Int, x: Double, y: Double) { print("touch \(id) up \(x), \(y)") }
    func on_touch_cancelled(id: Int, x: Double, y: Double) { print("touch \(id) cancelled") }
}

// MARK: - Run

do {
    let display = WaylandDisplay.shared
    try display.connect()
    print("connected to the compositor")

    let window = try PlatformWindow<ProbeWindow>(width: 960, height: 640, title: "Nucleant Wayland Probe")
    let delegate = ProbeWindow()
    delegate.window = window
    delegate.bufferSize = SIMD2(Int32(window.bufferWidth), Int32(window.bufferHeight))
    if case .wayland(let displayHandle, let surfaceHandle) = window.vulkanSurfaceKind,
       let displayHandle, let surfaceHandle {
        delegate.painter = ShmPainter(display: displayHandle, surface: surfaceHandle)
    }
    window.win_delegate = delegate
    window.show()

    print("window: \(window.width) x \(window.height) pt, "
        + "\(window.bufferWidth) x \(window.bufferHeight) px, scale \(window.scale)")
    print("surface kind: \(window.vulkanSurfaceKind)")
    print("running — ^C to quit")

    display.run()
    print("event loop ended")
} catch let error as WaylandError {
    print("Wayland: \(error.description)")
    exit(1)
} catch {
    print("failed: \(error)")
    exit(1)
}
#endif
