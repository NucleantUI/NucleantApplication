//
//  BrowserPlatformTests.swift
//  NucleantApplicationTests
//
//  Platform_Wasm and the browser app lifecycle (wasm only), on a real page:
//  windows are real canvases, and events enter through the same exported
//  functions Web/nucleant-app.js calls from the DOM. Run with
//  scripts/run_wasm_tests.py, which builds the tests for wasm and runs them
//  in headless Chrome.
//
#if os(WASI)
import Testing
import CVulkan
import CWasmDOM
import Dispatch
import Foundation
import NucleantVulkan
import NucleantWindow
import Observation
@testable import NucleantApplication
@testable import Platform_Wasm

@Suite(.serialized)
@MainActor
struct BrowserPlatformTests {

    // MARK: Keys

    @Test func keyCodesAreTheMacOSVirtualKeyCodes() {
        let expected: [String: UInt16] = [
            "KeyA": 0x00, "KeyZ": 0x06, "Digit0": 0x1D, "Enter": 0x24, "Tab": 0x30, "Space": 0x31,
            "Backspace": 0x33, "Escape": 0x35, "Home": 0x73, "PageUp": 0x74, "End": 0x77, "PageDown": 0x79,
            "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E, "NumpadEnter": 0x4C,
        ]
        for (code, keyCode) in expected {
            #expect(BrowserKeyMap.keyCode(forCode: code) == keyCode, "\(code)")
        }
        #expect(BrowserKeyMap.keyCode(forCode: "NotAKey") == nil)
    }

    @Test func charactersAreTheTypedTextOrAppKitsControlCharacter() {
        #expect(BrowserKeyMap.characters(forKey: "a") == "a")
        #expect(BrowserKeyMap.characters(forKey: "A") == "A")
        #expect(BrowserKeyMap.characters(forKey: "é") == "é")
        #expect(BrowserKeyMap.characters(forKey: "Enter") == "\r")
        #expect(BrowserKeyMap.characters(forKey: "Tab") == "\t")
        #expect(BrowserKeyMap.characters(forKey: "Backspace") == "\u{7F}")
        #expect(BrowserKeyMap.characters(forKey: "Escape") == "\u{1B}")
        #expect(BrowserKeyMap.characters(forKey: "ArrowUp") == "\u{F700}")
        #expect(BrowserKeyMap.characters(forKey: "Shift") == nil)
    }

    // MARK: Windows

    @Test func windowIsACanvasOfTheRequestedSize() throws {
        let window = try PlatformWindow<RecordingWindow>(width: 320, height: 200, title: "metrics")
        defer { window.close() }
        #expect(window.width == 320)
        #expect(window.height == 200)
        #expect(window.scale > 0)
        #expect(window.bufferWidth == UInt32((320 * window.scale).rounded()))
        #expect(window.bufferHeight == UInt32((200 * window.scale).rounded()))
        #expect(window.canvasSelector == "#nucleant-window-\(window.window.id)")
    }

    @Test func aWindowIsHeldWithinItsLimits() async throws {
        let window = try PlatformWindow<RecordingWindow>(width: 320, height: 200, title: "limits")
        defer { window.close() }
        // The page reports the new size through its ResizeObserver, a turn
        // later; the sleep is that turn.
        window.setLayout(fillsContainer: false, minSize: SIMD2(400, 300))
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.width == 400)
        #expect(window.height == 300)

