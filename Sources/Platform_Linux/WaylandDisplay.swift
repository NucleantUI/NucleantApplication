//
//  WaylandDisplay.swift
//  NucleantApplication
//
//  The process-wide Wayland connection: the compositor handshake, the seat's
//  input devices, and the event loop. This is Platform_Linux's answer to
//  `NSApplication` / `UIApplication` — the piece that exists once per process
//  and that every `PlatformWindow` hangs off, as opposed to the per-window
//  state in `WaylandSurface`.
//
#if os(Linux)
import CWayland
import Glibc

public enum WaylandError: Error, CustomStringConvertible {
    /// No compositor to talk to: `WAYLAND_DISPLAY` unset, or the socket it
    /// names isn't there. On a machine running X11 (or no session at all)
    /// this is the expected failure.
    case noCompositor
    /// The compositor connected fine but never advertised an interface we
    /// can't work without.
    case missingGlobal(String)
    /// wl_compositor/xdg_wm_base accepted the request but handed back
    /// nothing — protocol-level failure, not a configuration one.
    case surfaceCreationFailed

    public var description: String {
        switch self {
        case .noCompositor:
            return "no Wayland compositor: WAYLAND_DISPLAY is unset or its socket is unreachable"
        case .missingGlobal(let name):
            return "the compositor does not implement \(name)"
        case .surfaceCreationFailed:
            return "the compositor refused to create the window surface"
        }
    }
}

/// Wraps a listener struct in storage with a stable address.
///
/// `wl_proxy_add_listener` keeps the pointer it's handed and calls through it
/// for the proxy's whole life — it does not copy the struct. A Swift local
/// (or `withUnsafePointer` on a temporary) would dangle the moment the call
/// returns, so every listener in this module is allocated here and then owned
/// by whatever owns the proxy — `WaylandSurface.ListenerStorage` for the
/// per-window ones, and for the seat/registry listeners below, the process:
/// their proxies live as long as the connection does, so those allocations
/// are deliberately never freed.
func waylandListener<T>(_ value: T) -> UnsafeMutablePointer<T> {
    let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
    storage.initialize(to: value)
    return storage
}

/// Seconds on `CLOCK_MONOTONIC`. Frame timing has to come from a clock that
/// can't jump; wall time can.
func waylandMonotonicSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}

/// The connection to the compositor.
///
/// Single-threaded by construction: everything here — the C callbacks
/// libwayland invokes, the frame ticks, the delegate calls that come out the
/// far side — happens synchronously inside `pumpEvents` on whichever thread
/// runs the loop, which for an app driven by `AppDelegate.run()` is the main
/// thread. Nothing in this module is safe to touch from another one.
public final class WaylandDisplay {

    /// One connection per process, matching `NSApplication.shared`. Created
    /// on first use but *not* connected — call `connect()`.
    public nonisolated(unsafe) static let shared = WaylandDisplay()

    // MARK: Connection + globals

    /// `wl_display *`. Hand this to `vkCreateWaylandSurfaceKHR` along with a
    /// window's `surfaceHandle`.
    public private(set) var displayHandle: OpaquePointer?

    private var registry: OpaquePointer?
    /// `wl_compositor *` — makes wl_surfaces.
    private(set) var compositor: OpaquePointer?
    /// `xdg_wm_base *` — promotes a wl_surface to a desktop window.
    private(set) var wmBase: OpaquePointer?
    /// `zxdg_decoration_manager_v1 *`, when the compositor has one. Optional
    /// by design: GNOME doesn't implement it and windows simply come up
    /// without a server-drawn titlebar.
    private(set) var decorationManager: OpaquePointer?

    private var seat: OpaquePointer?
    private var pointer: OpaquePointer?
    private var keyboard: OpaquePointer?
    private var touch: OpaquePointer?

    /// Live windows, keyed by their `wl_surface *`. Input events name a
    /// surface, so this is how a compositor event finds its `PlatformWindow`.
    /// Weak: a window's lifetime belongs to whoever created it, and a dropped
    /// one has to fall out of here on its own.
    private var surfaces: [OpaquePointer: WeakSurface] = [:]

