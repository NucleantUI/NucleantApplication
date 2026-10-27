//
//  Platform_Windows.swift
//  NucleantApplication
//
#if os(Windows)
import NucleantWindow

/// The input events `PlatformWindow` routes from Win32 to its `win_delegate`.
/// Like Linux's `WaylandWindowDelegate`, the union of what macOS's
/// `WindowBaseDelegate` and iOS's `WindowTouchDelegate` cover: a Windows
/// laptop with a touch screen has a mouse, a keyboard and fingers at once.
///
/// Same seam as the other platforms — the geometry-typed methods here are
/// what `PlatformWindow` calls, and the default forwarding to the
/// `on_mouse_*` / `on_touch_*` / `on_key_*` hooks lives on `NucleantWindow
/// where Self: Win32WindowDelegate` below, so a conformance declared in
/// another module picks these up as its default witnesses.
///
/// Locations are client-area points — pixels over `PlatformWindow.scale` —
/// the same space `on_size` reports and the same contract as
/// `NSPoint`/`CGPoint` on the Apple platforms.
public protocol Win32WindowDelegate: AnyObject {
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

extension NucleantWindow where Self: Win32WindowDelegate {
    // public so a conformance declared in another module can use these as the
    // default witnesses for the public Win32WindowDelegate requirements, as
    // on the other platforms.
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
