//
//  RootViewController.swift
//  NucleantApplication
//
#if os(iOS)
import UIKit

/// The view controller at the root of a `PlatformWindow`. UIKit asks it
/// whether the status bar shows and whether the Home indicator hides; it
/// answers what the window was told, and asks UIKit to ask again when that
/// changes.
///
/// UIKit only asks when the app leaves the status bar to its view
/// controllers: `UIViewControllerBasedStatusBarAppearance` in the
/// Info.plist absent or true. Set to false, the Info.plist's own
/// `UIStatusBarHidden` decides for the whole app instead.
final class RootViewController: UIViewController {

    var statusBarHidden = false {
        didSet {
            guard statusBarHidden != oldValue else { return }
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    var homeIndicatorAutoHidden = false {
        didSet {
            guard homeIndicatorAutoHidden != oldValue else { return }
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    override var prefersStatusBarHidden: Bool { statusBarHidden }

    override var prefersHomeIndicatorAutoHidden: Bool { homeIndicatorAutoHidden }
}
#endif