        window.setLayout(fillsContainer: false, maxSize: SIMD2(100, 80))
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.width == 100)
        #expect(window.height == 80)
    }

    @Test func aFillingWindowTakesItsContainerUpToItsMaximum() async throws {
        let window = try PlatformWindow<RecordingWindow>(width: 120, height: 90, title: "fills")
        defer { window.close() }
        // The test page's container is as wide as the page, which is wider
        // than 250, and has no height of its own — the minimum gives it one.
        window.setLayout(fillsContainer: true, minSize: SIMD2(0, 120), maxSize: SIMD2(250, 120))
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.width == 250)
        #expect(window.height == 120)
        #expect(window.bufferWidth == UInt32((250 * window.scale).rounded()))
    }

    @Test func mouseEventsReachTheDelegateAsMouseCallbacks() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        let id = window.window.id
        nucleantPointer(id, BrowserPointer.move, 10, 20, 0, 0, 1, BrowserPointer.mouse)
        nucleantPointer(id, BrowserPointer.down, 11, 21, 0, 1, 1, BrowserPointer.mouse)
        nucleantPointer(id, BrowserPointer.move, 12, 22, 0, 1, 1, BrowserPointer.mouse)
        nucleantPointer(id, BrowserPointer.up, 13, 23, 0, 0, 1, BrowserPointer.mouse)
        nucleantPointer(id, BrowserPointer.down, 14, 24, 2, 2, 1, BrowserPointer.mouse)
        nucleantPointer(id, BrowserPointer.up, 15, 25, 2, 0, 1, BrowserPointer.mouse)
        nucleantWheel(id, -3, 40)
        #expect(delegate.events == [
            "moved 10 20", "down 11 21", "dragged 12 22", "up 13 23",
            "rightDown 14 24", "rightUp 15 25", "scroll -3 40",
        ])
    }

    @Test func touchAndPenEventsReachTheDelegateAsTouches() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        let id = window.window.id
        nucleantPointer(id, BrowserPointer.down, 1, 2, 0, 1, 7, BrowserPointer.touch)
        nucleantPointer(id, BrowserPointer.down, 3, 4, 0, 1, 8, BrowserPointer.pen)
        nucleantPointer(id, BrowserPointer.move, 5, 6, 0, 1, 7, BrowserPointer.touch)
        nucleantPointer(id, BrowserPointer.up, 5, 6, 0, 0, 7, BrowserPointer.touch)
        nucleantPointer(id, BrowserPointer.cancel, 3, 4, 0, 0, 8, BrowserPointer.pen)
        #expect(delegate.events == [
            "touchDown 7 1 2", "touchDown 8 3 4", "touchMoved 7 5 6", "touchUp 7 5 6", "touchCancelled 8 3 4",
        ])
    }

    @Test func keysReachTheDelegate() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        window.browserKeyDown(key: 0x24, chars: "\r")
        window.browserKeyUp(key: 0x24, chars: "\r")
        #expect(delegate.events == ["keyDown 36", "keyUp 36"])
    }

    @Test func eventsForAClosedWindowGoNowhere() throws {
        let (window, delegate) = try openWindow()
        let id = window.window.id
        window.close()
        nucleantPointer(id, BrowserPointer.down, 1, 1, 0, 1, 1, BrowserPointer.mouse)
        #expect(delegate.events.isEmpty)
        #expect(BrowserWindow.window(id) == nil)
    }

    // MARK: Frames

    @Test func framesTickWindowsAndObserversWithBrowserTimestamps() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        var observed: [Double] = []
        let observer = BrowserFrameLoop.add { observed.append($0) }
        defer { BrowserFrameLoop.remove(observer) }

        // Exported entry point, rAF timestamps in milliseconds.
        nucleantFrame(1000)
        nucleantFrame(1016.5)
        #expect(observed == [1.0, 1.0165])
        #expect(delegate.frames.count == 2)
        #expect(abs(delegate.frames[0] - 1.0 / 60.0) < 1e-9)
        #expect(abs(delegate.frames[1] - 0.0165) < 1e-9)

        window.stopFrameLoop()
        nucleantFrame(1033)
        #expect(delegate.frames.count == 2)
    }

    // MARK: Appearance

    @Test func colorSchemeIsThePagesPreference() {
        // scripts/run_wasm_tests.py starts Chrome with a dark page.
        #expect(nwd_color_scheme_is_dark() == 1)
        #expect(BrowserAppearance.colorScheme() == .dark)
    }

    @Test func colorSchemeChangesReachObserversAndLaterReads() {
        let original = BrowserAppearance.colorScheme()
        defer { nucleantColorSchemeChanged(original.rawValue) }
        var seen: [BrowserColorScheme] = []
        let observer = BrowserAppearance.addObserver { seen.append($0) }

        // Exported entry point, as the page's media-query listener calls it.
        nucleantColorSchemeChanged(0)
        #expect(BrowserAppearance.colorScheme() == .light)
        nucleantColorSchemeChanged(1)
        #expect(BrowserAppearance.colorScheme() == .dark)

        BrowserAppearance.removeObserver(observer)
        nucleantColorSchemeChanged(0)
        #expect(seen == [.light, .dark])
        #expect(BrowserAppearance.colorScheme() == .light)
    }

    // MARK: Time zones

    @Test func namedTimeZonesFormatFromThePagesZoneinfo() {
        // Foundation reads a named zone from /usr/share/zoneinfo, which the
        // page mounts from zoneinfo.bin (scripts/run_wasm_tests.py serves the
        // one build_wasm_app.py writes for an app); without it this traps.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let date = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 14:13 UTC
        let expected = [
            "Europe/Lisbon": "2026-09-21 15:13",
            "America/New_York": "2026-09-21 10:13",
            "Asia/Tokyo": "2026-09-21 23:13",
        ]
        for (zone, text) in expected {
            formatter.timeZone = TimeZone(identifier: zone)
            #expect(formatter.string(from: date) == text, "\(zone)")
        }
    }

    // MARK: App lifecycle

    @Test func runStartsTheAppAndThePageKeepsItUntilTerminate() throws {
        // run() makes the main queue Swift concurrency's executor; this
        // process's async main needs its jobs back afterwards.
        defer { MainQueueExecutor.uninstall() }
        weak var released: TestApp?
        do {
            let app = TestApp()
            app.setup()
            try app.run()
            #expect(app.started)
            #expect(MainQueueExecutor.isInstalled)
            released = app
        }
        // Past the `main` that made it, the page holds the app.
        #expect(released != nil)
        released?.appDelegate?.terminate()
        #expect(released == nil)
    }

    private func openWindow() throws -> (PlatformWindow<RecordingWindow>, RecordingWindow) {
        let window = try PlatformWindow<RecordingWindow>(width: 100, height: 80, title: "events")
        let delegate = RecordingWindow()
        window.win_delegate = delegate
        // Kept alive for the test by the returned tuple.
        return (window, delegate)
    }
}

