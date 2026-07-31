//
//  WaylandSurface.swift
//  NucleantApplication
//
//  One window's worth of Wayland: the wl_surface, the xdg-shell role that
//  makes it a desktop window, the size negotiation, and the frame callback
//  that paces rendering.
//
#if os(Linux)
import CWayland
import Glibc

/// What a `WaylandSurface` reports upwards.
///
/// Deliberately not generic, and deliberately separate from
/// `PlatformWindow`: a `@convention(c)` function pointer — which is all a
/// Wayland listener slot is — cannot be formed from a closure that captures
/// generic parameters. So every C callback lives on this non-generic class
/// and comes back out through this protocol, which `PlatformWindow<WindowBase>`
/// implements. Coordinates and sizes are logical points, matching
/// `WaylandWindowDelegate`.
protocol WaylandSurfaceHandler: AnyObject {
    func waylandSurfaceDidTick(dt: Double)
    func waylandSurfaceDidResize(width: Double, height: Double)
    func waylandSurfaceDidRequestClose()

    func waylandPointerDown(at location: SIMD2<Double>)
    func waylandPointerUp(at location: SIMD2<Double>)
    func waylandPointerDragged(at location: SIMD2<Double>)
    func waylandPointerMoved(to location: SIMD2<Double>)
    func waylandRightPointerDown(at location: SIMD2<Double>)
    func waylandRightPointerUp(at location: SIMD2<Double>)
    func waylandScrolled(dx: Double, dy: Double)

    func waylandKeyDown(key: UInt16, chars: String?)
    func waylandKeyUp(key: UInt16, chars: String?)

    func waylandTouchDown(id: Int, at location: SIMD2<Double>)
    func waylandTouchMoved(id: Int, at location: SIMD2<Double>)
    func waylandTouchUp(id: Int, at location: SIMD2<Double>)
    func waylandTouchCancelled(id: Int, at location: SIMD2<Double>)
}

/// Recovers the surface a listener was registered with from the `void *` it
/// was registered with.
///
/// A free function rather than a static method: naming a member from inside a
/// `@convention(c)` closure captures the enclosing type, and a C function
/// pointer can't be formed from a closure that captures anything at all.
private func surfaceObject(_ data: UnsafeMutableRawPointer?) -> WaylandSurface? {
    guard let data else { return nil }
    return Unmanaged<WaylandSurface>.fromOpaque(data).takeUnretainedValue()
}

/// Whether an `xdg_toplevel.configure` state array contains any state in
/// which the compositor, not the client, decides the size.
///
/// The array is a packed run of `uint32` state values — `wl_array` is a byte
/// buffer with no element type, so the count comes from its size.
private func containsSizingState(_ states: UnsafeMutablePointer<wl_array>?) -> Bool {
    guard let states, let data = states.pointee.data else { return false }
    let count = states.pointee.size / MemoryLayout<UInt32>.size
    let values = data.assumingMemoryBound(to: UInt32.self)
    for index in 0..<count {
        switch values[index] {
        case XDG_TOPLEVEL_STATE_MAXIMIZED.rawValue,
             XDG_TOPLEVEL_STATE_FULLSCREEN.rawValue,
             XDG_TOPLEVEL_STATE_TILED_LEFT.rawValue,
             XDG_TOPLEVEL_STATE_TILED_RIGHT.rawValue,
             XDG_TOPLEVEL_STATE_TILED_TOP.rawValue,
             XDG_TOPLEVEL_STATE_TILED_BOTTOM.rawValue:
            return true
        default:
            continue
        }
    }
    return false
}

/// The Wayland side of a window. `PlatformWindow` owns one of these and is
/// its handler; nothing outside this module needs to name it.
final class WaylandSurface {

    /// `wl_surface *` — the second half of what `vkCreateWaylandSurfaceKHR`
    /// needs, the first being `WaylandDisplay.shared.displayHandle`.
    private(set) var handle: OpaquePointer?

    private var xdgSurface: OpaquePointer?
    private var xdgToplevel: OpaquePointer?
    private var decoration: OpaquePointer?

