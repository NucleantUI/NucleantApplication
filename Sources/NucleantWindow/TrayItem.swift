//
//  TrayItem.swift
//  NucleantApplication
//
//  An app's item in the system tray: on macOS a menu bar extra, one of the
//  icons at the right end of the menu bar; on Windows a notification area
//  icon, by the clock in the taskbar; on Linux a StatusNotifierItem, in the
//  panel's tray. The platform-neutral description, and `TrayHost`, what a
//  platform provider turns it into. Neither side sees the other's framework
//  types.
//
// https://developer.apple.com/documentation/appkit/nsstatusitem
// https://learn.microsoft.com/windows/win32/shell/notification-area
// https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/
//

/// One item in the system tray: an icon or a title, and what a click on it
/// does. A reference type, so the app keeps the one it inserted, edits it in
/// place and has the host show the change (`TrayHost.refresh(_:)`).
@MainActor
public final class TrayItem {

    /// What it is called. Shown when there is no icon, and read out by
    /// accessibility when there is. Where a tray shows only icons — Windows,
    /// most Linux trays — it is the item's tooltip.
    public var title: String

    /// One of the platform's own named icons: an SF Symbol name on macOS, an
    /// icon-theme name on Linux (`media-playback-start`), the name of an
    /// icon resource in the executable on Windows.
    public var iconName: String?

    /// A bitmap to show, in place of a named icon.
    public var icon: TrayIcon?

    /// Shows the title next to the icon, not only when there is none.
    public var showsTitle: Bool

    /// What a click on it does.
    public var action: Action

    /// Called when the person takes the item out of the tray themselves —
    /// on macOS, by dragging it out of the menu bar with ⌘ held. Without
    /// it, the item can't be taken out. Windows and Linux trays give a
    /// person no way to, so there it is never called.
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

/// Where a tray item is on screen, in the platform's screen coordinates: on
/// macOS AppKit's points, with y going up from the bottom of the main
/// screen; on Windows and X11 pixels, with y going down from the top-left of
/// the whole desktop. Where the tray says only where it was clicked — a
/// Linux tray — it is that point, with no width or height.
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

extension TrayAnchor {
    /// Where the top-left corner of a `width` × `height` window goes for it
    /// to drop from the item, on a screen whose usable part — less its
    /// taskbars and panels — is `workArea`; all in y-down screen
    /// coordinates, Windows' and X11's.
    ///
    /// On the side of the item that faces the rest of the screen, `gap`
    /// away from it, and centred on it the other way: above an item in a
    /// taskbar at the bottom, under one in a panel at the top, beside one in
    /// a taskbar down the side. Then moved, as far as it fits, onto the work
    /// area.
    public func dropDownOrigin(
        width: Double, height: Double, in workArea: TrayAnchor, gap: Double = 4
    ) -> (x: Double, y: Double) {
        let midX = x + self.width / 2, midY = y + self.height / 2
        let areaRight = workArea.x + workArea.width, areaBottom = workArea.y + workArea.height
        var origin: (x: Double, y: Double)
        if midX < workArea.x || midX > areaRight, midY >= workArea.y, midY <= areaBottom {
            // A taskbar down the left or the right.
            origin.x = midX < workArea.x ? x + self.width + gap : x - gap - width
            origin.y = midY - height / 2
        } else {
            let below = midY < workArea.y + workArea.height / 2
            origin.x = midX - width / 2
            origin.y = below ? y + self.height + gap : y - gap - height
        }
        origin.x = max(workArea.x, min(origin.x, areaRight - width))
        origin.y = max(workArea.y, min(origin.y, areaBottom - height))
        return origin
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
