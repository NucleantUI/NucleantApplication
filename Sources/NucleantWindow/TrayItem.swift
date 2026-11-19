//
//  TrayItem.swift
//  NucleantApplication
//
//  An app's item in the system tray: on macOS a menu bar extra, one of the
//  icons at the right end of the menu bar. The platform-neutral description,
//  and `TrayHost`, what a platform provider turns it into. Neither side sees
//  the other's framework types.
//
// https://developer.apple.com/documentation/appkit/nsstatusitem
//

/// One item in the system tray: an icon or a title, and what a click on it
/// does. A reference type, so the app keeps the one it inserted, edits it in
/// place and has the host show the change (`TrayHost.refresh(_:)`).
@MainActor
public final class TrayItem {

    /// What it is called. Shown when there is no icon, and read out by
    /// accessibility when there is.
    public var title: String

    /// One of the platform's own named icons — an SF Symbol name on macOS.
    public var iconName: String?

    /// A bitmap to show, in place of a named icon.
    public var icon: TrayIcon?

    /// Shows the title next to the icon, not only when there is none.
    public var showsTitle: Bool

    /// What a click on it does.
    public var action: Action

    /// Called when the person takes the item out of the tray themselves —
    /// on macOS, by dragging it out of the menu bar with ⌘ held. Without
    /// it, the item can't be taken out.
    public var onRemove: (() -> Void)?

    public enum Action {
        /// A menu drops down from the item.
        case menu([MenuBar.Item])
        /// The app shows what it likes — a window under the item, say —
        /// and is told where the item is on screen.
        case press((TrayAnchor) -> Void)
    }

    public init(
        title: String,
        iconName: String? = nil,
        icon: TrayIcon? = nil,
        showsTitle: Bool = false,
        action: Action,
        onRemove: (() -> Void)? = nil
    ) {
        self.title = title
        self.iconName = iconName
        self.icon = icon
        self.showsTitle = showsTitle
        self.action = action
        self.onRemove = onRemove
    }
}

/// A tray item's bitmap: `width` × `height` pixels, row-major from the
/// top-left, each an alpha-premultiplied ARGB `UInt32` (a little-endian BGRA
/// byte buffer), `scale` pixels to a point.
public struct TrayIcon: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt32]
    public var scale: Double

    public init(width: Int, height: Int, pixels: [UInt32], scale: Double = 1) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.scale = scale
    }
}

/// Where a tray item is on screen, in points, in the platform's screen
/// coordinates — on macOS AppKit's, with y going up from the bottom of the
/// main screen.
public struct TrayAnchor: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A platform's system tray. The host owns the native objects; an item is
/// shown from `insert` until `remove`.
@MainActor
public protocol TrayHost: AnyObject {
    func insert(_ item: TrayItem)
    /// Show what changed in an inserted item: its title, icon or action.
    func refresh(_ item: TrayItem)
    func remove(_ item: TrayItem)
}
