import Testing
@testable import NucleantSync

@MainActor
@Suite struct DisplaySyncTests {

    @Test func callbackFires() async throws {
        var ticks = 0
        let index = DisplaySync.newCallback(fps: 60) { dt in
            #expect(dt > 0)
            ticks += 1
        }
        defer { DisplaySync.destroyCallback(fps: 60, index: index) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(ticks > 5)
    }

    @Test func sameFpsSharesHandlerAndIndicesAreDistinct() async throws {
        let a = DisplaySync.newCallback(fps: 30) { _ in }
        let b = DisplaySync.newCallback(fps: 30) { _ in }
        #expect(a != b)
        DisplaySync.destroyCallback(fps: 30, index: a)
        DisplaySync.destroyCallback(fps: 30, index: b)
    }

    @Test func destroyedCallbackStopsFiring() async throws {
        var ticks = 0
        let index = DisplaySync.newCallback(fps: 60) { _ in ticks += 1 }
        try await Task.sleep(for: .milliseconds(200))
        DisplaySync.destroyCallback(fps: 60, index: index)
        let after = ticks
        try await Task.sleep(for: .milliseconds(200))
        #expect(ticks == after)
    }

    @Test func maxFpsFiresAndLowerFpsIsSlower() async throws {
        var fast = 0
        var slow = 0
        let f = DisplaySync.newCallback(fps: DisplaySync.maxFPS) { _ in fast += 1 }
        let s = DisplaySync.newCallback(fps: 15) { _ in slow += 1 }
        try await Task.sleep(for: .milliseconds(600))
        DisplaySync.destroyCallback(fps: DisplaySync.maxFPS, index: f)
        DisplaySync.destroyCallback(fps: 15, index: s)
        #expect(fast > 0)
        #expect(slow > 0)
        #expect(fast > slow)
    }
}
