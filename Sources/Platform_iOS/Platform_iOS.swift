//
//  Platform_iOS.swift
//  NucleantApplication
//
#if os(iOS)
import NucleantWindow

import UIKit

/// The touch/key events `PlatformWindow` routes from UIKit to its
/// `win_delegate`. Mirrors macOS's `WindowBaseDelegate`: the geometry-typed
/// methods here are the seam, and the default forwarding to the `on_touch_*` /
/// `on_key_*` Python-facing hooks lives on `NucleantWindow where Self:
/// WindowTouchDelegate` so a conformance declared in another module
/// picks these up as its default witnesses.
public protocol WindowTouchDelegate: AnyObject {
    func touchDown(id: Int, location: CGPoint)
    func touchMoved(id: Int, location: CGPoint)
    func touchUp(id: Int, location: CGPoint)
    func touchCancelled(id: Int, location: CGPoint)
    func keyDown(key: UInt16, chars: String?)
    func keyUp(key: UInt16, chars: String?)
    /// The on-screen keyboard was put away from the keyboard itself (iPad's
    /// dismiss key), not by `textInputKind`, which is `.none` now.
    func keyboardDismissed()
    /// The part of the window the on-screen keyboard covers is about to
    /// change: `height` is the new `keyboardHeight`, in points from the
    /// window's bottom edge up. The keyboard gets there over `duration`
    /// seconds on `curve`, its own animation, so whatever moves out of its
    /// way can move with it. A curve can be one UIKit has no case for: the
    /// keyboard's own is raw value 7. A change of the window's own size or
    /// place, with the keyboard where it was, has a `duration` of 0.
    func keyboardHeightChanged(_ height: CGFloat, duration: TimeInterval, curve: UIView.AnimationCurve)
    /// The window's safe area changed: `insets` is the window's
    /// `safeAreaInsets` now, in points — what the status bar, the sensor
    /// housing, the home indicator and the rounded corners keep from its
    /// edges. Told as soon as the delegate is set, when they aren't zero.
    func safeAreaInsetsChanged(_ insets: UIEdgeInsets)
}

extension NucleantWindow where Self: WindowTouchDelegate {
    // public so an out-of-module conformance can use these as the default
    // witnesses for the public WindowTouchDelegate requirements.
    public func touchDown(id: Int, location: CGPoint) {
        on_touch_down(id: id, x: location.x, y: location.y)
    }

    public func touchMoved(id: Int, location: CGPoint) {
        on_touch_moved(id: id, x: location.x, y: location.y)
    }

    public func touchUp(id: Int, location: CGPoint) {
        on_touch_up(id: id, x: location.x, y: location.y)
    }

    public func touchCancelled(id: Int, location: CGPoint) {
        on_touch_cancelled(id: id, x: location.x, y: location.y)
    }

    public func keyDown(key: UInt16, chars: String?) {
        on_key_down(keyCode: key, characters: chars)
    }

    public func keyUp(key: UInt16, chars: String?) {
        on_key_up(keyCode: key, characters: chars)
    }

    /// Nothing, unless the window does something about it.
    public func keyboardDismissed() {}

    /// Nothing, unless the window does something about it.
    public func keyboardHeightChanged(_ height: CGFloat, duration: TimeInterval, curve: UIView.AnimationCurve) {}

    /// Nothing, unless the window does something about it.
    public func safeAreaInsetsChanged(_ insets: UIEdgeInsets) {}
}
#endif