    private struct WeakSurface {
        weak var surface: WaylandSurface?
    }

    // MARK: Input state
    //
    // Wayland reports input against the *seat*, not the window: `motion`
    // carries no surface, only the coordinates, because the surface was
    // established by the preceding `enter`. So focus has to be tracked here
    // and each event routed to the surface that currently holds it.

    private var pointerFocus: OpaquePointer?
    private var pointerLocation = SIMD2<Double>(0, 0)
    /// Buttons currently held, as `BTN_*` codes — `motion` becomes a drag
    /// rather than a move while the left one is down, matching AppKit.
    private var pointerButtonsDown: Set<UInt32> = []
    /// `axis` events accumulate until the `frame` that ends the batch, so a
    /// diagonal scroll arrives as one `on_scroll` instead of two.
    private var pendingScroll = SIMD2<Double>(0, 0)

    private var keyboardFocus: OpaquePointer?
    /// The depressed-modifier mask from `wl_keyboard.modifiers`, used only to
    /// pick between the shifted and unshifted character for a key.
    private var modifierMask: UInt32 = 0
    private var lockedMask: UInt32 = 0

    /// Which surface each in-flight touch point started on, and where it was
    /// last seen — `wl_touch.up` carries neither, but the `on_touch_up` hook
    /// (like UIKit's) takes a location.
    private var touchFocus: [Int32: OpaquePointer] = [:]
    private var touchLocations: [Int32: SIMD2<Double>] = [:]

    // MARK: Loop state

    private var running = false
    /// Set when the compositor hangs up or the socket errors out; `run()`
    /// returns and further pumping is a no-op.
    public private(set) var isTerminated = false

    private init() {}

    // MARK: - Connect

    public var isConnected: Bool { displayHandle != nil }

    /// Connects and completes the handshake. Idempotent — calling it from
    /// every window's init is fine and only the first does work.
    public func connect() throws {
        guard displayHandle == nil else { return }

        guard let display = wl_display_connect(nil) else {
            throw WaylandError.noCompositor
        }
        displayHandle = display

        let registry = wl_display_get_registry(display)
        self.registry = registry
        wl_registry_add_listener(registry, Self.registryListener, selfPointer)

        // Two round trips, not one: the first delivers the `global` events and
        // so populates `compositor` / `wmBase` / `seat`; only then do the
        // objects bound during it exist to send their own events, and the
        // second collects those (the seat's `capabilities`, which is what
        // creates the pointer/keyboard/touch devices).
        wl_display_roundtrip(display)
        wl_display_roundtrip(display)

        guard compositor != nil else {
            throw WaylandError.missingGlobal("wl_compositor")
        }
        guard wmBase != nil else {
            // Without xdg-shell there is no way to ask for a *window* — only
            // a bare surface with no size negotiation and no close button.
            throw WaylandError.missingGlobal("xdg_wm_base")
        }
    }

    private var selfPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private static func display(_ data: UnsafeMutableRawPointer?) -> WaylandDisplay? {
        guard let data else { return nil }
        return Unmanaged<WaylandDisplay>.fromOpaque(data).takeUnretainedValue()
    }

    // MARK: - Surface registry

    func register(_ surface: WaylandSurface, for handle: OpaquePointer) {
        surfaces[handle] = WeakSurface(surface: surface)
    }

    func unregister(_ handle: OpaquePointer) {
        surfaces.removeValue(forKey: handle)
        if pointerFocus == handle { pointerFocus = nil }
        if keyboardFocus == handle { keyboardFocus = nil }
        for (id, focus) in touchFocus where focus == handle {
            touchFocus.removeValue(forKey: id)
            touchLocations.removeValue(forKey: id)
        }
    }

    /// Whether any window is still live — what `PlatformWindow`'s default
    /// close handler checks before stopping the event loop, so closing one of
    /// several open windows doesn't end the whole app.
    var hasNoLiveSurfaces: Bool { surfaces.isEmpty }

    private func surface(for handle: OpaquePointer?) -> WaylandSurface? {
        guard let handle else { return nil }
        guard let box = surfaces[handle] else { return nil }
        guard let surface = box.surface else {
            // The window went away without unregistering (its owner dropped
            // it). Drop the dead entry rather than looking it up again.
            surfaces.removeValue(forKey: handle)
            return nil
        }
        return surface
    }

