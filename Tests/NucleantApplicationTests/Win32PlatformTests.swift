//
//  Win32PlatformTests.swift
//  NucleantApplicationTests
//
//  Platform_Windows and the Windows app lifecycle (Windows only), on real
//  Win32 windows: input goes to the window procedure as the messages Windows
//  itself sends, and the event loop is turned by hand. The windows are never
//  shown, so the tests run without a desktop (over SSH, on CI). Only the
//  render test needs a Vulkan driver.
//
#if os(Windows)
import Testing
import WinSDK
import CVulkan
import NucleantVulkan
import NucleantWindow
@testable import NucleantApplication
@testable import Platform_Windows

@Suite(.serialized)
@MainActor
struct Win32PlatformTests {

    // MARK: Keys

    @Test func keyCodesAreTheMacOSVirtualKeyCodes() {
        let expected: [(scanCode: UInt32, extended: Bool, keyCode: UInt16)] = [
            (0x1E, false, 0x00), (0x2C, false, 0x06), (0x0B, false, 0x1D), // A Z 0
            (0x1C, false, 0x24), (0x0F, false, 0x30), (0x39, false, 0x31), // Return Tab Space
            (0x0E, false, 0x33), (0x01, false, 0x35), (0x1C, true, 0x4C), // Backspace Escape KeypadEnter
            (0x4B, true, 0x7B), (0x4D, true, 0x7C), (0x50, true, 0x7D), (0x48, true, 0x7E), // arrows
            (0x47, true, 0x73), (0x4F, true, 0x77), (0x49, true, 0x74), (0x51, true, 0x79), // Home End PageUp PageDown
            (0x47, false, 0x59), (0x53, true, 0x75), (0x1D, false, 0x3B), (0x1D, true, 0x3E), // Keypad7 Delete Controls
        ]
        for key in expected {
            #expect(Win32KeyMap.keyCode(scanCode: key.scanCode, extended: key.extended) == key.keyCode,
                    "scan code \(String(key.scanCode, radix: 16)) extended \(key.extended)")
        }
        #expect(Win32KeyMap.keyCode(scanCode: 0x7F, extended: false) == Win32KeyMap.unknownKeyCode)
        // A virtual key with no scan code, as synthesized input can be.
        #expect(Win32KeyMap.keyCode(lParam: 0, virtualKey: UInt32(VK_LEFT)) == 0x7B)
    }

    @Test func charactersAreTheTypedTextOrAppKitsCharacter() {
        func characters(_ units: [UInt16], _ keyCode: UInt16) -> String? {
            Win32KeyMap.characters(typed: units, keyCode: keyCode, virtualKey: 0, scanCode: 0)
        }
        #expect(characters([0x61], 0x00) == "a")
        #expect(characters([0xD83D, 0xDE00], Win32KeyMap.unknownKeyCode) == "😀")
        #expect(characters([0x08], 0x33) == "\u{7F}")
        #expect(characters([], 0x7B) == "\u{F702}")
        #expect(characters([], 0x24) == "\r")
        #expect(characters([], 0x38) == nil)
    }

    @Test func ctrlLettersReportTheLetterAsCommandDoes() throws {
        try withKeysHeld([VK_CONTROL, VK_LCONTROL]) {
            // Ctrl+A types SOH; with Ctrl as the command key it reads as "a".
            #expect(Win32KeyMap.characters(typed: [0x01], keyCode: 0x00, virtualKey: 0x41, scanCode: 0x1E) == "a")
        }
    }

    // MARK: Windows

    @Test func windowHasTheRequestedSizeInPoints() throws {
        let (window, _) = try openWindow(width: 320, height: 200)
        defer { window.close() }
        let scale = Double(GetDpiForWindow(window.win32Window)) / 96
        #expect(window.scale == scale)
        #expect(abs(window.width - 320) <= 1 / scale)
        #expect(abs(window.height - 200) <= 1 / scale)
        #expect(window.bufferWidth == UInt32((320 * scale).rounded()))
        #expect(window.bufferHeight == UInt32((200 * scale).rounded()))
        #expect(IsWindow(window.win32Window))
        #expect(window.win32Instance == GetModuleHandleW(nil))
    }

    @Test func mouseEventsReachTheDelegateInPoints() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        let hwnd = window.win32Window
        let s = window.scale

        SendMessageW(hwnd, UINT(WM_MOUSEMOVE), 0, pixels(10, 20))
        SendMessageW(hwnd, UINT(WM_LBUTTONDOWN), WPARAM(MK_LBUTTON), pixels(11, 21))
        #expect(GetCapture() == hwnd)
        SendMessageW(hwnd, UINT(WM_MOUSEMOVE), WPARAM(MK_LBUTTON), pixels(30, 40))
        // Dragged out past the window's left edge, as capture reports it.
        SendMessageW(hwnd, UINT(WM_MOUSEMOVE), WPARAM(MK_LBUTTON), pixels(-5, 40))
        SendMessageW(hwnd, UINT(WM_LBUTTONUP), 0, pixels(-5, 40))
        #expect(GetCapture() == nil)
        SendMessageW(hwnd, UINT(WM_RBUTTONDOWN), WPARAM(MK_RBUTTON), pixels(5, 6))
        SendMessageW(hwnd, UINT(WM_RBUTTONUP), 0, pixels(5, 6))

        #expect(delegate.events == [
            "moved \(10 / s) \(20 / s)",
            "down \(11 / s) \(21 / s)",
            "dragged \(30 / s) \(40 / s)",
            "dragged \(-5 / s) \(40 / s)",
            "up \(-5 / s) \(40 / s)",
            "rightDown \(5 / s) \(6 / s)",
            "rightUp \(5 / s) \(6 / s)",
        ])
    }

    @Test func wheelScrollsByTheSystemsLinesPerNotch() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        var lines: UINT = 3
        SystemParametersInfoW(UINT(SPI_GETWHEELSCROLLLINES), 0, &lines, 0)
        let notch = Double(lines) * 16

        // A notch away from the user (up), half a notch toward, a tilt right.
        SendMessageW(window.win32Window, UINT(WM_MOUSEWHEEL), wheel(120), 0)
        SendMessageW(window.win32Window, UINT(WM_MOUSEWHEEL), wheel(-60), 0)
        SendMessageW(window.win32Window, UINT(WM_MOUSEHWHEEL), wheel(120), 0)
        #expect(delegate.events == [
            "scroll 0.0 \(notch)",
            "scroll 0.0 \(-notch / 2)",
            "scroll \(-notch) 0.0",
        ])
    }

    @Test func keysTypedThroughTheLoopCarryTheirCharacters() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        let hwnd = window.win32Window

        // Posted, as the keyboard's are: the loop's TranslateMessage types
        // the character, and the key-down carries it.
        PostMessageW(hwnd, UINT(WM_KEYDOWN), WPARAM(0x41), keyMessage(scanCode: 0x1E))
        PostMessageW(hwnd, UINT(WM_KEYUP), WPARAM(0x41), keyMessage(scanCode: 0x1E, up: true))
        PostMessageW(hwnd, UINT(WM_KEYDOWN), WPARAM(VK_LEFT), keyMessage(scanCode: 0x4B, extended: true))
        PostMessageW(hwnd, UINT(WM_KEYUP), WPARAM(VK_LEFT), keyMessage(scanCode: 0x4B, extended: true, up: true))
        PostMessageW(hwnd, UINT(WM_KEYDOWN), WPARAM(VK_BACK), keyMessage(scanCode: 0x0E))
        Win32EventLoop.shared.pumpEvents()

        #expect(delegate.events == [
            "keyDown 0 a", "keyUp 0 a",
            "keyDown 123 \u{F702}", "keyUp 123 \u{F702}",
            "keyDown 51 \u{7F}",
        ])
    }

    @Test func aCloseRequestGoesToOnClose() throws {
        let (window, _) = try openWindow()
        defer { window.close() }
        var asked = 0
        window.on_close = { asked += 1 }
        SendMessageW(window.win32Window, UINT(WM_CLOSE), 0, 0)
        #expect(asked == 1)
        #expect(IsWindow(window.win32Window))
    }

    @Test func withoutOnCloseACloseRequestDestroysTheWindow() throws {
        let (window, delegate) = try openWindow()
        let hwnd = window.win32Window
        SendMessageW(hwnd, UINT(WM_CLOSE), 0, 0)
        #expect(!IsWindow(hwnd))
        #expect(Win32EventLoop.shared.window(for: hwnd) == nil)
        // Nothing reaches the delegate of a window that's gone.
        Win32EventLoop.shared.tick()
        #expect(delegate.frames.isEmpty)
    }

    @Test func resizingReportsTheNewSizeInPoints() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        let hwnd = window.win32Window
        let dpi = GetDpiForWindow(hwnd)
        var rect = RECT(left: 0, top: 0, right: 400, bottom: 300)
        AdjustWindowRectExForDpi(&rect, DWORD(WS_OVERLAPPEDWINDOW), false, 0, dpi)
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))

        let s = window.scale
        #expect(delegate.events == ["size \(400 / s) \(300 / s)"])
        #expect(window.bufferWidth == 400)
        #expect(window.bufferHeight == 300)
    }

    // MARK: Frames

    @Test func framesTickWindowsAndObserversOffTheLoop() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        var observed: [Double] = []
        let observer = FrameLoopTurn.add { observed.append($0) }
        defer { FrameLoopTurn.remove(observer) }

        Win32EventLoop.shared.tick()
        Win32EventLoop.shared.tick()
        #expect(observed.count == 2)
        #expect(observed[1] >= observed[0])
        #expect(delegate.frames.count == 2)
        // The first frame has nothing before it, so it gets one frame's time.
        #expect(abs(delegate.frames[0] - 1.0 / 60.0) < 1e-9)
        #expect(delegate.frames[1] >= 0)

        window.stopFrameLoop()
        Win32EventLoop.shared.tick()
        #expect(delegate.frames.count == 2)
    }

    @Test func aMinimizedWindowGetsNoFrames() throws {
        let (window, delegate) = try openWindow()
        defer { window.close() }
        window.minimize()
        #expect(IsIconic(window.win32Window))
        Win32EventLoop.shared.tick()
        #expect(delegate.frames.isEmpty)
    }

    // MARK: Menu bar

    @Test func installedCommandsAreEveryWindowsMenuBar() throws {
        defer { Win32EventLoop.shared.installMenu(nil) }
        let (before, _) = try openWindow()
        defer { before.close() }

        var ran: [String] = []
        let disabled = MenuBar.Command(title: "Disabled", isEnabled: false) { ran.append("disabled") }
        let menuBar = MenuBar(
            menus: [
                MenuBar.Menu(title: "Tools & More", items: [
                    .command(MenuBar.Command(title: "Run", shortcut: MenuBar.Shortcut("r")) { ran.append("run") }),
                    .divider,
                    .command(disabled),
                ]),
            ],
            groups: [
                MenuBar.Group(.appInfo, position: .replacing, items: [
                    .command(MenuBar.Command(title: "About") { ran.append("about") }),
                ]),
            ]
        )
        let host = Win32MenuBar()
        host.install(menuBar)
        let (after, delegate) = try openWindow()
        defer { after.close() }

        // Both windows, the one made before the install and the one after.
        for window in [before, after] {
            let bar = try #require(GetMenu(window.win32Window))
            // File, the app's menu, Help: Edit and Window have nothing in them.
            #expect(menuTitles(bar) == ["&File", "Tools && More", "&Help"])
            let tools = try #require(GetSubMenu(bar, 1))
            #expect(menuTitles(tools) == ["Run\tCtrl+R", "", "Disabled"])
            #expect(menuTitles(try #require(GetSubMenu(bar, 0))) == ["Close\tCtrl+W", "", "Exit"])
        }
        // The content keeps the size it asked for, with the menu bar outside it.
        #expect(abs(after.height - 80) <= 1 / after.scale)

        let bar = try #require(GetMenu(after.win32Window))
        let tools = try #require(GetSubMenu(bar, 1))
        let run = GetMenuItemID(tools, 0)
        let disabledID = GetMenuItemID(tools, 2)

        // Chosen from the menu.
        SendMessageW(after.win32Window, UINT(WM_COMMAND), WPARAM(run), 0)
        SendMessageW(after.win32Window, UINT(WM_COMMAND), WPARAM(disabledID), 0)
        #expect(ran == ["run"])

        // Greyed while disabled, enabled once the command is: read as the
        // menu opens.
        SendMessageW(after.win32Window, UINT(WM_INITMENUPOPUP), WPARAM(UInt(bitPattern: tools)), 0)
        #expect(GetMenuState(tools, disabledID, UINT(MF_BYCOMMAND)) & UINT(MF_GRAYED) != 0)
        disabled.isEnabled = true
        SendMessageW(after.win32Window, UINT(WM_INITMENUPOPUP), WPARAM(UInt(bitPattern: tools)), 0)
        #expect(GetMenuState(tools, disabledID, UINT(MF_BYCOMMAND)) & UINT(MF_GRAYED) == 0)

        // Its shortcut, pressed: the command runs, and the key goes no further.
        try withKeysHeld([VK_CONTROL, VK_LCONTROL]) {
            PostMessageW(after.win32Window, UINT(WM_KEYDOWN), WPARAM(0x52), keyMessage(scanCode: 0x13))
            Win32EventLoop.shared.pumpEvents()
        }
        #expect(ran == ["run", "run"])
        #expect(!delegate.events.contains { $0.hasPrefix("keyDown") })
    }

    // MARK: Appearance

    @Test func anUnchangedAppModeNotifiesNobody() throws {
        let (window, _) = try openWindow()
        defer { window.close() }
        let scheme = WindowsAppearance.colorScheme()
        var seen: [WindowsColorScheme] = []
        let observer = WindowsAppearance.addObserver { seen.append($0) }
        defer { WindowsAppearance.removeObserver(observer) }

        // What Windows broadcasts when the app mode is switched.
        "ImmersiveColorSet".withCString(encodedAs: UTF16.self) { area in
            _ = SendMessageW(window.win32Window, UINT(WM_SETTINGCHANGE), 0, LPARAM(Int(bitPattern: area)))
        }
        #expect(seen.isEmpty)
        #expect(WindowsAppearance.colorScheme() == scheme)
    }

    // MARK: App lifecycle

    @Test func runStartsTheAppAndReturnsWhenItsLastWindowCloses() throws {
        // Should the close never arrive, a timer ends the loop instead of the
        // test hanging; it is then too late to pass.
        let safety = SetTimer(nil, 0, 5000) { _, _, _, _ in Win32EventLoop.shared.stop() }
        defer { KillTimer(nil, safety) }
        let started = win32MonotonicSeconds()

        let app = TestApp()
        app.setup()
        try app.run()

        #expect(app.started)
        #expect(win32MonotonicSeconds() - started < 4)
        #expect(app.window.map { !IsWindow($0.win32Window) } == true)
    }

    // MARK: Rendering

    @Test(.enabled(if: VulkanDriver.isAvailable, "no Vulkan driver"))
    func engineRendersOnThePlatformWindow() throws {
        let (window, delegate) = try openWindow(width: 160, height: 120)
        defer { window.close() }
        let engine = try VulkanRenderEngine<TestSlot>(
            win32Instance: window.win32Instance,
            win32Window: window.win32Window,
            getExtent: { [unowned window] in VkExtent2D(width: window.bufferWidth, height: window.bufferHeight) }
        )
        delegate.renderEngine = engine
        let node = try engine.makePixelBufferNode(width: 8, height: 8)
        node.write(rgba: [UInt32](repeating: 0xFF00_80FF, count: 64))
        engine.append(TestSlot(id: 1, context: .pixels(node)))

        for _ in 0..<3 {
            engine.drawFrame(1.0 / 60.0)
        }
        #expect(engine.readable.contains(1))
    }

    // MARK: Helpers

    private func openWindow(width: Int = 100, height: Int = 80) throws -> (PlatformWindow<RecordingWindow>, RecordingWindow) {
        let window = try PlatformWindow<RecordingWindow>(width: width, height: height, title: "events")
        let delegate = RecordingWindow()
        window.win_delegate = delegate
        // Kept alive for the test by the returned tuple.
        return (window, delegate)
    }

    /// A mouse message's position: client pixels, signed 16-bit each.
    private func pixels(_ x: Int16, _ y: Int16) -> LPARAM {
        LPARAM(Int(UInt16(bitPattern: x)) | Int(UInt16(bitPattern: y)) << 16)
    }

    /// A wheel message's `wParam`: the signed delta in the high word.
    private func wheel(_ delta: Int16) -> WPARAM {
        WPARAM(UInt16(bitPattern: delta)) << 16
    }

    /// A key message's `lParam`: a repeat count of 1, the scan code, the
    /// extended flag, and for a release the previous-state and transition
    /// bits.
    private func keyMessage(scanCode: UInt32, extended: Bool = false, up: Bool = false) -> LPARAM {
        var value = 1 | Int(scanCode) << 16
        if extended { value |= 1 << 24 }
        if up { value |= 3 << 30 }
        return LPARAM(value)
    }

    /// Runs `body` with `keys` down in this thread's keyboard state — which
    /// `GetKeyState` reads, and posted messages leave alone — then puts the
    /// state back.
    private func withKeysHeld(_ keys: [Int32], _ body: () throws -> Void) throws {
        var original = [UInt8](repeating: 0, count: 256)
        try #require(GetKeyboardState(&original))
        var held = original
        for key in keys { held[Int(key)] = 0x80 }
        SetKeyboardState(&held)
        defer { SetKeyboardState(&original) }
        try body()
    }

    private func menuTitles(_ menu: HMENU) -> [String] {
        (0..<GetMenuItemCount(menu)).map { position in
            var buffer = [WCHAR](repeating: 0, count: 128)
            let length = GetMenuStringW(menu, UINT(position), &buffer, Int32(buffer.count), UINT(MF_BYPOSITION))
            return String(decoding: buffer[..<Int(max(length, 0))], as: UTF16.self)
        }
    }
}

