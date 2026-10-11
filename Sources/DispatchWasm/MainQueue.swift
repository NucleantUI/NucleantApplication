//
//  MainQueue.swift
//  Dispatch (WebAssembly)
//
//  The browser's main queue: what `DispatchQueue.main.async`, `asyncAfter`
//  and — once `MainQueueExecutor.install()` has run — every Swift concurrency
//  job end up on (MainQueueExecutor.swift).
//
//  On the other platforms a run loop (or the platform's own event loop)
//  services the main queue. In the browser the page owns the event loop and
//  the module only runs while the page is calling into it, so the queue asks
//  the page for a turn: `mainQueueWake(delay)`, which Web/nucleant-app.js
//  answers by calling the `nucleant_main_queue_run` export — straight after
//  the current call returns (a message-channel task) for ready work, or from
//  a timer for delayed work.
//
#if os(WASI)
import CDispatchWasm

enum MainQueue {

    private struct Delayed {
        let deadline: UInt64
        let sequence: UInt64
        let work: () -> Void
    }

    // One thread: nothing here is ever touched concurrently.
    private nonisolated(unsafe) static var ready: [() -> Void] = []
    /// Sorted by deadline, then submission.
    private nonisolated(unsafe) static var delayed: [Delayed] = []
    private nonisolated(unsafe) static var nextSequence: UInt64 = 0
    /// When the turn the page has been asked for is due; nil while none is.
    private nonisolated(unsafe) static var wakeDeadline: UInt64?

    static func enqueue(_ work: @escaping () -> Void) {
        ready.append(work)
        requestTurn(at: 0)
    }

    static func enqueue(at deadline: UInt64, _ work: @escaping () -> Void) {
        let item = Delayed(deadline: deadline, sequence: nextSequence, work: work)
        nextSequence += 1
        let index = delayed.firstIndex { $0.deadline > deadline } ?? delayed.endIndex
        delayed.insert(item, at: index)
        requestTurn(at: deadline)
    }

    /// Whether anything is queued, due or not.
    static var isEmpty: Bool { ready.isEmpty && delayed.isEmpty }

    /// One turn: the delayed work that is due joins the ready work, and all
    /// of that runs, in order. Work queued while it runs waits for the next
    /// turn, so a job that requeues itself cannot hold the page.
    static func runTurn() {
        wakeDeadline = nil
        let now = ndw_monotonic_nanoseconds()
        let due = delayed.prefix { $0.deadline <= now }
        if !due.isEmpty {
            delayed.removeFirst(due.count)
            ready.append(contentsOf: due.map(\.work))
        }
        let batch = ready
        ready = []
        for work in batch {
            work()
        }
        if !ready.isEmpty {
            requestTurn(at: 0)
        } else if let next = delayed.first {
            requestTurn(at: next.deadline)
        }
    }

    /// Asks the page for a turn at `deadline` (monotonic nanoseconds; 0 for
    /// now), unless one at least as early is already coming.
    private static func requestTurn(at deadline: UInt64) {
        if let wakeDeadline, wakeDeadline <= deadline { return }
        wakeDeadline = deadline
        let now = ndw_monotonic_nanoseconds()
        let delay = deadline > now ? Double(deadline - now) / 1_000_000 : 0
        ndw_main_queue_wake(delay)
    }
}

/// The page's call for a main queue turn (`mainQueueWake`).
@_expose(wasm, "nucleant_main_queue_run")
public func nucleantMainQueueRun() {
    MainQueue.runTurn()
}
#endif
