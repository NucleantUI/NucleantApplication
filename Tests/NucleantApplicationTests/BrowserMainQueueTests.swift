//
//  BrowserMainQueueTests.swift
//  NucleantApplicationTests
//
//  The browser's Dispatch (Sources/DispatchWasm): times on the monotonic
//  clock, and queues whose work runs on main queue turns — called here
//  directly through the export the page calls, and, in the last test, by the
//  page itself while the test sleeps. Run with scripts/run_wasm_tests.py.
//
#if os(WASI)
import Testing
import Dispatch

@Suite(.serialized)
struct BrowserMainQueueTests {

    // MARK: Times

    @Test func timesAreMonotonicNanoseconds() {
        let first = DispatchTime.now()
        let second = DispatchTime.now()
        #expect(first.uptimeNanoseconds > 0)
        #expect(second >= first)
    }

    @Test func secondsAndIntervalsMoveATime() {
        let start = DispatchTime(uptimeNanoseconds: 10_000_000_000)
        #expect((start + 1.5).uptimeNanoseconds == 11_500_000_000)
        #expect((start - 0.25).uptimeNanoseconds == 9_750_000_000)
        #expect((start + .milliseconds(20)).uptimeNanoseconds == 10_020_000_000)
        #expect((start + .seconds(2)).uptimeNanoseconds == 12_000_000_000)
        #expect((start - .microseconds(5)).uptimeNanoseconds == 9_999_995_000)
        #expect(start + .never == .distantFuture)
        #expect(start.distance(to: start + .nanoseconds(7)) == .nanoseconds(7))
    }

    @Test func arithmeticSaturates() {
        #expect((DispatchTime(uptimeNanoseconds: 5) - 1.0).uptimeNanoseconds == 0)
        #expect(DispatchTime.distantFuture + 1.0 == .distantFuture)
    }

    // MARK: Queues

    @Test func asyncWorkWaitsForATurnAndRunsInOrder() {
        drain()
        let log = Log()
        for value in 1...3 {
            DispatchQueue.main.async { log.append(value) }
        }
        #expect(log.values.isEmpty)
        nucleantMainQueueRun()
        #expect(log.values == [1, 2, 3])
    }

    @Test func workQueuedDuringATurnWaitsForTheNext() {
        drain()
        let log = Log()
        DispatchQueue.main.async {
            log.append(1)
            DispatchQueue.main.async { log.append(2) }
        }
        nucleantMainQueueRun()
        #expect(log.values == [1])
        nucleantMainQueueRun()
        #expect(log.values == [1, 2])
    }

    @Test func everyQueueIsTheMainThread() {
        drain()
        let log = Log()
        DispatchQueue.global().async { log.append(1) }
        DispatchQueue(label: "serial").async { log.append(2) }
        #expect(DispatchQueue.global(qos: .userInitiated).sync { 3 } == 3)
        nucleantMainQueueRun()
        #expect(log.values == [1, 2])
        #expect(Thread.isMainThread)
    }

    @Test func delayedWorkRunsOnceItsDeadlineHasPassed() {
        drain()
        let log = Log()
        let deadline = DispatchTime.now() + 0.03
        DispatchQueue.main.asyncAfter(deadline: deadline) { log.append(1) }
        nucleantMainQueueRun()
        #expect(log.values.isEmpty)
        while DispatchTime.now() <= deadline {}
        nucleantMainQueueRun()
        #expect(log.values == [1])
    }

    @Test func dueWorkRunsInDeadlineOrderThenSubmissionOrder() {
        drain()
        let log = Log()
        let now = DispatchTime.now()
        DispatchQueue.main.asyncAfter(deadline: now - 0.001) { log.append(2) }
        DispatchQueue.main.asyncAfter(deadline: now - 0.002) { log.append(1) }
        DispatchQueue.main.asyncAfter(deadline: now - 0.001) { log.append(3) }
        DispatchQueue.main.asyncAfter(deadline: now + 60) { log.append(99) }
        DispatchQueue.main.async { log.append(0) }
        nucleantMainQueueRun()
        #expect(log.values == [0, 1, 2, 3])
    }

    @Test func thePageRunsTheQueueOnItsOwn() async throws {
        drain()
        let log = Log()
        DispatchQueue.main.async { log.append(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { log.append(2) }
        // Suspends the module (JSPI): the page gets its turns meanwhile.
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.values == [1, 2])
    }

    // MARK: Swift concurrency

    /// Synchronous on purpose: between install and uninstall the test's own
    /// task must not suspend, or its continuation would be queued here too.
    @Test func tasksRunOnMainQueueTurnsOnceInstalled() {
        drain()
        MainQueueExecutor.install()
        defer { MainQueueExecutor.uninstall() }
        let log = Log()

        Task { @MainActor in log.append(1) }
        Task { log.append(2) }
        #expect(log.values.isEmpty)
        nucleantMainQueueRun()
        #expect(log.values == [1, 2])

        // A sleep is a delayed job, due once its time has passed; it resumes
        // the task, whose continuation is then ready for the following turn.
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            log.append(3)
            try? await Task.sleep(for: .milliseconds(5))
            log.append(4)
        }
        nucleantMainQueueRun()
        #expect(log.values == [1, 2])
        for expected in [[1, 2, 3], [1, 2, 3, 4]] {
            let deadline = DispatchTime.now() + 0.006
            while DispatchTime.now() <= deadline {}
            nucleantMainQueueRun()
            nucleantMainQueueRun()
            #expect(log.values == expected)
        }
    }

    /// Runs whatever earlier tests left due, so each starts from an empty
    /// ready list. A far-off delayed item may stay; it is never due here.
    private func drain() {
        nucleantMainQueueRun()
    }
}

/// What the queued work records; `@unchecked Sendable` because it is only
/// ever touched on the one thread.
private final class Log: @unchecked Sendable {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
#endif
