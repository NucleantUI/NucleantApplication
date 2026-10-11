//
//  main.swift
//  WasmProbe
//
//  A smoke test for Platform_Wasm with the renderer attached: puts one window
//  on the page, builds the render engine on its canvas — Vulkan, implemented
//  on the browser's WebGPU — and prints what the page sends back: the size,
//  the pixel density, and every pointer / keyboard / touch / scroll event.
//
//  The window shows a CPU-painted pixel buffer composited by the engine, so a
//  glance answers "is it rendering": an animated gradient, a crosshair that
//  follows the pointer, a dot per finger, the whole frame flashing on a key
//  press and inverting while the mouse button is down.
//
//      scripts/build_wasm_app.py WasmProbe --serve
//
#if os(WASI)
import CVulkan
import Foundation
import NucleantApplication
import NucleantVulkan
import NucleantWindow
import Observation
import Platform_Wasm

// MARK: - Render slot

/// The engine's composite slot for the probe's one node.
@Observable
final class ProbeSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case pixels(PixelBufferShaderNode<ProbeSlot>)
    }

    let id: Int
    let context: Context
    var needsRender = true

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {
        if case .pixels(let node) = context { observe(node) }
    }

    func update(engine: Engine, cmd: VkCommandBuffer) {
        if case .pixels(let node) = context { node.update(engine, slot: self, cmd: cmd) }
    }

    func destroyResources(engine: Engine) {
        if case .pixels(let node) = context { node.destroyResources(engine) }
    }

    func getImageView() -> VkImageView? {
        if case .pixels(let node) = context { return node.imageView }
        return nil
    }
}

// MARK: - Window

final class ProbeWindow: NucleantWindow, BrowserWindowDelegate {
    typealias Node = ProbeSlot

    var renderEngine: VulkanRenderEngine<ProbeSlot>?
    var win_rect: SIMD4<Int> = .init(0, 0, 720, 450)

    let platformWindow: PlatformWindow<ProbeWindow>

    /// Painted at a quarter of the window's size and nearest-scaled up 4×
    /// by the node, so the pixels stay visible.
    private static let canvasWidth = 180
    private static let canvasHeight = 112
    private var pixels: PixelBufferShaderNode<ProbeSlot>?
    private var frame = [UInt32](repeating: 0, count: canvasWidth * canvasHeight)

    private var time = 0.0
    private var frames = 0
    private var pointer: SIMD2<Double>?
    private var pressed = false
    private var touches: [Int: SIMD2<Double>] = [:]
    private var flash = 0.0

    init() throws {
        platformWindow = try PlatformWindow(width: 720, height: 450, title: "WasmProbe")
        platformWindow.win_delegate = self
        print("WasmProbe: window \(platformWindow.canvasSelector) \(platformWindow.width)×\(platformWindow.height) pt, scale \(platformWindow.scale), canvas \(platformWindow.bufferWidth)×\(platformWindow.bufferHeight) px")
    }

    func present() throws {
        let window = platformWindow
        let engine = try VulkanRenderEngine<ProbeSlot>(canvasSelector: window.canvasSelector) { [unowned window] in
            (Int(window.bufferWidth), Int(window.bufferHeight))
        }
        engine.clearColor = (0.05, 0.05, 0.08, 1)
        let node = try engine.makePixelBufferNode(width: Self.canvasWidth, height: Self.canvasHeight, scale: 4)
        engine.append(ProbeSlot(id: 1, context: .pixels(node)))
        renderEngine = engine
        pixels = node
        window.show()
        print("WasmProbe: render engine up on \(window.canvasSelector)")
    }

    // MARK: Frames

    func onFrame(_ dt: Double) {
        time += dt
        frames += 1
        flash = max(0, flash - dt * 3)
        if frames % 300 == 0 {
            print("WasmProbe: \(frames) frames, last Δt \((dt * 100_000).rounded() / 100) ms")
        }
        paint()
        renderEngine?.drawFrame(dt)
    }

    func on_size(w: Double, h: Double) {
        win_rect = .init(0, 0, Int(w * platformWindow.scale), Int(h * platformWindow.scale))
        print("WasmProbe: on_size \(w)×\(h) pt (canvas \(platformWindow.bufferWidth)×\(platformWindow.bufferHeight) px)")
    }

