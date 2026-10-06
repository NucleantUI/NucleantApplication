/// Thins a source that ticks faster than the rate a handler wants — an
/// Android vsync, a Linux event-loop turn — down to that rate.
///
/// Apple's display link paces itself (`preferredFrameRateRange`); the others
/// tick at whatever the source does, so the handler skips ticks until one
/// interval has passed. `slack` lets a tick that lands just short of the
/// interval fire anyway, so 30 fps on a 60 Hz source isn't pushed to every
/// third frame by timer jitter.
struct FramePacer {

    /// Seconds between ticks, or `nil` for every tick the source makes.
    let interval: Double?
    let slack: Double
    private var last: Double?

    init(fps: Int, slack: Double = 0.004) {
        self.interval = fps > 0 ? 1.0 / Double(fps) : nil
        self.slack = slack
    }

    /// Δt since the previous fired tick if one is due at `now` (seconds on
    /// any monotonic clock), else `nil`. The first tick, with nothing before
    /// it, gets one interval.
    mutating func step(now: Double) -> Double? {
        guard let previous = last else {
            last = now
            return interval ?? 1.0 / 60.0
        }
        let dt = now - previous
        if let interval, dt < interval - slack { return nil }
        last = now
        return dt
    }

    mutating func reset() {
        last = nil
    }
}
