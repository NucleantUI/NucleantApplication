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
/// WindowTouchDelegate` so a conformance declared in another module (e.g.
/// PyNucleantUI's `WindowBase`) picks these up as its default witnesses.
public protocol WindowTouchDelegate: AnyObject {
    func touchDown(id: Int, location: CGPoint)
    func touchMoved(id: Int, location: CGPoint)
    func touchUp(id: Int, location: CGPoint)
    func touchCancelled(id: Int, location: CGPoint)
    func keyDown(key: UInt16, chars: String?)
    func keyUp(key: UInt16, chars: String?)
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
}
#endif
