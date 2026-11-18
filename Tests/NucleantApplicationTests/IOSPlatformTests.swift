//
//  IOSPlatformTests.swift
//  NucleantApplicationTests
//
//  Platform_iOS (iOS only): the phase a window tells its delegate as its
//  scene, or the app, goes to the background and back; and the keys it
//  tells it, from a hardware keyboard and from the on-screen one.
//
//  The test process is not an app — it has no `UIApplication` and connects
//  no scenes — so UIKit's notifications are posted by hand, as UIKit posts
//  them. The scene is the one UIKit gives a window made without one; it is
//  in the foreground and active. Nothing becomes first responder here, so
//  no keyboard comes up, and a `UIPress` can't be made: the on-screen
//  keyboard's calls are made on the view it types into, as UIKit makes them.
//
#if os(iOS)
import Testing
import UIKit
import CVulkan
import NucleantVulkan
import NucleantWindow
@testable import Platform_iOS

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

@Suite(.serialized)
@MainActor
struct IOSKeyTests {

    /// A window with a delegate, and the view its on-screen keyboard types
    /// into.
    private func makeWindow() throws -> (PlatformWindow<KeyRecordingWindow>, KeyRecordingWindow, UIKeyInput) {
        let window = PlatformWindow<KeyRecordingWindow>(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let delegate = KeyRecordingWindow()
        window.win_delegate = delegate
        let input = try #require(window.rootViewController?.view.subviews.lazy.compactMap { $0 as? UIKeyInput }.first)
        return (window, delegate, input)
    }

    /// A hardware key's HID usage is reported as its macOS key code, the
    /// code every window reports keys in.
    @Test func hardwareKeysAreMacOSKeyCodes() {
        let codes: [(UIKeyboardHIDUsage, UInt16)] = [
            (.keyboardA, 0x00), (.keyboardS, 0x01), (.keyboardZ, 0x06), (.keyboardQ, 0x0C),
            (.keyboard1, 0x12), (.keyboard5, 0x17), (.keyboard9, 0x19), (.keyboard0, 0x1D),
            (.keyboardReturnOrEnter, 0x24), (.keypadEnter, 0x4C),
            (.keyboardDeleteOrBackspace, 0x33), (.keyboardDeleteForward, 0x75),
            (.keyboardTab, 0x30), (.keyboardEscape, 0x35), (.keyboardSpacebar, 0x31),
            (.keyboardLeftArrow, 0x7B), (.keyboardRightArrow, 0x7C),
            (.keyboardDownArrow, 0x7D), (.keyboardUpArrow, 0x7E),
            (.keyboardHome, 0x73), (.keyboardEnd, 0x77),
            (.keyboardPageUp, 0x74), (.keyboardPageDown, 0x79),
            (.keyboardHyphen, 0x1B), (.keyboardEqualSign, 0x18),
            (.keyboardOpenBracket, 0x21), (.keyboardCloseBracket, 0x1E),
            (.keyboardBackslash, 0x2A), (.keyboardNonUSPound, 0x2A), (.keyboardNonUSBackslash, 0x0A),
            (.keyboardSemicolon, 0x29), (.keyboardQuote, 0x27), (.keyboardGraveAccentAndTilde, 0x32),
            (.keyboardComma, 0x2B), (.keyboardPeriod, 0x2F), (.keyboardSlash, 0x2C),
            (.keyboardF1, 0x7A), (.keyboardF5, 0x60), (.keyboardF12, 0x6F),
            (.keypad1, 0x53), (.keypad7, 0x59), (.keypad8, 0x5B), (.keypad0, 0x52),
            (.keypadSlash, 0x4B), (.keypadAsterisk, 0x43), (.keypadHyphen, 0x4E), (.keypadPlus, 0x45),
            (.keypadPeriod, 0x41), (.keypadEqualSign, 0x51),
            (.keyboardLeftShift, 0x38), (.keyboardRightGUI, 0x36),
        ]
        for (usage, code) in codes {
            #expect(usage.windowKeyCode == code, "HID \(usage.rawValue)")
        }
        #expect(UIKeyboardHIDUsage.keyboardErrorRollOver.windowKeyCode == 0xFFFF)
    }

    @Test func modifierKeysAreNotPresses() {
        let modifiers: [UIKeyboardHIDUsage] = [
            .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
            .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
            .keyboardCapsLock,
        ]
        for usage in modifiers {
            #expect(usage.isModifier, "HID \(usage.rawValue)")
        }
        for usage in [UIKeyboardHIDUsage.keyboardA, .keyboardSpacebar, .keyboardTab, .keyboardF1] {
            #expect(!usage.isModifier, "HID \(usage.rawValue)")
        }
    }

    /// Each character the on-screen keyboard types is a press of its own:
    /// a newline is Return, anything else an unknown key typing it.
    @Test func onScreenTextArrivesAsPresses() throws {
        let (_, delegate, input) = try makeWindow()
        input.insertText("a\n👍🏽")
        #expect(delegate.take() == [
            "down ffff a", "up ffff a",
            "down 24 \r", "up 24 \r",
            "down ffff 👍🏽", "up ffff 👍🏽",
        ])
        #expect(input.hasText)
        input.deleteBackward()
        #expect(delegate.take() == ["down 33 nil", "up 33 nil"])
    }

    // The view typed into can't become first responder here, so it is never
    // told to resign: what it tells the window when it is, is told directly.

    /// The keyboard put away from the keyboard: the window says so, once,
    /// and asks for no keyboard any more.
    @Test func aKeyboardPutAwayTellsTheDelegate() throws {
        let (window, delegate, _) = try makeWindow()
        window.textInputKind = .singleLine
        window.textInputViewResigned()
        #expect(delegate.take() == ["dismissed"])
        #expect(window.textInputKind == .none)
        window.textInputViewResigned()
        #expect(delegate.take().isEmpty)
    }

    /// The keyboard put away by asking for none is not news to the delegate.
    @Test func aKeyboardAskedAwayIsNotTold() throws {
        let (window, delegate, _) = try makeWindow()
        window.textInputKind = .multiLine
        window.textInputKind = .none
        window.textInputViewResigned()
        #expect(delegate.take().isEmpty)
        #expect(window.textInputKind == .none)
    }
}

/// Notes each key press and release, and the keyboard put away.
final class KeyRecordingWindow: NucleantWindow, WindowTouchDelegate {
    var renderEngine: VulkanRenderEngine<PhaseTestSlot>?
    var win_rect: SIMD4<Int> = .init(0, 0, 160, 120)
    private var events: [String] = []

    /// The events so far, emptying the record.
    func take() -> [String] {
        defer { events = [] }
        return events
    }

    func on_key_down(keyCode: UInt16, characters: String?) {
        events.append("down \(String(keyCode, radix: 16)) \(characters ?? "nil")")
    }

    func on_key_up(keyCode: UInt16, characters: String?) {
        events.append("up \(String(keyCode, radix: 16)) \(characters ?? "nil")")
    }

    func keyboardDismissed() { events.append("dismissed") }

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