    private let listeners = ListenerStorage()

    weak var handler: (any WaylandSurfaceHandler)?

    /// Logical size in points — what the compositor negotiated, and the
    /// space pointer/touch coordinates arrive in.
    private(set) var width: Double
    private(set) var height: Double

    /// Buffer scale: how many device pixels one logical point is worth.
    /// Reported by the compositor via `wl_surface.preferred_buffer_scale`
    /// (wl_surface v6). Compositors older than that never send it and this
    /// stays 1 — the window still works, it just isn't HiDPI-aware.
    private(set) var scale: Double = 1

    /// Size of the render target in device pixels. This is what a swapchain
    /// should be sized against, not `width`/`height`.
    var bufferWidth: UInt32 { UInt32(max(width * scale, 1)) }
    var bufferHeight: UInt32 { UInt32(max(height * scale, 1)) }

    /// True once the compositor has sent a configure and we've acked it — a
    /// surface may not be drawn to before that.
    private(set) var isConfigured = false

    private var pendingWidth: Double = 0
    private var pendingHeight: Double = 0
    private var pendingScale: Double = 0

    /// Whether the last configure left the window free to pick its own size —
    /// i.e. not maximized, fullscreen or tiled against an edge. Only in that
    /// state does a zero-size configure mean "restore".
    private var isFloating = true
    /// The size to go back to when a maximize/fullscreen ends.
    private var floatingWidth: Double
    private var floatingHeight: Double

    /// The geometry the handler has been told about. Resizes are delivered
    /// from `tick`, not from the configure that caused them, for two reasons:
    /// the first configure arrives during `init`, before there's a handler to
    /// tell — and the compositor's answer can differ from the size that was
    /// asked for (a tiling WM decides, it doesn't negotiate), so that first
    /// one is exactly the one that mustn't be lost. Comparing against this
    /// also coalesces a drag-resize's burst of configures into one call per
    /// frame.
    private var deliveredWidth: Double = 0
    private var deliveredHeight: Double = 0
    private var deliveredScale: Double = 0

    // MARK: Frame pacing

    /// The in-flight `wl_callback` from `wl_surface_frame`, if any.
    private var frameCallback: OpaquePointer?
    private var isTicking = false
    private var lastTickTime: Double = 0

    /// How long to wait for a compositor frame callback before ticking
    /// anyway. See `pumpFallbackTick` — this is a floor on the frame rate
    /// while the compositor isn't asking for frames, not a frame interval.
    private static let fallbackTickInterval: Double = 0.25

    /// Δt handed to the first tick, before there are two timestamps to
    /// subtract.
    private static let assumedFirstFrameInterval: Double = 1.0 / 60.0

    /// Owns the listener structs, which have to outlive the proxies that
    /// point at them. A class so the C callbacks can reach it by address
    /// without fighting struct copy semantics.
    private final class ListenerStorage {
        var surface: UnsafeMutablePointer<wl_surface_listener>?
        var xdgSurface: UnsafeMutablePointer<xdg_surface_listener>?
        var toplevel: UnsafeMutablePointer<xdg_toplevel_listener>?
        var frame: UnsafeMutablePointer<wl_callback_listener>?
        var decoration: UnsafeMutablePointer<zxdg_toplevel_decoration_v1_listener>?

        deinit {
            surface?.deinitialize(count: 1); surface?.deallocate()
            xdgSurface?.deinitialize(count: 1); xdgSurface?.deallocate()
            toplevel?.deinitialize(count: 1); toplevel?.deallocate()
            frame?.deinitialize(count: 1); frame?.deallocate()
            decoration?.deinitialize(count: 1); decoration?.deallocate()
        }
    }

    // MARK: - Init