    // MARK: - Event loop

    /// Runs until `stop()` or until the compositor goes away. The Wayland
    /// counterpart of `NSApplication.run()` — it blocks, and every callback
    /// this module makes happens inside it.
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

    /// How long a single `pumpEvents` may block waiting for the socket.
    /// Short enough that the fallback frame tick in `WaylandSurface` stays
    /// on time, long enough that an idle app isn't spinning a core.
    private static let pollTimeoutMilliseconds: Int32 = 8

    /// One turn of the loop: drain what's queued, flush what we've written,
    /// wait for more, then let every window take its frame tick. Exposed for
    /// hosts that own their own run loop and want to fold Wayland into it
    /// rather than hand the thread to `run()`.
    public func pumpEvents(timeoutMilliseconds: Int32 = 0) {
        guard let display = displayHandle, !isTerminated else { return }

        // Anything already in the queue is dispatched before we consider
        // blocking — otherwise a burst that arrived during the last frame
        // would sit there until the *next* readable event woke us.
        if wl_display_dispatch_pending(display) < 0 {
            terminate()
            return
        }
        while wl_display_flush(display) < 0 {
            if errno == EAGAIN {
                // The compositor isn't draining our side fast enough; wait
                // for it to become writable instead of spinning.
                var out = pollfd(fd: wl_display_get_fd(display), events: Int16(POLLOUT), revents: 0)
                if poll(&out, 1, timeoutMilliseconds) <= 0 { break }
                continue
            }
            terminate()
            return
        }

        var fds = pollfd(fd: wl_display_get_fd(display), events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeoutMilliseconds)
        if ready < 0 {
            if errno != EINTR { terminate() }
            return
        }
        if ready > 0 {
            if (fds.revents & Int16(POLLHUP | POLLERR)) != 0 {
                terminate()
                return
            }
            if (fds.revents & Int16(POLLIN)) != 0, wl_display_dispatch(display) < 0 {
                terminate()
                return
            }
        }

        tickSurfaces()
    }

    /// The compositor is gone (or the socket broke). Nothing can be sent or
    /// received after this; windows stay constructed but inert.
    private func terminate() {
        isTerminated = true
        running = false
    }

    /// Gives every live window the chance to drive a frame the compositor
    /// hasn't asked for — see `WaylandSurface.pumpFallbackTick`.
    private func tickSurfaces() {
        let now = waylandMonotonicSeconds()
        for (handle, box) in surfaces {
            guard let surface = box.surface else {
                surfaces.removeValue(forKey: handle)
                continue
            }
            surface.pumpFallbackTick(now: now)
        }
    }

    /// Pushes everything queued to the compositor now. Worth calling after a
    /// render when the loop isn't about to come back around immediately.
    public func flush() {
        guard let displayHandle else { return }
        wl_display_flush(displayHandle)
    }

    /// Blocks until the compositor has processed everything sent so far.
    public func roundtrip() {
        guard let displayHandle, !isTerminated else { return }
        if wl_display_roundtrip(displayHandle) < 0 { terminate() }
    }

    // MARK: - Registry

    private nonisolated(unsafe) static let registryListener: UnsafeMutablePointer<wl_registry_listener> = {
        var listener = wl_registry_listener()
        listener.global = { data, registry, name, interface, version in
            guard let registry, let interface, let me = WaylandDisplay.display(data) else { return }
            me.bindGlobal(
                registry: registry,
                name: name,
                interface: String(cString: interface),
                version: version
            )
        }
        listener.global_remove = { _, _, _ in }
        return waylandListener(listener)
    }()

