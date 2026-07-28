//
//  Platform_Linux.swift
//  NucleantApplication
//
#if os(Linux)
import NucleantWindow

/// The input events `PlatformWindow` routes from Wayland to its
/// `win_delegate`. This is the union of what macOS's `WindowBaseDelegate`
/// and iOS's `WindowTouchDelegate` each cover separately, because Linux is
/// the one platform where both halves are live at once: a `wl_seat` can
/// advertise a pointer, a keyboard and a multitouch device simultaneously,
/// and a laptop with a touchscreen does exactly that.
///
/// Same seam as the other two platforms — the geometry-typed methods here are
/// what `PlatformWindow` calls, and the default forwarding to the
/// `on_mouse_*` / `on_touch_*` / `on_key_*` hooks lives on `NucleantWindow
/// where Self: WaylandWindowDelegate` below, so a conformance declared in
/// another module (e.g. PyNucleantUI's `WindowBase`) picks these up as its
/// default witnesses.
///
/// Locations are surface-local, in logical points — the same space
/// `on_size` reports and the same contract as `NSPoint`/`CGPoint` on the
/// Apple platforms. Multiply by `PlatformWindow.scale` for pixels.
public protocol WaylandWindowDelegate: AnyObject {
    func mouseDown(location: SIMD2<Double>)
    func mouseUp(location: SIMD2<Double>)
    func mouseDragged(location: SIMD2<Double>)
    func mouseMoved(location: SIMD2<Double>)
    func rightMouseDown(location: SIMD2<Double>)
    func rightMouseUp(location: SIMD2<Double>)
    func scrollWheel(deltaX: Double, deltaY: Double)
    func keyDown(key: UInt16, chars: String?)
    func keyUp(key: UInt16, chars: String?)
    func touchDown(id: Int, location: SIMD2<Double>)
    func touchMoved(id: Int, location: SIMD2<Double>)
    func touchUp(id: Int, location: SIMD2<Double>)
    func touchCancelled(id: Int, location: SIMD2<Double>)
}

extension NucleantWindow where Self: WaylandWindowDelegate {
    // public so a conformance declared in another module can use these as the
    // default witnesses for the public WaylandWindowDelegate requirements —
    // an internal default impl isn't visible there and the conformance would
    // fail to type-check. Same reasoning as Platform_MacOS / Platform_iOS.
    public func mouseDown(location: SIMD2<Double>) {
        on_mouse_down(x: location.x, y: location.y)
    }

    public func mouseUp(location: SIMD2<Double>) {
        on_mouse_up(x: location.x, y: location.y)
    }

    public func mouseDragged(location: SIMD2<Double>) {
        on_mouse_dragged(x: location.x, y: location.y)
    }

    public func mouseMoved(location: SIMD2<Double>) {
        on_mouse_moved(x: location.x, y: location.y)
    }

    public func rightMouseDown(location: SIMD2<Double>) {
        on_right_mouse_down(x: location.x, y: location.y)
    }

    public func rightMouseUp(location: SIMD2<Double>) {
        on_right_mouse_up(x: location.x, y: location.y)
    }

    public func scrollWheel(deltaX: Double, deltaY: Double) {
        on_scroll(dx: deltaX, dy: deltaY)
    }

    public func keyDown(key: UInt16, chars: String?) {
        on_key_down(keyCode: key, characters: chars)
    }

    public func keyUp(key: UInt16, chars: String?) {
        on_key_up(keyCode: key, characters: chars)
    }

    public func touchDown(id: Int, location: SIMD2<Double>) {
        on_touch_down(id: id, x: location.x, y: location.y)
    }

    public func touchMoved(id: Int, location: SIMD2<Double>) {
        on_touch_moved(id: id, x: location.x, y: location.y)
    }

    public func touchUp(id: Int, location: SIMD2<Double>) {
        on_touch_up(id: id, x: location.x, y: location.y)
    }

    public func touchCancelled(id: Int, location: SIMD2<Double>) {
        on_touch_cancelled(id: id, x: location.x, y: location.y)
    }
}
#endif
