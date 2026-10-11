#if os(WASI)
import Platform_Wasm

/// Every callback that wants the same `fps`, driven off the page's
/// requestAnimationFrame loop.
///
/// requestAnimationFrame is the browser's vsync callback: it fires once per
/// display refresh while the page is visible (and not at all while the tab
/// is hidden). `Platform_Wasm` already runs one loop for its windows; this
/// handler rides it (`BrowserFrameLoop`) and thins its frames down to `fps`
/// (`FramePacer`), the way the Linux handler rides that platform's event
/// loop — so it needs no window of its own.
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
        if let observer { BrowserFrameLoop.remove(observer) }
        observer = nil
        pacer.reset()
    }

    private func start() {
        // The page's frames arrive on its one thread, where the main actor is.
        observer = BrowserFrameLoop.add { [unowned self] now in
            MainActor.assumeIsolated { self.frame(now: now) }
        }
    }

    private func frame(now: Double) {
        guard let dt = pacer.step(now: now) else { return }
        for callback in callbacks.values {
            callback(dt)
        }
    }
}
#endif