    init(width: Double, height: Double, title: String) throws {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.floatingWidth = self.width
        self.floatingHeight = self.height

        let display = WaylandDisplay.shared
        try display.connect()

        guard let compositor = display.compositor else {
            throw WaylandError.missingGlobal("wl_compositor")
        }
        guard let wmBase = display.wmBase else {
            throw WaylandError.missingGlobal("xdg_wm_base")
        }
        guard let surface = wl_compositor_create_surface(compositor) else {
            throw WaylandError.surfaceCreationFailed
        }
        self.handle = surface

        let me = Unmanaged.passUnretained(self).toOpaque()

        listeners.surface = waylandListener(Self.makeSurfaceListener())
        wl_surface_add_listener(surface, listeners.surface, me)

        // xdg-shell in two steps: xdg_surface adds the configure/ack
        // handshake to a plain surface, and xdg_toplevel then says it's a
        // top-level window rather than a popup.
        guard let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, surface) else {
            throw WaylandError.surfaceCreationFailed
        }
        self.xdgSurface = xdgSurface
        listeners.xdgSurface = waylandListener(Self.makeXdgSurfaceListener())
        xdg_surface_add_listener(xdgSurface, listeners.xdgSurface, me)

        guard let toplevel = xdg_surface_get_toplevel(xdgSurface) else {
            throw WaylandError.surfaceCreationFailed
        }
        self.xdgToplevel = toplevel
        listeners.toplevel = waylandListener(Self.makeToplevelListener())
        xdg_toplevel_add_listener(toplevel, listeners.toplevel, me)
        setTitle(title)

        // Ask for a compositor-drawn titlebar where that's an option. Where
        // it isn't (GNOME advertises no decoration manager) the window is
        // simply undecorated — the alternative would be drawing our own
        // chrome, which isn't this layer's job.
        if let manager = display.decorationManager {
            decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(manager, toplevel)
            if let decoration {
                listeners.decoration = waylandListener(Self.makeDecorationListener())
                zxdg_toplevel_decoration_v1_add_listener(decoration, listeners.decoration, me)
                zxdg_toplevel_decoration_v1_set_mode(
                    decoration,
                    ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE.rawValue
                )
            }
        }

        display.register(self, for: surface)