// MARK: - Test doubles

@MainActor
final class TestApp: NucleantApplication {
    var appDelegate: AppDelegate<TestApp>?
    var started = false
    var window: PlatformWindow<RecordingWindow>?
    let delegate = RecordingWindow()

    /// Opens a window and asks it to close, as its ✕ would: with no
    /// `on_close`, that ends the loop.
    func onStart() {
        started = true
        window = try? PlatformWindow(width: 100, height: 80, title: "lifecycle")
        window?.win_delegate = delegate
        if let window {
            PostMessageW(window.win32Window, UINT(WM_CLOSE), 0, 0)
        }
    }
}

/// The engine's composite slot for one pixel buffer.
final class TestSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case pixels(PixelBufferShaderNode<TestSlot>)
    }

    let id: Int
    let context: Context
    var needsRender = true

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {
        if case .pixels(let node) = context { observe(node) }
    }

    func update(engine: Engine, cmd: VkCommandBuffer) {
        if case .pixels(let node) = context { node.update(engine, slot: self, cmd: cmd) }
    }

    func destroyResources(engine: Engine) {
        if case .pixels(let node) = context { node.destroyResources(engine) }
    }

    func getImageView() -> VkImageView? {
        if case .pixels(let node) = context { return node.imageView }
        return nil
    }
}

