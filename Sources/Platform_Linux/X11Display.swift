//
//  X11Display.swift
//  NucleantApplication
//
//  The process-wide X11 connection: the display handshake, atom interning,
//  and the event loop — X11's counterpart of `WaylandDisplay`, used instead
//  of it when the session is X11 rather than Wayland (see
//  `LinuxSession.detect()`). Most Linux desktops (Cinnamon, MATE, XFCE, and
//  GNOME/KDE when not running their Wayland session) are still X11-only, so
//  this is what makes windows on those show up as normal, WM-managed
//  top-levels rather than requiring a Wayland compositor to exist at all.
//
#if os(Linux)
import CXCB
import Glibc

public enum X11Error: Error, CustomStringConvertible {
    /// No X server to talk to: `DISPLAY` unset, or the socket it names isn't
    /// there.
    case noDisplay
    case windowCreationFailed

    public var description: String {
        switch self {
        case .noDisplay:
            return "no X11 display: DISPLAY is unset or its socket is unreachable"
        case .windowCreationFailed:
            return "the X server refused to create the window"
        }
    }
}

/// Single-threaded by construction, same contract as `WaylandDisplay`:
/// everything here happens synchronously inside `pumpEvents` on whichever
/// thread calls `run()`.
public final class X11Display {

    public nonisolated(unsafe) static let shared = X11Display()

    // MARK: Connection

    public private(set) var connectionHandle: OpaquePointer?
    private(set) var screen: xcb_screen_t?
    private(set) var rootVisual: xcb_visualid_t = 0

    // MARK: Atoms

    private(set) var wmProtocolsAtom: xcb_atom_t = 0
    private(set) var wmDeleteWindowAtom: xcb_atom_t = 0
    private(set) var netWmNameAtom: xcb_atom_t = 0
    private(set) var utf8StringAtom: xcb_atom_t = 0

    /// Live windows, keyed by their `xcb_window_t`. Weak, same reasoning as
    /// `WaylandDisplay.surfaces` — a window's lifetime belongs to whoever
    /// created it.
    private var windows: [xcb_window_t: WeakWindow] = [:]
    private struct WeakWindow {
        weak var window: X11Window?
    }

    // MARK: Loop state

    private var running = false
    public private(set) var isTerminated = false

    private init() {}

    // MARK: - Connect

    public var isConnected: Bool { connectionHandle != nil }

    public func connect() throws {
        guard connectionHandle == nil else { return }

        var screenNumber: Int32 = 0
        guard let connection = xcb_connect(nil, &screenNumber) else {
            throw X11Error.noDisplay
        }
        if xcb_connection_has_error(connection) != 0 {
            xcb_disconnect(connection)
            throw X11Error.noDisplay
        }
        connectionHandle = connection

        guard let setup = xcb_get_setup(connection) else {
            xcb_disconnect(connection)
            connectionHandle = nil
            throw X11Error.noDisplay
        }
        var iter = xcb_setup_roots_iterator(setup)
        var index: Int32 = 0
        while index < screenNumber, iter.rem > 0 {
            xcb_screen_next(&iter)
            index += 1
        }
        guard let screenPtr = iter.data else {
            xcb_disconnect(connection)
            connectionHandle = nil
            throw X11Error.noDisplay
        }
        screen = screenPtr.pointee
        rootVisual = screenPtr.pointee.root_visual

        wmProtocolsAtom = internAtom(connection, "WM_PROTOCOLS")
        wmDeleteWindowAtom = internAtom(connection, "WM_DELETE_WINDOW")
        netWmNameAtom = internAtom(connection, "_NET_WM_NAME")
        utf8StringAtom = internAtom(connection, "UTF8_STRING")
    }

    private func internAtom(_ connection: OpaquePointer, _ name: String) -> xcb_atom_t {
        let cookie = name.utf8CString.withUnsafeBufferPointer { buf in
            xcb_intern_atom(connection, 0, UInt16(buf.count - 1), buf.baseAddress)
        }
        guard let reply = xcb_intern_atom_reply(connection, cookie, nil) else { return 0 }
        defer { free(reply) }
        return reply.pointee.atom
    }

    // MARK: - Window registry

    func register(_ window: X11Window, for handle: xcb_window_t) {
        windows[handle] = WeakWindow(window: window)
    }

    func unregister(_ handle: xcb_window_t) {
        windows.removeValue(forKey: handle)
    }

    /// Whether any window is still live — what `PlatformWindow`'s default
    /// close handler checks before stopping the event loop, so closing one of
    /// several open windows doesn't end the whole app.
    var hasNoLiveWindows: Bool { windows.isEmpty }

    private func window(for handle: xcb_window_t) -> X11Window? {
        guard let box = windows[handle] else { return nil }
        guard let window = box.window else {
            windows.removeValue(forKey: handle)
            return nil
        }
        return window
    }

    // MARK: - Event loop

    public func run() {
        running = true
        while running && !isTerminated {
            pumpEvents(timeoutMilliseconds: Self.pollTimeoutMilliseconds)
        }
        running = false
    }

    public func stop() {
        running = false
    }

    private static let pollTimeoutMilliseconds: Int32 = 8

