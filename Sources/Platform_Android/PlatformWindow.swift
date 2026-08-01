//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(Android)
import Foundation
import NucleantWindow
import NucleantVulkan
import VulkanCore

/// The Android counterpart of the macOS/iOS/Linux `PlatformWindow`.
///
/// Android gives an app one surface, owned by the Activity, so unlike the other
/// platforms this creates no window of its own — it attaches to whatever
/// surface `AndroidSurfaceHost` currently holds and rebuilds when it changes.
/// The Activity is the window; this is the object that binds it to a
/// `NucleantWindow`.
///
/// Generic rather than existential for the same reason as every other
/// platform: `NucleantWindow` has an associated `Node`, so a concrete type is
/// needed to reach its members.
@MainActor
public final class PlatformWindow<WindowBase> where WindowBase: NucleantWindow {

    public var on_close: (() -> Void)?

    /// Strongly held by the owner (PyNucleantUI keeps this); referenced weakly
    /// so the window does not retain its delegate.
    public weak var win_delegate: WindowBase?

    /// Frame pacing. Android has no CADisplayLink and no compositor event loop
    /// we own, so the render loop is a thread of our own that ticks the
    /// delegate — started when a surface exists, stopped when it goes away.
    private var renderThread: Thread?
    private var running = false
    private let runLock = NSLock()

    /// Touch ids arrive already assigned by the Java side (MotionEvent pointer
    /// ids), so unlike iOS there is no mapping table to keep.

    public init() {
        AndroidSurfaceHost.onSurfaceChanged = { [weak self] window, w, h in
            self?.surfaceChanged(window, w, h)
        }
        AndroidSurfaceHost.onSurfaceDestroyed = { [weak self] in
            self?.surfaceDestroyed()
        }
        AndroidSurfaceHost.onTouch = { [weak self] phase, id, x, y in
            self?.dispatchTouch(phase, id, x, y)
        }
        AndroidSurfaceHost.onKey = { [weak self] down, code, unicode in
            self?.dispatchKey(down, code, unicode)
        }
        AndroidSurfaceHost.onActiveChanged = { [weak self] active in
            active ? self?.startRenderLoop() : self?.stopRenderLoop()
        }
    }

    /// Attach to the surface that already exists, if any. The Activity creates
    /// its surface before Python is started, so by the time a window calls
    /// `present()` there is normally one waiting.
    public func present() {
        let (window, w, h) = AndroidSurfaceHost.currentSurface()
        if window != nil {
            surfaceChanged(window, w, h)
        }
    }

    // MARK: - Surface lifecycle

    private func surfaceChanged(_ window: OpaquePointer?, _ w: Int, _ h: Int) {
        guard let window else { return }
        // Android is always fullscreen: the surface size is the window size,
        // so it overrides whatever the window was constructed with.
        win_delegate?.win_rect = SIMD4<Int>(0, 0, w, h)

        // A resize means a new swapchain. Tearing the engine down and building
        // a fresh one is the same thing the surfaceDestroyed path does, and
        // avoids having to thread a resize through every render node.
        win_delegate?.renderEngine = nil
        do {
            win_delegate?.renderEngine = try VulkanRenderEngine(
                androidWindow: window,
                getSize: {
                    let (_, cw, ch) = AndroidSurfaceHost.currentSurface()
                    return (cw, ch)
                }
            )
        } catch {
            NSLog("[nucleant] failed to create Vulkan engine: \(error)")
            return
        }
        win_delegate?.on_size(w: Double(w), h: Double(h))
        startRenderLoop()
    }

    /// Must not return until the renderer has let go of the window — the
    /// Surface is only valid until the Java-side callback returns, and the
    /// bootstrap blocks on this.
    private func surfaceDestroyed() {
        stopRenderLoop()
        win_delegate?.renderEngine = nil
    }

    // MARK: - Frame loop

    private func startRenderLoop() {
        runLock.lock()
        defer { runLock.unlock() }
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in
            // The loop only reads its own state and calls the delegate, both of
            // which are main-actor isolated, so each tick hops back rather than
            // touching them from this thread.
            while MainActor.assumeIsolated({ self?.isRunning ?? false }) {
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        thread.name = "nucleant-render"
        renderThread = thread
        thread.start()
    }

    private func stopRenderLoop() {
        runLock.lock()
        running = false
        runLock.unlock()
        // Join: the surface must not be released while a frame is in flight.
        while renderThread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.001)
        }
        renderThread = nil
    }

    private var isRunning: Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return running
    }

    private var lastFrame = Date().timeIntervalSince1970

    private func tick() {
        let now = Date().timeIntervalSince1970
        let dt = now - lastFrame
        lastFrame = now
        win_delegate?.onFrame(dt)
    }

    // MARK: - Input

    private func dispatchTouch(_ phase: AndroidSurfaceHost.TouchPhase, _ id: Int, _ x: Double, _ y: Double) {
        switch phase {
        case .down:      win_delegate?.on_touch_down(id: id, x: x, y: y)
        case .moved:     win_delegate?.on_touch_moved(id: id, x: x, y: y)
        case .up:        win_delegate?.on_touch_up(id: id, x: x, y: y)
        case .cancelled: win_delegate?.on_touch_cancelled(id: id, x: x, y: y)
        }
    }

    private func dispatchKey(_ down: Bool, _ keyCode: Int, _ unicodeChar: Int) {
        // unicodeChar is 0 for keys with no printable form (arrows, BACK …),
        // which maps onto the same `characters: nil` the other platforms pass.
        let characters: String? = unicodeChar != 0
            ? String(UnicodeScalar(UInt32(unicodeChar)) ?? " ")
            : nil
        if down {
            win_delegate?.on_key_down(keyCode: UInt16(truncatingIfNeeded: keyCode), characters: characters)
        } else {
            win_delegate?.on_key_up(keyCode: UInt16(truncatingIfNeeded: keyCode), characters: characters)
        }
    }
}
#endif
