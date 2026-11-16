//
//  MacOSPlatformTests.swift
//  NucleantApplicationTests
//
//  Platform_MacOS (macOS only), on a real window: the phase it tells its
//  delegate as it is minimized and the app is hidden, and back.
//
//  The app is really hidden. Minimizing is handed to the window the way
//  AppKit does it, as its delegate's did-minimize and did-restore calls: a
//  real one stops every display link in the process for the length of the
//  Dock's animation, the ones other tests are timing included.
//
#if os(macOS)
import Testing
import AppKit
import CVulkan
import NucleantVulkan
import NucleantWindow
import Platform_MacOS

@Suite(.serialized)
@MainActor
struct MacOSPlatformTests {

    /// A shown window, and the phases it reports, emptied after each step.
    private func window() -> (PlatformWindow<PhaseRecordingWindow>, PhaseRecordingWindow) {
        let window = PlatformWindow<PhaseRecordingWindow>(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let delegate = PhaseRecordingWindow()
        window.win_delegate = delegate
        window.orderFront(nil)
        return (window, delegate)
    }

    /// Let the main run loop turn until `done` holds, for at most `timeout`
    /// seconds.
    private func run(until done: () -> Bool, timeout: Double = 5) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The window going into the Dock and coming back out, as AppKit tells
    /// its delegate.
    private func minimize(_ window: PlatformWindow<PhaseRecordingWindow>) {
        window.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: window))
    }

    private func restore(_ window: PlatformWindow<PhaseRecordingWindow>) {
        window.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
    }

    @Test func aMinimizedWindowIsInactiveUntilItIsBack() {
        let (window, delegate) = window()
        defer { window.close() }

        minimize(window)
        #expect(delegate.take() == ["inactive"])
        restore(window)
        #expect(delegate.take() == ["active"])
    }

    @Test func aPhaseIsToldOnce() {
        let (window, delegate) = window()
        defer { window.close() }

        restore(window)
        #expect(delegate.take().isEmpty)
        minimize(window)
        minimize(window)
        #expect(delegate.take() == ["inactive"])
        restore(window)
    }

    @Test func aHiddenAppsWindowIsInTheBackground() async {
        let (window, delegate) = window()
        defer { window.close() }
        let app = NSApplication.shared

        app.hide(nil)
        await run { app.isHidden }
        #expect(app.isHidden)
        #expect(delegate.take() == ["background"])

        app.unhide(nil)
        await run { !app.isHidden }
        #expect(delegate.take() == ["active"])
    }

    @Test func aMinimizedWindowOfAHiddenAppIsInactiveOnceTheAppIsBack() async {
        let (window, delegate) = window()
        defer { window.close() }
        let app = NSApplication.shared

        minimize(window)
        app.hide(nil)
        await run { app.isHidden }
        #expect(delegate.take() == ["inactive", "background"])

        app.unhide(nil)
        await run { !app.isHidden }
        #expect(delegate.take() == ["inactive"])

        restore(window)
        #expect(delegate.take() == ["active"])
    }
}

/// A composite slot the test window never fills: the platform window is
/// tested without an engine.
final class PhaseTestSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case none
    }

    let id: Int
    let context: Context
    var needsRender = false

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {}
    func update(device: Device, cmd: VkCommandBuffer) {}
    func destroyResources(device: Device) {}
    func getImageView() -> VkImageView? { nil }
}

/// Notes each phase it is told; everything else is ignored.
final class PhaseRecordingWindow: NucleantWindow, WindowBaseDelegate {
    var renderEngine: VulkanRenderEngine<PhaseTestSlot>?
    var win_rect: SIMD4<Int> = .init(0, 0, 160, 120)
    private var phases: [String] = []

    /// The phases so far, emptying the record.
    func take() -> [String] {
        defer { phases = [] }
        return phases
    }

    func on_phase_active() { phases.append("active") }
    func on_phase_inactive() { phases.append("inactive") }
    func on_phase_background() { phases.append("background") }

    func present() throws {}
    func onFrame(_ dt: Double) {}
    func on_size(w: Double, h: Double) {}
    func on_mouse_down(x: Double, y: Double) {}
    func on_mouse_up(x: Double, y: Double) {}
    func on_mouse_dragged(x: Double, y: Double) {}
    func on_mouse_moved(x: Double, y: Double) {}
    func on_right_mouse_down(x: Double, y: Double) {}
    func on_right_mouse_up(x: Double, y: Double) {}
    func on_scroll(dx: Double, dy: Double) {}
    func on_key_down(keyCode: UInt16, characters: String?) {}
    func on_key_up(keyCode: UInt16, characters: String?) {}
}
#endif
