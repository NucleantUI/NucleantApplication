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

    /// Strongly held by the owner; referenced weakly
    /// so the window does not retain its delegate.
    public weak var win_delegate: WindowBase?

    /// Whether frames from the Activity should be drawn. Set when a surface
    /// exists and the Activity is resumed; cleared when either goes away.
    private var running = false
    private let runLock = NSLock()

    /// Touch ids arrive already assigned by the Java side (MotionEvent pointer
    /// ids), so unlike iOS there is no mapping table to keep.

    /// The window `renderEngine` was last built from.
    /// `AndroidSurfaceHost.surfaceResized` (unlike `surfaceCreated`) always
    /// re-delivers the same pointer it already had, so comparing against this
    /// tells a plain resize (rotation) apart from a genuinely new surface
    /// (minimize/resume tearing the old one down).
    private var currentWindow: OpaquePointer?

    /// When the last frame was drawn, by either source — the Choreographer
    /// callback or the poll-timeout fallback. Read and written only on the
    /// render thread.

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
        AndroidSurfaceHost.onFrame = { [weak self] dt in
            guard let self, self.isRunning else { return }
            self.tick(dt)
        }
    }

    /// Attach to the surface that already exists, if any.
    ///
    /// The Activity creates its surface before it enters Swift at all, so by the
    /// time a window calls `present()` there is one waiting — recorded by
    /// `AndroidSurfaceHost.surfaceCreated`, which the bridge in this same module
    /// called on the way through. It used to need a replay: the bridge lived in
    /// the app's own library and this one was loaded later by Python, so the
    /// create event fired before anything here could record it.
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
            win_delegate?.on_size(
                w: Double(w) / AndroidSurfaceHost.displayScale,
                h: Double(h) / AndroidSurfaceHost.displayScale
            )
            win_delegate?.on_surface_recreated()
            withExtendedLifetime(oldEngine) {}
        } else {
            // Same window, new size — e.g. a rotation that didn't tear the
            // Surface down. The engine is still valid; on_size re-lays the
            // existing tree and ensureSwapchain picks up the new drawable size
            // on the next drawFrame, same as every other platform.
            //
            // Points, not pixels: the surface reports pixels and `on_size`
            // multiplies by the display scale to get back to them. Passing
            // pixels here asks for a drawable `scale` times too large, which
            // the GPU refuses outright once the scale is not 1.
            win_delegate?.on_size(
                w: Double(w) / AndroidSurfaceHost.displayScale,
                h: Double(h) / AndroidSurfaceHost.displayScale
            )
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

    // MARK: - Frame loop

    /// Frames come from the Activity now, so there is nothing to start.
    ///
    /// This used to spawn a thread with its own ALooper and AChoreographer,
    /// because the renderer lived in a library Python loaded later and could
    /// not be driven from the interpreter thread. With the app compiled into
    /// one binary and the Activity owning the process, the Activity's own
    /// Choreographer is the frame source — the ordinary Android arrangement —
    /// and `active` is only a flag deciding whether those frames are drawn.
    private func startRenderLoop() {
        runLock.lock()
        running = true
        runLock.unlock()
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

    /// Stop drawing. The Activity keeps posting frames; `running` decides
    /// whether they do anything, so a backgrounded app costs one branch.
    private func stopRenderLoop() {
        runLock.lock()
        running = false
        runLock.unlock()
    }

    private var isRunning: Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return running
    }

    /// Draw one frame.
    ///
    /// `dt` comes from the Activity's Choreographer callback — the display's
    /// own vsync timestamps — rather than being derived from a wall clock
    /// here, so the renderer advances on the same clock the frames arrive on.
    private func tick(_ dt: Double) {
        win_delegate?.onFrame(dt)
        // The Activity polls for this to take its presplash down. Marked after
        // the frame rather than before, so what it reports is a frame that has
        // actually reached the surface.
        AndroidSurfaceHost.markFirstFrame()
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