        // A surface with a role must be committed before the compositor will
        // configure it, and the round trip waits for that configure so the
        // caller gets a window with a negotiated size rather than the one it
        // asked for.
        wl_surface_commit(surface)
        display.roundtrip()
    }

    deinit {
        destroy()
    }

    // MARK: - Teardown

    func destroy() {
        stopFrameLoop()
        if let handle {
            WaylandDisplay.shared.unregister(handle)
        }
        if let decoration {
            zxdg_toplevel_decoration_v1_destroy(decoration)
            self.decoration = nil
        }
        if let xdgToplevel {
            xdg_toplevel_destroy(xdgToplevel)
            self.xdgToplevel = nil
        }
        if let xdgSurface {
            xdg_surface_destroy(xdgSurface)
            self.xdgSurface = nil
        }
        if let handle {
            wl_surface_destroy(handle)
            self.handle = nil
        }
    }

    // MARK: - Window properties

    func setTitle(_ title: String) {
        guard let xdgToplevel else { return }
        title.withCString { xdg_toplevel_set_title(xdgToplevel, $0) }
        // The app id is what desktop environments match against a .desktop
        // file for the icon and the task-switcher name.
        title.withCString { xdg_toplevel_set_app_id(xdgToplevel, $0) }
    }

    func minimize() {
        guard let xdgToplevel else { return }
        xdg_toplevel_set_minimized(xdgToplevel)
    }

    /// Requests a state change. The compositor answers with a configure
    /// carrying the size it decided on, which is what actually resizes the
    /// window — these are requests, not setters, and a compositor is free to
    /// ignore them.
    func setMaximized(_ maximized: Bool) {
        guard let xdgToplevel else { return }
        if maximized {
            xdg_toplevel_set_maximized(xdgToplevel)
        } else {
            xdg_toplevel_unset_maximized(xdgToplevel)
        }
    }

    func setFullscreen(_ fullscreen: Bool) {
        guard let xdgToplevel else { return }
        if fullscreen {
            // A null output lets the compositor pick which one.
            xdg_toplevel_set_fullscreen(xdgToplevel, nil)
        } else {
            xdg_toplevel_unset_fullscreen(xdgToplevel)
        }
    }

    // MARK: - Frame loop
    //
    // The Wayland equivalent of a CVDisplayLink/CADisplayLink is
    // `wl_surface.frame`: a one-shot callback the compositor fires when it's
    // about to composite, i.e. exactly when a new frame is worth drawing.
    // One-shot is the important part — each tick has to request the next, so
    // the loop is self-perpetuating rather than a repeating timer, and it
    // stops on its own while the window is hidden or occluded.

    func startFrameLoop() {
        guard !isTicking else { return }
        isTicking = true
        lastTickTime = waylandMonotonicSeconds()
        requestFrameCallback()
    }

    func stopFrameLoop() {
        isTicking = false
        if let frameCallback {
            wl_callback_destroy(frameCallback)
            self.frameCallback = nil
        }
    }

    private func requestFrameCallback() {
        guard isTicking, frameCallback == nil, let handle else { return }
        guard let callback = wl_surface_frame(handle) else { return }
        if listeners.frame == nil {
            listeners.frame = waylandListener(Self.makeFrameListener())
        }
        wl_callback_add_listener(callback, listeners.frame, Unmanaged.passUnretained(self).toOpaque())
        frameCallback = callback
        // The request only takes effect on the next commit. Renderers commit
        // as part of presenting, but this must not depend on one having run:
        // committing here is what gets the very first callback moving.
        wl_surface_commit(handle)
    }

    private func frameCallbackFired() {
        if let frameCallback {
            wl_callback_destroy(frameCallback)
            self.frameCallback = nil
        }
        tick()
    }

    /// Drives a frame the compositor didn't ask for.
    ///
    /// Frame callbacks only arrive for a surface the compositor is actually
    /// compositing — which a window that has never had a buffer attached is
    /// not. That's a chicken-and-egg: the first frame is what attaches the
    /// first buffer, and without it the callback chain never starts. The same
    /// stall happens whenever a window is minimised or fully occluded and
    /// then something needs to run anyway. So the loop keeps a floor: if no
    /// callback has come for `fallbackTickInterval`, tick regardless. Well
    /// above any real frame interval, so a compositing window is paced purely
    /// by its callbacks and this never fires.
    func pumpFallbackTick(now: Double) {
        guard isTicking, isConfigured else { return }
        guard now - lastTickTime >= Self.fallbackTickInterval else { return }
        tick()
    }

    private func tick() {
        let now = waylandMonotonicSeconds()
        let dt = lastTickTime > 0 ? now - lastTickTime : Self.assumedFirstFrameInterval
        lastTickTime = now
        // Queued before the handler runs so the request rides along on
        // whatever commit the render does, rather than needing its own.
        requestFrameCallback()
        deliverPendingResize()
        handler?.waylandSurfaceDidTick(dt: dt)
    }

    /// Hands the handler the current geometry if it hasn't seen it yet, so
    /// layout is settled before the frame that renders against it.
    private func deliverPendingResize() {
        guard let handler else { return }
        guard width != deliveredWidth || height != deliveredHeight || scale != deliveredScale else {
            return
        }
        deliveredWidth = width
        deliveredHeight = height
        deliveredScale = scale
        handler.waylandSurfaceDidResize(width: width, height: height)
    }

    // MARK: - Configure

    /// Adopts whatever the last configure sequence staged. The handler isn't
    /// told from here — see `deliverPendingResize`.
    private func applyConfigure() {
        if pendingScale > 0, pendingScale != scale {
            // A scale change is a change in pixel size for an unchanged point
            // size, which still resizes the swapchain.
            scale = pendingScale
            if let handle, wl_proxy_get_version(handle) >= 3 {
                wl_surface_set_buffer_scale(handle, Int32(scale))
            }
        }
        pendingScale = 0

        // A zero size means "you choose" — the compositor has no opinion. In
        // a maximized/fullscreen/tiled state it always has one, so a zero
        // there can only mean the state is being *left*, and the size to
        // choose is the one the window had before it entered: coming back
        // from fullscreen must not leave the window the size of the screen.
        if pendingWidth > 0, pendingHeight > 0 {
            width = pendingWidth
            height = pendingHeight
        } else if isFloating {
            width = floatingWidth
            height = floatingHeight
        }
        // Track the floating size as it changes, so there's something to
        // restore to. A drag-resize is a run of floating configures, and the
        // last one before a maximize is what should come back.
        if isFloating {
            floatingWidth = width
            floatingHeight = height
        }
        pendingWidth = 0
        pendingHeight = 0

        if let xdgSurface {
            // Tell the compositor what area of the surface is the window
            // proper, so it can place drop shadows and snap edges correctly.
            xdg_surface_set_window_geometry(xdgSurface, 0, 0, Int32(width), Int32(height))
        }
    }

    // MARK: - Listeners

    private static func makeSurfaceListener() -> wl_surface_listener {
        var listener = wl_surface_listener()
        // enter/leave report which outputs the surface overlaps. Output-by-
        // output scale tracking is what preferred_buffer_scale replaced, so
        // these are only kept non-null because the bound version can send them.
        listener.enter = { _, _, _ in }
        listener.leave = { _, _, _ in }
        listener.preferred_buffer_scale = { data, _, factor in
            guard let me = surfaceObject(data), factor > 0 else { return }
            me.pendingScale = Double(factor)
            // No configure is coming to bracket this — the compositor changed
            // its mind about scale on its own — so apply it directly.
            me.applyConfigure()
        }
        listener.preferred_buffer_transform = { _, _, _ in }
        return listener
    }

    private static func makeXdgSurfaceListener() -> xdg_surface_listener {
        var listener = xdg_surface_listener()
        listener.configure = { data, xdgSurface, serial in
            // This is the end of a configure sequence: any xdg_toplevel
            // configure that preceded it is part of the same atomic update,
            // which is why the size is staged rather than applied on arrival.
            // Acking has to come first, then the state it acknowledges.
            xdg_surface_ack_configure(xdgSurface, serial)
            guard let me = surfaceObject(data) else { return }
            me.applyConfigure()
            // Only this event makes the surface configured — a
            // preferred_buffer_scale can arrive first and also lands in
            // applyConfigure, but it isn't permission to start drawing.
            me.isConfigured = true
        }
        return listener
    }

    private static func makeToplevelListener() -> xdg_toplevel_listener {
        var listener = xdg_toplevel_listener()
        listener.configure = { data, _, width, height, states in
            guard let me = surfaceObject(data) else { return }
            me.pendingWidth = Double(width)
            me.pendingHeight = Double(height)
            me.isFloating = !containsSizingState(states)
        }
        listener.close = { data, _ in
            // A request, not an order — the compositor is relaying the user
            // clicking the close button and it's the app's call what happens.
            surfaceObject(data)?.handler?.waylandSurfaceDidRequestClose()
        }
        listener.configure_bounds = { _, _, _, _ in }
        listener.wm_capabilities = { _, _, _ in }
        return listener
    }

    private static func makeFrameListener() -> wl_callback_listener {
        var listener = wl_callback_listener()
        listener.done = { data, _, _ in
            // The callback's own timestamp is a compositor-clock millisecond
            // counter that wraps; Δt is measured against CLOCK_MONOTONIC
            // instead, which neither wraps nor needs an epoch.
            surfaceObject(data)?.frameCallbackFired()
        }
        return listener
    }

    private static func makeDecorationListener() -> zxdg_toplevel_decoration_v1_listener {
        var listener = zxdg_toplevel_decoration_v1_listener()
        // The compositor answers with the mode it actually chose, which may
        // be client-side even though server-side was requested. Nothing to do
        // either way: we don't draw chrome, so a client-side answer just
        // means the window is undecorated.
        listener.configure = { _, _, _ in }
        return listener
    }
}
#endif
