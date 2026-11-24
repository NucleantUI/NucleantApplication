//
//  LinuxPlatformTests.swift
//  NucleantApplicationTests
//
//  Platform_Linux (Linux only), on real X11 windows under a real window
//  manager: the phase a window tells its delegate as the window manager
//  minimizes it, shows another workspace or moves it to one, and brings it
//  back — and the phase it keeps as it loses the keys or the app hides it.
//  The event loop is turned by hand.
//
//  Needs an X11 display with an EWMH window manager that minimizes windows
//  (Xvfb with Openbox will do), and for the workspace tests two workspaces.
//  Without them there is nothing to check, and the tests pass.
//
#if os(Linux)
import Testing
import Foundation
import CVulkan
import CXCB
import NucleantVulkan
import NucleantWindow
@testable import Platform_Linux

@Suite(.serialized)
@MainActor
struct LinuxPlatformTests {

    // MARK: Phase

    @Test func aMinimizedWindowIsInTheBackgroundUntilItIsBack() throws {
        guard case let (window, delegate)? = try openWindow() else { return }
        defer { window.close() }

        window.minimize()
        pump { delegate.hasPhases }
        #expect(delegate.take() == ["background"])

        window.activate()
        pump { delegate.hasPhases }
        #expect(delegate.take() == ["active"])
    }

    @Test func aPhaseIsToldOnce() throws {
        guard case let (window, delegate)? = try openWindow() else { return }
        defer { window.close() }

        window.minimize()
        pump { delegate.hasPhases }
        window.minimize()
        pump(for: 0.5)
        #expect(delegate.take() == ["background"])

        window.activate()
        pump { delegate.hasPhases }
        window.activate()
        pump(for: 0.5)
        #expect(delegate.take() == ["active"])
    }

    @Test func aWindowOnAWorkspaceNotShownIsInTheBackground() throws {
        guard workspaceCount >= 2, case let (window, delegate)? = try openWindow() else { return }
        defer { window.close() }
        let shown = currentWorkspace

        showWorkspace(shown == 0 ? 1 : 0)
        pump { delegate.hasPhases }
        #expect(delegate.take() == ["background"])

        showWorkspace(shown)
        pump { delegate.hasPhases }
        #expect(delegate.take() == ["active"])
    }

    @Test func aWindowMovedToAnotherWorkspaceIsInTheBackgroundUntilItIsBack() throws {
        guard workspaceCount >= 2, case let (window, delegate)? = try openWindow() else { return }
        defer { window.close() }
        let shown = currentWorkspace

        move(window, toWorkspace: shown == 0 ? 1 : 0)
        pump { delegate.hasPhases }
        #expect(delegate.take() == ["background"])

        move(window, toWorkspace: shown)
        pump { delegate.hasPhases }
        #expect(delegate.take() == ["active"])
    }

    @Test func aWindowWithoutTheKeysIsActive() throws {
        guard case let (window, delegate)? = try openWindow() else { return }
        defer { window.close() }
        window.activate()
        pump(for: 0.3)
        var deactivated = false
        window.on_deactivate = { deactivated = true }

        guard case let (other, _)? = try openWindow() else { return }
        defer { other.close() }
        other.activate()
        pump { deactivated }
        #expect(deactivated)
        pump(for: 0.3)
        #expect(delegate.take().isEmpty)
    }

    @Test func aWindowTheAppHidesKeepsItsPhase() throws {
        guard case let (window, delegate)? = try openWindow() else { return }
        defer { window.close() }

        window.hide()
        pump(for: 0.5)
        #expect(!isViewable(window))
        #expect(delegate.take().isEmpty)

        window.show()
        pump { isViewable(window) }
        pump(for: 0.3)
        #expect(delegate.take().isEmpty)
    }

    // MARK: Helpers

    /// A shown window and the phases it reports, or nil where there is no
    /// X11 display with a window manager to show it on.
    private func openWindow() throws -> (PlatformWindow<LinuxPhaseWindow>, LinuxPhaseWindow)? {
        guard hasWindowManager else {
            print("No X11 window manager to test against")
            return nil
        }
        let window = try PlatformWindow<LinuxPhaseWindow>(width: 160, height: 120, title: "LinuxPlatformTests")
        let delegate = LinuxPhaseWindow()
        window.win_delegate = delegate
        window.show()
        pump { isViewable(window) }
        // The window manager's own work on a new window — decorating,
        // placing, focusing it — done before the test starts.
        pump(for: 0.3)
        _ = delegate.take()
        return (window, delegate)
    }

