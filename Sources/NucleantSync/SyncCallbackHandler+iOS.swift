#if os(iOS)
import UIKit
import QuartzCore

/// One display link serving every callback that wants the same `fps`.
@MainActor
final class SyncCallbackHandler: NSObject {

    let fps: Int

    /// Every callback of this frame rate, by the index handed back to the caller.
    private var callbacks: [Int: @MainActor (Double) -> Void] = [:]
    private var nextIndex = 0

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    var isEmpty: Bool { callbacks.isEmpty }

    init(fps: Int) {
        self.fps = fps
        super.init()
    }

    func add(_ callback: @escaping @MainActor (Double) -> Void) -> Int {
        let index = nextIndex
        nextIndex += 1
        callbacks[index] = callback
        if link == nil { start() }
        return index
    }

    func remove(_ index: Int) {
        callbacks[index] = nil
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    private func start() {
        // The link retains `self` until `stop()` invalidates it; DisplaySync
        // always stops a handler before dropping it.
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if fps > 0 {
            let rate = Float(fps)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Δt from the link's own vsync timestamps, so a missed refresh is counted
    /// in the next tick. The first tick, with nothing before it, gets one
    /// refresh.
    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        for callback in callbacks.values {
            callback(dt)
        }
    }
}
#endif
