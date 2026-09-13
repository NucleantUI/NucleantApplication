//
//  PlatformWindow.swift
//  NucleantApplication
//
#if os(Android)
import CAndroidChoreographer
import Foundation
import NucleantWindow
import NucleantVulkan
import VulkanCore

/// What the Choreographer callbacks are handed, instead of the window itself.
///
/// A C function pointer cannot be formed from a closure that mentions a generic
/// parameter, and `PlatformWindow` is generic over its delegate — so the window
/// passes these two erased closures and the callbacks never name its type.
private final class FrameTarget {
    let tick: () -> Void
    let isRunning: () -> Bool

    init(tick: @escaping () -> Void, isRunning: @escaping () -> Bool) {
        self.tick = tick
        self.isRunning = isRunning
    }
}

/// Steady state: draw this frame, then ask for the next vsync.
private func postFrameCallback(_ context: UnsafeMutableRawPointer) {
    guard let choreographer = AChoreographer_getInstance() else { return }
    AChoreographer_postFrameCallback(choreographer, { _, data in
        guard let data else { return }
        let target = Unmanaged<FrameTarget>.fromOpaque(data).takeUnretainedValue()
        guard target.isRunning() else { return }
        target.tick()
        postFrameCallback(data)
    }, context)
}

/// The first frame only: draw, tell the Activity it can drop the presplash,
/// then hand over to the steady-state callback. Separate so the signal costs
/// one call at startup rather than a test on every frame.
private func postFirstFrameCallback(_ context: UnsafeMutableRawPointer) {
    guard let choreographer = AChoreographer_getInstance() else { return }
    AChoreographer_postFrameCallback(choreographer, { _, data in
        guard let data else { return }
        let target = Unmanaged<FrameTarget>.fromOpaque(data).takeUnretainedValue()
        guard target.isRunning() else { return }
        target.tick()
        // After the frame, not before: signalling first uncovers an unpainted
        // surface.
        AndroidSurfaceHost.signalFirstFrame()
        postFrameCallback(data)
    }, context)
}

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
// Deliberately not @MainActor, matching Platform_Linux. Android has no main
// queue anyone drains — Java's Looper owns the main thread — so neither hopping
// to it (dispatch_sync deadlocks/traps) nor asserting onto it
// (MainActor.assumeIsolated -> SIGILL) works from the render thread or from the
// interpreter thread Python calls in on.
// @unchecked Sendable so the render thread can capture it: the isolation that
// used to satisfy that requirement is gone, and the invariant is upheld by
// hand instead — `running` is guarded by runLock, and everything else the loop
// touches belongs to the window for its whole lifetime.
public final class PlatformWindow<WindowBase>: @unchecked Sendable
    where WindowBase: NucleantWindow {

    public var on_close: (() -> Void)?

    /// Strongly held by the owner (PyNucleantUI keeps this); referenced weakly
    /// so the window does not retain its delegate.
    public weak var win_delegate: WindowBase?

    /// Frame pacing. A thread of our own, driven by AChoreographer's vsync
    /// callback — started when a surface exists, stopped when it goes away.
    private var renderThread: Thread?
    /// The render thread's Looper, so stop() can wake it out of ALooper_pollOnce.
    private var looper: OpaquePointer?
    private var frameTarget: FrameTarget?
    private var running = false
    private let runLock = NSLock()

    /// Touch ids arrive already assigned by the Java side (MotionEvent pointer
    /// ids), so unlike iOS there is no mapping table to keep.

    /// The window `renderEngine` was last built from. `nucleant_android_surface_resized`
    /// (unlike `_created`) always re-delivers the same pointer it already had,
    /// so comparing against this tells a plain resize (rotation) apart from a
    /// genuinely new surface (minimize/resume tearing the old one down) —
    /// see AndroidSurfaceHost.swift's two `@_cdecl` hooks.
    private var currentWindow: OpaquePointer?

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
        // "Normally one waiting" only holds once the bootstrap has been asked
        // to replay it: the create event fired long before this library was
        // loaded, so nothing recorded it here. See replayFromBootstrap().
        AndroidSurfaceHost.replayFromBootstrap()

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

        if window != currentWindow || win_delegate?.renderEngine == nil {
            // A genuinely new native window — the old VkSurfaceKHR (if any) was
            // built from a window that's no longer valid, so it must be rebuilt
            // from scratch. This is the minimize/resume case: the Surface gets
            // destroyed and a new one created, which the render-node tree bound
            // into the old engine doesn't survive — on_surface_recreated tells
            // the delegate to rebind it.
            currentWindow = window
            // Kept alive through the retarget below via withExtendedLifetime,
            // not dropped before the new engine exists: a ThorVG canvas
            // retargeted by on_surface_recreated() needs its old wgpu target
            // to still be alive at the moment it retargets onto the new one
            // (tvg_wgcanvas_set_target on a canvas whose target was already
            // destroyed fails with TVG_RESULT_INSUFFICIENT_CONDITION — ThorVG
            // has no API to detach a canvas from a target that's gone). Same
            // ordering resizeThorNode already uses in-place: build the new
            // target, retarget onto it, only then let the old one be
            // destroyed.
            let oldEngine = win_delegate?.renderEngine
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
            win_delegate?.on_surface_recreated()
            withExtendedLifetime(oldEngine) {}
        } else {
            // Same window, new size — e.g. a rotation that didn't tear the
            // Surface down. The engine is still valid; on_size re-lays the
            // existing tree and ensureSwapchain picks up the new drawable size
            // on the next drawFrame, same as every other platform.
            win_delegate?.on_size(w: Double(w), h: Double(h))
        }
        startRenderLoop()
    }

    /// Must not return until the renderer has let go of the window — the
    /// Surface is only valid until the Java-side callback returns, and the
    /// bootstrap blocks on this. Stopping the render loop is what "letting go"
    /// requires (no more frames drawn against the dying surface); the engine
    /// itself is deliberately *not* torn down here. It stays alive — its
    /// VkSurfaceKHR/swapchain simply go unused — until surfaceChanged's next
    /// genuinely-new-window rebuild has retargeted every ThorVG canvas onto
    /// the replacement engine (on_surface_recreated) and released this one
    /// itself (see the withExtendedLifetime there). Clearing renderEngine
    /// here would destroy those canvases' wgpu targets before ThorVG has any
    /// chance to detach from them — there is no API to detach a canvas from a
    /// target that's already gone, so retargeting afterwards fails with
    /// TVG_RESULT_INSUFFICIENT_CONDITION. If the surface never comes back
    /// (app closed, not resumed), this engine is reclaimed along with
    /// everything else when the process dies, same as always.
    private func surfaceDestroyed() {
        stopRenderLoop()
    }

    // MARK: - Frame loop

    private func startRenderLoop() {
        runLock.lock()
        defer { runLock.unlock() }
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in
            guard let self else { return }
            // Vsync, not a spin: AChoreographer is Android's CADisplayLink, and
            // the frame callback arrives on the display's cadence. It delivers
            // through a Looper and needs one on the calling thread, so prepare
            // one here and pump it — the callbacks re-post themselves, so this
            // thread sleeps in ALooper_pollOnce between frames instead of
            // burning a core and drifting out of phase with the display.
            //
            // Not @MainActor / assumeIsolated anywhere in here: that check traps
            // with SIGILL off the main thread, and Java's Looper owns the main
            // thread so there is nothing to hop to. `running` is guarded by
            // runLock and the delegate belongs to the window, the same
            // arrangement Platform_Linux uses.
            guard ALooper_prepare(0) != nil,
                  let choreographer = AChoreographer_getInstance()
            else {
                NSLog("[nucleant] no Choreographer on the render thread — no frames")
                return
            }

            self.looper = ALooper_forThread()

            // Held by the window so the pointer handed to C stays valid; the
            // closures hold the window weakly, so neither keeps the other alive.
            let target = FrameTarget(
                tick:      { [weak self] in self?.tick() },
                isRunning: { [weak self] in self?.isRunning ?? false }
            )
            self.frameTarget = target
            postFirstFrameCallback(Unmanaged.passUnretained(target).toOpaque())

            while self.isRunning {
                // -1: block until a callback or an ALooper_wake from stop().
                _ = ALooper_pollOnce(-1, nil, nil, nil)
            }
        }
        thread.name = "nucleant-render"
        renderThread = thread
        thread.start()
    }

    private func stopRenderLoop() {
        runLock.lock()
        running = false
        let looper = self.looper
        runLock.unlock()
        // The render thread is blocked in ALooper_pollOnce with no timeout, so
        // clearing `running` alone would never be noticed — wake it so it can
        // re-check and fall out of the loop.
        if let looper { ALooper_wake(looper) }
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