    private func bindGlobal(registry: OpaquePointer, name: UInt32, interface: String, version: UInt32) {
        // Bind at the lowest of what the compositor offers and what the
        // headers this was built against describe. Asking for more than the
        // client library knows is a protocol error; asking for more than we
        // handle would let the compositor send events into listener slots
        // that don't exist in our struct.
        func bind(_ descriptor: UnsafePointer<wl_interface>) -> OpaquePointer? {
            let bound = min(version, UInt32(descriptor.pointee.version))
            guard let raw = wl_registry_bind(registry, name, descriptor, bound) else { return nil }
            return OpaquePointer(raw)
        }

        let compositorInterface = nucleant_wl_compositor_interface()!
        let seatInterface = nucleant_wl_seat_interface()!
        let wmBaseInterface = nucleant_xdg_wm_base_interface()!
        let decorationInterface = nucleant_zxdg_decoration_manager_v1_interface()!

        switch interface {
        case String(cString: compositorInterface.pointee.name):
            compositor = bind(compositorInterface)

        case String(cString: wmBaseInterface.pointee.name):
            wmBase = bind(wmBaseInterface)
            if let wmBase {
                xdg_wm_base_add_listener(wmBase, Self.wmBaseListener, selfPointer)
            }

        case String(cString: decorationInterface.pointee.name):
            decorationManager = bind(decorationInterface)

        case String(cString: seatInterface.pointee.name):
            // Only the first seat is taken. Multi-seat setups exist but map
            // badly onto a delegate that has one notion of "the pointer".
            guard seat == nil else { break }
            seat = bind(seatInterface)
            if let seat {
                wl_seat_add_listener(seat, Self.seatListener, selfPointer)
            }

        default:
            break
        }
    }

    // MARK: - xdg_wm_base

    private nonisolated(unsafe) static let wmBaseListener: UnsafeMutablePointer<xdg_wm_base_listener> = {
        var listener = xdg_wm_base_listener()
        // Non-optional: a compositor pings to check the client is alive and
        // kills it if the pong doesn't come back.
        listener.ping = { _, wmBase, serial in
            xdg_wm_base_pong(wmBase, serial)
        }
        return waylandListener(listener)
    }()

    // MARK: - Seat

    private nonisolated(unsafe) static let seatListener: UnsafeMutablePointer<wl_seat_listener> = {
        var listener = wl_seat_listener()
        listener.capabilities = { data, seat, capabilities in
            guard let seat, let me = WaylandDisplay.display(data) else { return }
            me.seatCapabilitiesChanged(seat: seat, capabilities: capabilities)
        }
        listener.name = { _, _, _ in }
        return waylandListener(listener)
    }()

    private func seatCapabilitiesChanged(seat: OpaquePointer, capabilities: UInt32) {
        // Devices come and go while the app runs — a mouse is unplugged, a
        // tablet is docked — so this fires more than once and each device is
        // created or released to match.
        let hasPointer = capabilities & WL_SEAT_CAPABILITY_POINTER.rawValue != 0
        let hasKeyboard = capabilities & WL_SEAT_CAPABILITY_KEYBOARD.rawValue != 0
        let hasTouch = capabilities & WL_SEAT_CAPABILITY_TOUCH.rawValue != 0

        if hasPointer, pointer == nil {
            pointer = wl_seat_get_pointer(seat)
            if let pointer {
                wl_pointer_add_listener(pointer, Self.pointerListener, selfPointer)
            }
        } else if !hasPointer, let existing = pointer {
            wl_pointer_release(existing)
            pointer = nil
            pointerFocus = nil
            pointerButtonsDown.removeAll()
        }

        if hasKeyboard, keyboard == nil {
            keyboard = wl_seat_get_keyboard(seat)
            if let keyboard {
                wl_keyboard_add_listener(keyboard, Self.keyboardListener, selfPointer)
            }
        } else if !hasKeyboard, let existing = keyboard {
            wl_keyboard_release(existing)
            keyboard = nil
            keyboardFocus = nil
            modifierMask = 0
            lockedMask = 0
        }

        if hasTouch, touch == nil {
            touch = wl_seat_get_touch(seat)
            if let touch {
                wl_touch_add_listener(touch, Self.touchListener, selfPointer)
            }
        } else if !hasTouch, let existing = touch {
            wl_touch_release(existing)
            touch = nil
            touchFocus.removeAll()
            touchLocations.removeAll()
        }
    }

    // MARK: - Pointer

