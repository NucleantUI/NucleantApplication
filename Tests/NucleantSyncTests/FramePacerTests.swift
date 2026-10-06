import Testing
@testable import NucleantSync

@Suite struct FramePacerTests {

    @Test func thinsA60HzSourceTo30() {
        var pacer = FramePacer(fps: 30)
        var fired = 0
        for frame in 0..<60 {
            if pacer.step(now: Double(frame) / 60.0) != nil { fired += 1 }
        }
        #expect(fired == 30)
    }

    @Test func maxFiresEveryTickWithRealDt() {
        var pacer = FramePacer(fps: 0)
        _ = pacer.step(now: 1.0)
        let dt = pacer.step(now: 1.01)
        #expect(dt != nil)
        #expect(abs(dt! - 0.01) < 1e-9)
    }

    @Test func firstTickGetsOneInterval() {
        var pacer = FramePacer(fps: 20)
        #expect(pacer.step(now: 5.0) == 0.05)
    }

    @Test func tickJustShortOfTheIntervalStillFires() {
        var pacer = FramePacer(fps: 60)
        _ = pacer.step(now: 0)
        #expect(pacer.step(now: 0.016) != nil) // 16 ms turn vs 16.67 ms interval
    }
}
