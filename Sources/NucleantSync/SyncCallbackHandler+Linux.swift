#if os(Linux)
import Platform_Linux

/// Every callback that wants the same `fps`, driven off the Linux event loop.
///
/// Linux has no display-wide vsync callback: Wayland's `wl_surface.frame` and
/// X11's loop tick belong to a window, and `Platform_Linux` already runs one
/// poll loop on the main thread that wakes at least every 8 ms. This handler
/// rides that loop (`FrameLoopTurn`) and thins its turns down to `fps`
/// (`FramePacer`), so it needs no window and no thread of its own — but it is
/// paced by the loop, not by vsync, and so is accurate to a few milliseconds
/// rather than to the refresh.
@MainActor
final class SyncCallbackHandler {

    let fps: Int

    /// Every callback of this frame rate, by the index handed back to the caller.
    private var callbacks: [Int: @MainActor (Double) -> Void] = [:]
    private var nextIndex = 0

    private var observer: Int?
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
        if observer == nil { start() }
        return index
    }

    func remove(_ index: Int) {
        callbacks[index] = nil
    }

    func stop() {
        if let observer { FrameLoopTurn.remove(observer) }
        observer = nil
        pacer.reset()
    }

    private func start() {
        // The loop runs on the main thread, which is where the main actor is.
        observer = FrameLoopTurn.add { [unowned self] now in
            MainActor.assumeIsolated { self.turn(now: now) }
        }
    }

    private func turn(now: Double) {
        guard let dt = pacer.step(now: now) else { return }
        for callback in callbacks.values {
            callback(dt)
        }
    }
}
#endif
