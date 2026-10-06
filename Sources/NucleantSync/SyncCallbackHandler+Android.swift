#if os(Android)
import CAndroidChoreographer

/// One Choreographer frame-callback chain serving every callback that wants
/// the same `fps`.
///
/// `AChoreographer` is Android's vsync callback. It delivers on the looper of
/// the thread that asked, so handlers must be created from the UI thread —
/// the process main thread, which is also where the main actor lives. Its
/// frame callbacks are one-shot, so each tick posts the next; and there is no
/// way to cancel a posted one, so `stop()` only clears `active` and the
/// pending callback lets the chain end. `postFrameCallback64` is API 29.
///
/// The Choreographer ticks at the display's rate whatever was asked, so
/// anything slower is made by skipping ticks (`FramePacer`).
@MainActor
final class SyncCallbackHandler {

    let fps: Int

    /// Every callback of this frame rate, by the index handed back to the caller.
    private var callbacks: [Int: @MainActor (Double) -> Void] = [:]
    private var nextIndex = 0

    private var active = false
    /// A frame callback is posted and has not fired yet.
    private var pending = false
    private var pacer: FramePacer

    var isEmpty: Bool { callbacks.isEmpty }

    init(fps: Int) {
        self.fps = fps
        self.pacer = FramePacer(fps: fps)
    }

    func add(_ callback: @escaping @MainActor (Double) -> Void) -> Int {
        let index = nextIndex
        nextIndex += 1
        callbacks[index] = callback
        if !active { start() }
        return index
    }

    func remove(_ index: Int) {
        callbacks[index] = nil
    }

    func stop() {
        active = false
        pacer.reset()
    }

    private func start() {
        active = true
        // A callback from before an earlier stop() may still be in flight; it
        // continues the chain, so posting another would double the ticks.
        if !pending { post() }
    }

    private func post() {
        guard let choreographer = AChoreographer_getInstance() else { return }
        pending = true
        // Retained for as long as the callback is pending, so a handler that
        // is dropped right after stop() isn't freed under the Choreographer.
        let data = Unmanaged.passRetained(self).toOpaque()
        AChoreographer_postFrameCallback64(choreographer, { frameTimeNanos, data in
            guard let data else { return }
            let handler = Unmanaged<SyncCallbackHandler>.fromOpaque(data).takeRetainedValue()
            MainActor.assumeIsolated {
                handler.frame(now: Double(frameTimeNanos) * 1e-9)
            }
        }, data)
    }

    private func frame(now: Double) {
        pending = false
        guard active else { return }
        post()
        guard let dt = pacer.step(now: now) else { return }
        for callback in callbacks.values {
            callback(dt)
        }
    }
}
#endif