// MARK: - Test doubles

@MainActor
final class TestApp: NucleantApplication {
    var appDelegate: AppDelegate<TestApp>?
    var started = false

    func onStart() {
        started = true
    }
}

@Observable
final class TestNode: RenderContainerNode, @unchecked Sendable {
    final class Context: RenderNodeContext {}
    let id: Int
    let context: Context
    var needsRender = false

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {}
    func update(engine: Engine, cmd: VkCommandBuffer) {}
    func destroyResources(engine: Engine) {}
    func getImageView() -> VkImageView? { nil }
}

/// A window that records what reaches it, in the delegate's own terms.
final class RecordingWindow: NucleantWindow, BrowserWindowDelegate {
    typealias Node = TestNode

    var renderEngine: VulkanRenderEngine<TestNode>?
    var win_rect: SIMD4<Int> = .init(0, 0, 100, 80)
    var events: [String] = []
    var frames: [Double] = []

    private func record(_ name: String, _ values: Double...) {
        events.append(([name] + values.map { String(Int($0)) }).joined(separator: " "))
    }

    func present() throws {}
    func onFrame(_ dt: Double) { frames.append(dt) }
    func on_size(w: Double, h: Double) { record("size", w, h) }
    func on_mouse_down(x: Double, y: Double) { record("down", x, y) }
    func on_mouse_up(x: Double, y: Double) { record("up", x, y) }
    func on_mouse_dragged(x: Double, y: Double) { record("dragged", x, y) }
    func on_mouse_moved(x: Double, y: Double) { record("moved", x, y) }
    func on_right_mouse_down(x: Double, y: Double) { record("rightDown", x, y) }
    func on_right_mouse_up(x: Double, y: Double) { record("rightUp", x, y) }
    func on_scroll(dx: Double, dy: Double) { record("scroll", dx, dy) }
    func on_key_down(keyCode: UInt16, characters: String?) { record("keyDown", Double(keyCode)) }
    func on_key_up(keyCode: UInt16, characters: String?) { record("keyUp", Double(keyCode)) }
    func on_touch_down(id: Int, x: Double, y: Double) { record("touchDown", Double(id), x, y) }
    func on_touch_moved(id: Int, x: Double, y: Double) { record("touchMoved", Double(id), x, y) }
    func on_touch_up(id: Int, x: Double, y: Double) { record("touchUp", Double(id), x, y) }
    func on_touch_cancelled(id: Int, x: Double, y: Double) { record("touchCancelled", Double(id), x, y) }
}
#endif
