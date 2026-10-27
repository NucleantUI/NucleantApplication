//
//  FrameLoopTurn.swift
//  NucleantApplication
//
//  A hook on the Win32 message loop's turns, for code that wants a periodic
//  tick without owning a window — NucleantSync's display-synced callbacks.
//  `Win32EventLoop` fires it once per turn, which is at least every 8 ms,
//  and from its timer while a window is being dragged or resized.
//
#if os(Windows)

/// Observers of the event loop's turns. Everything here runs on the thread
/// that runs the loop — the main thread — like the rest of the module, so
/// there is no locking.
public enum FrameLoopTurn {

    private nonisolated(unsafe) static var observers: [Int: (Double) -> Void] = [:]
    private nonisolated(unsafe) static var nextID = 0

    /// Calls `observer` with performance-counter seconds on every loop turn.
    /// Returns the id to hand to `remove(_:)`.
    public static func add(_ observer: @escaping (Double) -> Void) -> Int {
        let id = nextID
        nextID += 1
        observers[id] = observer
        return id
    }

    public static func remove(_ id: Int) {
        observers[id] = nil
    }

    static func fire(now: Double) {
        guard !observers.isEmpty else { return }
        // An observer may add or remove observers while running.
        for observer in Array(observers.values) {
            observer(now)
        }
    }
}
#endif