    public func pumpEvents(timeoutMilliseconds: Int32 = 0) {
        guard let connection = connectionHandle, !isTerminated else { return }

        while let event = xcb_poll_for_event(connection) {
            handle(event)
            free(event)
        }
        if xcb_connection_has_error(connection) != 0 {
            terminate()
            return
        }
        _ = xcb_flush(connection)

        var fds = pollfd(fd: xcb_get_file_descriptor(connection), events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeoutMilliseconds)
        if ready < 0 {
            if errno != EINTR { terminate() }
            return
        }
        if ready > 0, (fds.revents & Int16(POLLHUP | POLLERR)) != 0 {
            terminate()
            return
        }

        tickWindows()
    }

    private func terminate() {
        isTerminated = true
        running = false
    }

    private func tickWindows() {
        let now = waylandMonotonicSeconds()
        for (handle, box) in windows {
            guard let window = box.window else {
                windows.removeValue(forKey: handle)
                continue
            }
            window.pumpFallbackTick(now: now)
        }
    }

    public func flush() {
        guard let connectionHandle else { return }
        _ = xcb_flush(connectionHandle)
    }

    // MARK: - Event dispatch

    private func handle(_ event: UnsafeMutablePointer<xcb_generic_event_t>) {
        let responseType = event.pointee.response_type & 0x7f
        switch Int32(responseType) {
        case XCB_CONFIGURE_NOTIFY:
            event.withMemoryRebound(to: xcb_configure_notify_event_t.self, capacity: 1) { e in
                window(for: e.pointee.window)?.handleConfigure(
                    width: Double(e.pointee.width), height: Double(e.pointee.height)
                )
            }

        case XCB_CLIENT_MESSAGE:
            event.withMemoryRebound(to: xcb_client_message_event_t.self, capacity: 1) { e in
                guard e.pointee.data.data32.0 == wmDeleteWindowAtom else { return }
                window(for: e.pointee.window)?.handler?.waylandSurfaceDidRequestClose()
            }

        case XCB_BUTTON_PRESS:
            event.withMemoryRebound(to: xcb_button_press_event_t.self, capacity: 1) { e in
                buttonEvent(e.pointee, pressed: true)
            }

        case XCB_BUTTON_RELEASE:
            event.withMemoryRebound(to: xcb_button_press_event_t.self, capacity: 1) { e in
                buttonEvent(e.pointee, pressed: false)
            }

        case XCB_MOTION_NOTIFY:
            event.withMemoryRebound(to: xcb_motion_notify_event_t.self, capacity: 1) { e in
                let location = SIMD2(Double(e.pointee.event_x), Double(e.pointee.event_y))
                guard let target = window(for: e.pointee.event), let handler = target.handler else { return }
                if e.pointee.state & 0x100 != 0 { // XCB_BUTTON_MASK_1 (left button held)
                    handler.waylandPointerDragged(at: location)
                } else {
                    handler.waylandPointerMoved(to: location)
                }
            }

        case XCB_KEY_PRESS:
            event.withMemoryRebound(to: xcb_key_press_event_t.self, capacity: 1) { e in
                keyEvent(e.pointee, pressed: true)
            }

        case XCB_KEY_RELEASE:
            event.withMemoryRebound(to: xcb_key_press_event_t.self, capacity: 1) { e in
                keyEvent(e.pointee, pressed: false)
            }

        case XCB_EXPOSE:
            break // frame ticks come from tickWindows(), not Expose

        default:
            break
        }
    }

    private func buttonEvent(_ e: xcb_button_press_event_t, pressed: Bool) {
        let location = SIMD2(Double(e.event_x), Double(e.event_y))
        guard let handler = window(for: e.event)?.handler else { return }
        switch UInt32(e.detail) {
        case 1: // left
            pressed ? handler.waylandPointerDown(at: location) : handler.waylandPointerUp(at: location)
        case 3: // right
            pressed ? handler.waylandRightPointerDown(at: location) : handler.waylandRightPointerUp(at: location)
        case 4: // scroll up
            if pressed { handler.waylandScrolled(dx: 0, dy: -1) }
        case 5: // scroll down
            if pressed { handler.waylandScrolled(dx: 0, dy: 1) }
        default:
            break
        }
    }

    private func keyEvent(_ e: xcb_key_press_event_t, pressed: Bool) {
        guard let handler = window(for: e.event)?.handler else { return }
        // X11 keycodes are evdev codes + 8 — subtract to reuse the same
        // evdev-keyed table Wayland's `wl_keyboard.key` already uses.
        let evdevCode = UInt32(e.detail) - 8
        let shift = e.state & 1 != 0        // ShiftMask
        let capsLock = e.state & 2 != 0     // LockMask
        let characters = LinuxKeyMap.characters(forKey: evdevCode, shift: shift, capsLock: capsLock)
        if pressed {
            handler.waylandKeyDown(key: UInt16(truncatingIfNeeded: evdevCode), chars: characters)
        } else {
            handler.waylandKeyUp(key: UInt16(truncatingIfNeeded: evdevCode), chars: characters)
        }
    }
}
#endif