    private nonisolated(unsafe) static let pointerListener: UnsafeMutablePointer<wl_pointer_listener> = {
        var listener = wl_pointer_listener()
        listener.enter = { data, _, _, surface, x, y in
            guard let me = WaylandDisplay.display(data) else { return }
            me.pointerFocus = surface
            me.pointerLocation = SIMD2(wl_fixed_to_double(x), wl_fixed_to_double(y))
        }
        listener.leave = { data, _, _, _ in
            guard let me = WaylandDisplay.display(data) else { return }
            me.pointerFocus = nil
            me.pointerButtonsDown.removeAll()
        }
        listener.motion = { data, _, _, x, y in
            guard let me = WaylandDisplay.display(data) else { return }
            me.pointerMoved(to: SIMD2(wl_fixed_to_double(x), wl_fixed_to_double(y)))
        }
        listener.button = { data, _, _, _, button, state in
            guard let me = WaylandDisplay.display(data) else { return }
            me.pointerButton(button, pressed: state == WL_POINTER_BUTTON_STATE_PRESSED.rawValue)
        }
        listener.axis = { data, _, _, axis, value in
            guard let me = WaylandDisplay.display(data) else { return }
            me.pointerAxis(axis, value: wl_fixed_to_double(value))
        }
        listener.frame = { data, _ in
            WaylandDisplay.display(data)?.pointerFrame()
        }
        // Every remaining slot is filled even though nothing is done with it:
        // libwayland calls straight through the listener struct by opcode, so
        // a null slot for an event the bound version can send is a crash, not
        // a no-op. `axis` above already carries the scroll distance these
        // refine.
        listener.axis_source = { _, _, _ in }
        listener.axis_stop = { _, _, _, _ in }
        listener.axis_discrete = { _, _, _, _ in }
        listener.axis_value120 = { _, _, _, _ in }
        listener.axis_relative_direction = { _, _, _, _ in }
        return waylandListener(listener)
    }()

    private func pointerMoved(to location: SIMD2<Double>) {
        pointerLocation = location
        guard let target = surface(for: pointerFocus) else { return }
        if pointerButtonsDown.contains(UInt32(BTN_LEFT)) {
            target.handler?.waylandPointerDragged(at: location)
        } else {
            target.handler?.waylandPointerMoved(to: location)
        }
    }

    private func pointerButton(_ button: UInt32, pressed: Bool) {
        if pressed {
            pointerButtonsDown.insert(button)
        } else {
            pointerButtonsDown.remove(button)
        }
        guard let target = surface(for: pointerFocus), let handler = target.handler else { return }
        switch button {
        case UInt32(BTN_LEFT):
            if pressed {
                handler.waylandPointerDown(at: pointerLocation)
            } else {
                handler.waylandPointerUp(at: pointerLocation)
            }
        case UInt32(BTN_RIGHT):
            if pressed {
                handler.waylandRightPointerDown(at: pointerLocation)
            } else {
                handler.waylandRightPointerUp(at: pointerLocation)
            }
        default:
            // Middle click and the extra side buttons have no hook on
            // NucleantWindow; dropping them keeps the delegate honest rather
            // than folding them into left/right.
            break
        }
    }

    private func pointerAxis(_ axis: UInt32, value: Double) {
        // Wayland measures a scroll as the distance the *content* should
        // move, positive being down/right. AppKit's deltas are the opposite
        // sign, and `on_scroll` is specified against AppKit — so negate.
        if axis == WL_POINTER_AXIS_VERTICAL_SCROLL.rawValue {
            pendingScroll.y -= value
        } else if axis == WL_POINTER_AXIS_HORIZONTAL_SCROLL.rawValue {
            pendingScroll.x -= value
        }
    }

    private func pointerFrame() {
        guard pendingScroll != SIMD2<Double>(0, 0) else { return }
        let scroll = pendingScroll
        pendingScroll = SIMD2(0, 0)
        surface(for: pointerFocus)?.handler?.waylandScrolled(dx: scroll.x, dy: scroll.y)
    }

    // MARK: - Keyboard

