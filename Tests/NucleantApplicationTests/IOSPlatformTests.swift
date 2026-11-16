//
//  IOSPlatformTests.swift
//  NucleantApplicationTests
//
//  Platform_iOS (iOS only): the phase a window tells its delegate as its
//  scene, or the app, goes to the background and back.
//
//  The test process is not an app — it has no `UIApplication` and connects
//  no scenes — so UIKit's notifications are posted by hand, as UIKit posts
//  them. The scene is the one UIKit gives a window made without one; it is
//  in the foreground and active.
//
#if os(iOS)
import Testing
import UIKit
import CVulkan
import NucleantVulkan
import NucleantWindow
import Platform_iOS

@Suite(.serialized)
@MainActor
struct IOSPlatformTests {

    /// The scene a window lives in here.
    private func scene() throws -> UIWindowScene {
        try #require(UIWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 120)).windowScene)
    }

    private func post(_ name: Notification.Name, for object: AnyObject? = nil) {
        NotificationCenter.default.post(name: name, object: object)
    }

    @Test func aWindowGoesAsItsScene() throws {
        let scene = try scene()
        let window = PlatformWindow<PhaseRecordingWindow>(windowScene: scene)
        let delegate = PhaseRecordingWindow()
        window.win_delegate = delegate
        // The scene is active, as the window starts out.
        #expect(delegate.take().isEmpty)

        post(UIScene.willDeactivateNotification, for: scene)
        #expect(delegate.take() == ["inactive"])
        post(UIScene.didEnterBackgroundNotification, for: scene)
        #expect(delegate.take() == ["background"])
        post(UIScene.willEnterForegroundNotification, for: scene)
        #expect(delegate.take() == ["inactive"])
        post(UIScene.didActivateNotification, for: scene)
        #expect(delegate.take() == ["active"])
    }

    /// Two scenes side by side, one sent away: the other's window stays.
    /// Nor does the app as a whole move a scene's window: the app goes into
    /// the background only once its last scene has.
    @Test func anotherScenesPhaseLeavesTheWindowAsItIs() throws {
        let scene = try scene()
        let window = PlatformWindow<PhaseRecordingWindow>(windowScene: scene)
        let delegate = PhaseRecordingWindow()
        window.win_delegate = delegate
        let otherScene = NSObject()

        post(UIScene.willDeactivateNotification, for: otherScene)
        post(UIScene.didEnterBackgroundNotification, for: otherScene)
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didEnterBackgroundNotification)
        #expect(delegate.take().isEmpty)
    }

    /// An app with no scene manifest: its window is made from a frame, and
    /// goes as the app.
    @Test func aWindowWithoutASceneGoesAsTheApp() {
        let window = PlatformWindow<PhaseRecordingWindow>(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let delegate = PhaseRecordingWindow()
        window.win_delegate = delegate
        #expect(delegate.take().isEmpty)

        post(UIApplication.willResignActiveNotification)
        #expect(delegate.take() == ["inactive"])
        post(UIApplication.didEnterBackgroundNotification)
        #expect(delegate.take() == ["background"])
        post(UIApplication.willEnterForegroundNotification)
        #expect(delegate.take() == ["inactive"])
        post(UIApplication.didBecomeActiveNotification)
        #expect(delegate.take() == ["active"])
    }

    @Test func aPhaseIsToldOnce() throws {
        let scene = try scene()
        let window = PlatformWindow<PhaseRecordingWindow>(windowScene: scene)
        let delegate = PhaseRecordingWindow()
        window.win_delegate = delegate

        post(UIScene.didActivateNotification, for: scene)
        #expect(delegate.take().isEmpty)
        post(UIScene.willDeactivateNotification, for: scene)
        post(UIScene.willDeactivateNotification, for: scene)
        #expect(delegate.take() == ["inactive"])
        post(UIScene.didActivateNotification, for: scene)
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
final class PhaseRecordingWindow: NucleantWindow, WindowTouchDelegate {
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