final class RecordingWindow: NucleantWindow, Win32WindowDelegate {
    typealias Node = TestSlot

    var renderEngine: VulkanRenderEngine<TestSlot>?
    var win_rect: SIMD4<Int> = .init(0, 0, 100, 80)
    var events: [String] = []
    var frames: [Double] = []

    private func record(_ name: String, _ values: Double...) {
        events.append(([name] + values.map { "\($0)" }).joined(separator: " "))
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
    func on_key_down(keyCode: UInt16, characters: String?) { events.append("keyDown \(keyCode) \(characters ?? "nil")") }
    func on_key_up(keyCode: UInt16, characters: String?) { events.append("keyUp \(keyCode) \(characters ?? "nil")") }
    func on_touch_down(id: Int, x: Double, y: Double) { record("touchDown", Double(id), x, y) }
    func on_touch_moved(id: Int, x: Double, y: Double) { record("touchMoved", Double(id), x, y) }
    func on_touch_up(id: Int, x: Double, y: Double) { record("touchUp", Double(id), x, y) }
    func on_touch_cancelled(id: Int, x: Double, y: Double) { record("touchCancelled", Double(id), x, y) }
}

/// Whether the loader finds a Vulkan driver at all — a CI machine without a
/// GPU has none unless one is installed.
enum VulkanDriver {
    static let isAvailable: Bool = {
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        var created: VkInstance?
        let result = withUnsafePointer(to: &appInfo) { app in
            var info = VkInstanceCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
            info.pApplicationInfo = app
            return vkCreateInstance(&info, nil, &created)
        }
        guard result == VK_SUCCESS, let instance = created else { return false }
        defer { vkDestroyInstance(instance, nil) }
        var count: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &count, nil)
        return count > 0
    }()
}
#endif
