//
//  MainQueueExecutor.swift
//  Dispatch (WebAssembly)
//
//  Swift concurrency on the browser's main queue.
//
//  The runtime's own executors for WASI run jobs only from an `async` main,
//  draining them until none are left — and an app in the browser is a
//  reactor whose `main` returns to the page, after which that drain never
//  runs again: a `Task { }`, an `await MainActor.run`, a `Task.sleep` would
//  simply never continue. So the main actor's executor and the default
//  executor are replaced, through the runtime's executor factory, with two
//  that put every job on the main queue — a sleep's continuation at its
//  deadline, the way `asyncAfter` work waits — where it runs on the page's
//  next turn.
//
//  The factory is still SPI in Swift 6.3 (ExperimentalCustomExecutors);
//  this is the one file that depends on it.
//
#if os(WASI)
@_spi(ExperimentalCustomExecutors) @_spi(ExperimentalScheduling) import _Concurrency
import CDispatchWasm

/// Makes the browser's main queue Swift concurrency's executor, main and
/// default alike.
///
/// Call before the first task is created — an app's lifecycle does, before
/// `onStart()`. A process with an `async` main (a test runner) is draining
/// the runtime's own executors, which this takes the jobs away from: there,
/// `uninstall()` once the lifecycle has been exercised, without suspending
/// in between.
public enum MainQueueExecutor {

    private nonisolated(unsafe) static var previous: (main: any MainExecutor, default: any TaskExecutor)?

    public static var isInstalled: Bool { previous != nil }

    public static func install() {
        guard previous == nil else { return }
        previous = (MainActor.executor, Task.defaultExecutor)
        _createExecutors(factory: BrowserExecutors.self)
    }

    /// Puts back the executors `install()` replaced. Jobs already on the
    /// main queue stay there.
    public static func uninstall() {
        guard let previous else { return }
        RestoredExecutors.executors = previous
        self.previous = nil
        _createExecutors(factory: RestoredExecutors.self)
    }
}

private struct BrowserExecutors: ExecutorFactory {
    static let main = MainQueueMainExecutor()
    static let task = MainQueueTaskExecutor()

    static var mainExecutor: any MainExecutor { main }
    static var defaultExecutor: any TaskExecutor { task }
}

private struct RestoredExecutors: ExecutorFactory {
    nonisolated(unsafe) static var executors: (main: any MainExecutor, default: any TaskExecutor)?

    static var mainExecutor: any MainExecutor { executors!.main }
    static var defaultExecutor: any TaskExecutor { executors!.default }
}

/// The main actor's executor. There is one thread, so whatever runs is on
/// the main actor: the isolation checks always pass.
private final class MainQueueMainExecutor: MainExecutor, SchedulingExecutor, @unchecked Sendable {

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        MainQueue.enqueue { job.runSynchronously(on: executor) }
    }

    func enqueue<C: Clock>(_ job: consuming ExecutorJob, after delay: C.Duration, tolerance: C.Duration?, clock: C) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        MainQueue.enqueue(at: deadline(after: delay)) { job.runSynchronously(on: executor) }
    }

    func enqueue<C: Clock>(_ job: consuming ExecutorJob, at instant: C.Instant, tolerance: C.Duration?, clock: C) {
        enqueue(job, after: clock.now.duration(to: instant), tolerance: tolerance, clock: clock)
    }

    /// The page runs the loop, a turn at a time.
    func run() throws {}
    func stop() {}

    func checkIsolated() {}
    func isIsolatingCurrentContext() -> Bool? { true }
}

/// The default executor, for nonisolated work. Its jobs run on the same
/// queue, as the generic executor, so they do not hop again on arrival.
private final class MainQueueTaskExecutor: TaskExecutor, SchedulingExecutor, @unchecked Sendable {

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        MainQueue.enqueue { job.runSynchronously(on: executor) }
    }

    func enqueue<C: Clock>(_ job: consuming ExecutorJob, after delay: C.Duration, tolerance: C.Duration?, clock: C) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        MainQueue.enqueue(at: deadline(after: delay)) { job.runSynchronously(on: executor) }
    }

    func enqueue<C: Clock>(_ job: consuming ExecutorJob, at instant: C.Instant, tolerance: C.Duration?, clock: C) {
        enqueue(job, after: clock.now.duration(to: instant), tolerance: tolerance, clock: clock)
    }
}

/// Monotonic nanoseconds `delay` from now. Swift's own clocks measure in
/// `Duration`; any other clock's delay is taken as already due.
private func deadline<D: DurationProtocol>(after delay: D) -> UInt64 {
    let now = ndw_monotonic_nanoseconds()
    guard let delay = delay as? Duration else { return now }
    let (seconds, attoseconds) = delay.components
    guard seconds >= 0, attoseconds >= 0 else { return now }
    let nanoseconds = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
    let (sum, overflow) = now.addingReportingOverflow(nanoseconds.partialValue &+ UInt64(attoseconds / 1_000_000_000))
    return nanoseconds.overflow || overflow ? .max : sum
}
#endif