    private func paint() {
        let w = Self.canvasWidth, h = Self.canvasHeight
        for y in 0..<h {
            for x in 0..<w {
                let u = Double(x) / Double(w), v = Double(y) / Double(h)
                var r = 0.5 + 0.5 * sin(time + u * 6.0)
                var g = 0.5 + 0.5 * sin(time * 1.3 + v * 5.0 + 2.0)
                var b = 0.5 + 0.5 * sin(time * 0.7 + (u + v) * 4.0 + 4.0)
                r += (1 - r) * flash
                g += (1 - g) * flash
                b += (1 - b) * flash
                if pressed {
                    r = 1 - r
                    g = 1 - g
                    b = 1 - b
                }
                frame[y * w + x] = rgba(r, g, b)
            }
        }
        if let pointer {
            let p = toCanvas(pointer)
            for i in 0..<w { set(i, p.y, 0xFFFF_FFFF) }
            for j in 0..<h { set(p.x, j, 0xFFFF_FFFF) }
        }
        for location in touches.values {
            let p = toCanvas(location)
            for dy in -3...3 {
                for dx in -3...3 where dx * dx + dy * dy <= 9 { set(p.x + dx, p.y + dy, 0xFF00_00FF) }
            }
        }
        pixels?.write(rgba: frame)
    }

    private func toCanvas(_ point: SIMD2<Double>) -> (x: Int, y: Int) {
        let width = max(platformWindow.width, 1), height = max(platformWindow.height, 1)
        return (Int(point.x / width * Double(Self.canvasWidth)), Int(point.y / height * Double(Self.canvasHeight)))
    }

    private func set(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, y >= 0, x < Self.canvasWidth, y < Self.canvasHeight else { return }
        frame[y * Self.canvasWidth + x] = color
    }

    private func rgba(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, v * 255))) }
        return 0xFF00_0000 | (byte(b) << 16) | (byte(g) << 8) | byte(r)
    }

    // MARK: Input

    func on_mouse_down(x: Double, y: Double) {
        pressed = true
        pointer = SIMD2(x, y)
        print("WasmProbe: mouse down (\(x), \(y))")
    }

    func on_mouse_up(x: Double, y: Double) {
        pressed = false
        print("WasmProbe: mouse up (\(x), \(y))")
    }

    func on_mouse_dragged(x: Double, y: Double) {
        pointer = SIMD2(x, y)
    }

    func on_mouse_moved(x: Double, y: Double) {
        pointer = SIMD2(x, y)
    }

    func on_right_mouse_down(x: Double, y: Double) {
        print("WasmProbe: right mouse down (\(x), \(y))")
    }

    func on_right_mouse_up(x: Double, y: Double) {
        print("WasmProbe: right mouse up (\(x), \(y))")
    }

    func on_scroll(dx: Double, dy: Double) {
        print("WasmProbe: scroll (\(dx), \(dy))")
    }

    func on_key_down(keyCode: UInt16, characters: String?) {
        flash = 1
        print("WasmProbe: key down 0x\(String(keyCode, radix: 16)) \(characters?.debugDescription ?? "nil")")
    }

    func on_key_up(keyCode: UInt16, characters: String?) {
        print("WasmProbe: key up 0x\(String(keyCode, radix: 16))")
    }

    func on_touch_down(id: Int, x: Double, y: Double) {
        touches[id] = SIMD2(x, y)
        print("WasmProbe: touch \(id) down (\(x), \(y))")
    }

    func on_touch_moved(id: Int, x: Double, y: Double) {
        touches[id] = SIMD2(x, y)
    }

    func on_touch_up(id: Int, x: Double, y: Double) {
        touches[id] = nil
        print("WasmProbe: touch \(id) up")
    }

    func on_touch_cancelled(id: Int, x: Double, y: Double) {
        touches[id] = nil
    }
}

// MARK: - App

@MainActor
final class ProbeApp: NucleantApplication {
    var appDelegate: AppDelegate<ProbeApp>?
    private var window: ProbeWindow?

    func onStart() {
        do {
            let window = try ProbeWindow()
            try window.present()
            self.window = window
        } catch {
            print("WasmProbe: could not open the window: \(error)")
        }
    }
}

@main
struct WasmProbe {
    @MainActor
    static func main() throws {
        let app = ProbeApp()
        app.setup()
        try app.run()
    }
}
#endif