    /// An X11 session with an EWMH window manager that minimizes windows
    /// and activates them on request.
    private var hasWindowManager: Bool {
        guard LinuxSession.detect() == .x11, (try? X11Display.shared.connect()) != nil else { return false }
        let display = X11Display.shared
        let supported = display.atoms(display.atom("_NET_SUPPORTED"), of: display.rootWindow)
        return supported.contains(display.atom("_NET_ACTIVE_WINDOW"))
            && supported.contains(display.atom("_NET_WM_STATE_HIDDEN"))
    }

    private var workspaceCount: Int {
        guard hasWindowManager else { return 0 }
        let display = X11Display.shared
        return Int(display.cardinals(display.atom("_NET_NUMBER_OF_DESKTOPS"), of: display.rootWindow).first ?? 0)
    }

    private var currentWorkspace: UInt32 {
        let display = X11Display.shared
        return display.cardinals(display.atom("_NET_CURRENT_DESKTOP"), of: display.rootWindow).first ?? 0
    }

    /// Turn the event loop until `done` holds, for at most `timeout`
    /// seconds.
    private func pump(until done: () -> Bool, timeout: Double = 5) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done(), Date() < deadline {
            X11Display.shared.pumpEvents(timeoutMilliseconds: 10)
        }
    }

    /// Turn it for `seconds`, for what should not happen meanwhile.
    private func pump(for seconds: Double) {
        pump(until: { false }, timeout: seconds)
    }

    private func isViewable(_ window: PlatformWindow<LinuxPhaseWindow>) -> Bool {
        guard case .xcb(let connection?, let handle) = window.vulkanSurfaceKind,
              let reply = xcb_get_window_attributes_reply(connection, xcb_get_window_attributes(connection, handle), nil)
        else { return false }
        defer { free(reply) }
        return UInt32(reply.pointee.map_state) == XCB_MAP_STATE_VIEWABLE.rawValue
    }

    /// Asks the window manager to show `workspace`, as a pager does.
    private func showWorkspace(_ workspace: UInt32) {
        sendToWindowManager("_NET_CURRENT_DESKTOP", window: X11Display.shared.rootWindow, data: (workspace, 0, 0, 0, 0))
    }

    /// Asks the window manager to move `window` to `workspace`, as a pager
    /// does.
    private func move(_ window: PlatformWindow<LinuxPhaseWindow>, toWorkspace workspace: UInt32) {
        guard case .xcb(_, let handle) = window.vulkanSurfaceKind else { return }
        sendToWindowManager("_NET_WM_DESKTOP", window: handle, data: (workspace, 2, 0, 0, 0))
    }

    private func sendToWindowManager(_ message: String, window: xcb_window_t,
                                     data: (UInt32, UInt32, UInt32, UInt32, UInt32)) {
        let display = X11Display.shared
        guard let connection = display.connectionHandle else { return }
        var event = xcb_client_message_event_t()
        event.response_type = UInt8(XCB_CLIENT_MESSAGE)
        event.format = 32
        event.window = window
        event.type = display.atom(message)
        event.data.data32 = data
        withUnsafePointer(to: &event) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<xcb_client_message_event_t>.size) {
                _ = xcb_send_event(
                    connection, 0, display.rootWindow,
                    XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT.rawValue | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY.rawValue,
                    $0
                )
            }
        }
        _ = xcb_flush(connection)
    }
}

/// A composite slot the test window never fills: the platform window is
/// tested without an engine.
final class LinuxTestSlot: RenderContainerNode, @unchecked Sendable {
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
final class LinuxPhaseWindow: NucleantWindow, WaylandWindowDelegate {
    var renderEngine: VulkanRenderEngine<LinuxTestSlot>?
    var win_rect: SIMD4<Int> = .init(0, 0, 160, 120)
    private var phases: [String] = []

    var hasPhases: Bool { !phases.isEmpty }

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