    private nonisolated(unsafe) static let keyboardListener: UnsafeMutablePointer<wl_keyboard_listener> = {
        var listener = wl_keyboard_listener()
        listener.keymap = { _, _, _, fd, _ in
            // The compositor sends the layout as an mmap-able fd. Translating
            // it needs libxkbcommon, which this target deliberately doesn't
            // depend on (see LinuxKeyMap) — but the fd is ours either way and
            // leaking one per keyboard hotplug is not on.
            close(fd)
        }
        listener.enter = { data, _, _, surface, _ in
            WaylandDisplay.display(data)?.keyboardFocus = surface
        }
        listener.leave = { data, _, _, _ in
            guard let me = WaylandDisplay.display(data) else { return }
            me.keyboardFocus = nil
            me.modifierMask = 0
        }
        listener.key = { data, _, _, _, key, state in
            guard let me = WaylandDisplay.display(data) else { return }
            me.keyEvent(key, pressed: state == WL_KEYBOARD_KEY_STATE_PRESSED.rawValue)
        }
        listener.modifiers = { data, _, _, depressed, latched, locked, _ in
            guard let me = WaylandDisplay.display(data) else { return }
            me.modifierMask = depressed | latched
            me.lockedMask = locked
        }
        listener.repeat_info = { _, _, _, _ in }
        return waylandListener(listener)
    }()

    private func keyEvent(_ key: UInt32, pressed: Bool) {
        guard let target = surface(for: keyboardFocus), let handler = target.handler else { return }
        let characters = LinuxKeyMap.characters(
            forKey: key,
            shift: modifierMask & LinuxKeyMap.shiftBit != 0,
            capsLock: lockedMask & LinuxKeyMap.capsLockBit != 0
        )
        // The raw evdev code is what's reported, not an X11 keycode (evdev +
        // 8) or an xkb keysym: it's the one identifier that's stable across
        // layouts, which is what a keyCode is for. `characters` is where the
        // layout-dependent answer belongs.
        if pressed {
            handler.waylandKeyDown(key: UInt16(truncatingIfNeeded: key), chars: characters)
        } else {
            handler.waylandKeyUp(key: UInt16(truncatingIfNeeded: key), chars: characters)
        }
    }

    // MARK: - Touch

    private nonisolated(unsafe) static let touchListener: UnsafeMutablePointer<wl_touch_listener> = {
        var listener = wl_touch_listener()
        listener.down = { data, _, _, _, surface, id, x, y in
            guard let surface, let me = WaylandDisplay.display(data) else { return }
            let location = SIMD2(wl_fixed_to_double(x), wl_fixed_to_double(y))
            me.touchFocus[id] = surface
            me.touchLocations[id] = location
            me.surface(for: surface)?.handler?.waylandTouchDown(id: Int(id), at: location)
        }
        listener.up = { data, _, _, _, id in
            guard let me = WaylandDisplay.display(data) else { return }
            let location = me.touchLocations[id] ?? SIMD2(0, 0)
            let focus = me.touchFocus.removeValue(forKey: id)
            me.touchLocations.removeValue(forKey: id)
            me.surface(for: focus)?.handler?.waylandTouchUp(id: Int(id), at: location)
        }
        listener.motion = { data, _, _, id, x, y in
            guard let me = WaylandDisplay.display(data) else { return }
            let location = SIMD2(wl_fixed_to_double(x), wl_fixed_to_double(y))
            me.touchLocations[id] = location
            me.surface(for: me.touchFocus[id])?.handler?.waylandTouchMoved(id: Int(id), at: location)
        }
        listener.frame = { _, _ in }
        listener.cancel = { data, _ in
            guard let me = WaylandDisplay.display(data) else { return }
            // The compositor has taken the whole sequence over as a gesture
            // (an edge swipe, say). Every point in flight is cancelled, not
            // ended — the same distinction UIKit draws.
            for (id, focus) in me.touchFocus {
                let location = me.touchLocations[id] ?? SIMD2(0, 0)
                me.surface(for: focus)?.handler?.waylandTouchCancelled(id: Int(id), at: location)
            }
            me.touchFocus.removeAll()
            me.touchLocations.removeAll()
        }
        listener.shape = { _, _, _, _, _ in }
        listener.orientation = { _, _, _, _ in }
        return waylandListener(listener)
    }()
}
#endif
