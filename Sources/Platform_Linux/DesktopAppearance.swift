//
//  DesktopAppearance.swift
//  NucleantApplication
//
#if os(Linux)
import Foundation

/// What the desktop asks applications to render as.
///
/// The values are `org.freedesktop.appearance color-scheme`'s own, so the
/// portal's reply maps straight onto this.
public enum DesktopColorScheme: UInt32, Sendable {
    case noPreference = 0
    case dark = 1
    case light = 2
}

/// The desktop's light/dark preference, read from the XDG desktop portal.
///
/// There is no X11 or Wayland protocol for this — it is a desktop setting, not
/// a display-server one — so the cross-desktop answer is the portal's
/// `org.freedesktop.appearance color-scheme`, which is what GTK, Qt, Firefox
/// and Chrome all read. Every desktop that has the setting exposes it there:
/// GNOME through xdg-desktop-portal-gnome, KDE through -kde, and Cinnamon,
/// MATE and Xfce through -xapp.
///
/// Deliberately *not* gsettings: `org.gnome.desktop.interface color-scheme`
/// exists on a Cinnamon session but nothing maintains it, so it reads
/// `'default'` on a Mint desktop that is plainly dark. The portal answers
/// correctly on the same machine.
///
/// Over the module's own D-Bus connection (`DBusConnection`), which speaks
/// the wire protocol rather than linking libdbus. Anything unexpected — no
/// bus, no portal, a desktop without the setting — is `.noPreference`, never
/// a failure.
public enum DesktopAppearance {

    /// Ask the portal. Returns `.noPreference` if there is nobody to ask.
    ///
    /// Blocking, with a short timeout: called once while the first window is
    /// being built, where the alternative is drawing the wrong scheme and
    /// correcting it a frame later.
    public static func colorScheme() -> DesktopColorScheme {
        guard let bus = DBusConnection.session() else { return .noPreference }
        defer { bus.close() }

        // `ReadOne` returns the value; the older `Read` wraps it in a second
        // variant. Portals still in the field implement one or the other, so
        // try the current name and fall back on any error.
        for method in ["ReadOne", "Read"] {
            guard let reply = bus.call(
                .methodCall(
                    destination: "org.freedesktop.portal.Desktop",
                    path: "/org/freedesktop/portal/desktop",
                    interface: "org.freedesktop.portal.Settings",
                    member: method,
                    body: [.string("org.freedesktop.appearance"), .string("color-scheme")]
                ),
                timeout: 1
            ), reply.kind == .methodReturn, let value = reply.body.first?.uint32 else { continue }
            if let scheme = DesktopColorScheme(rawValue: value) { return scheme }
            // A value outside the enum is a desktop inventing its own; treat
            // it as "no preference" rather than guessing which way it meant.
            return .noPreference
        }
        return .noPreference
    }
}
#endif
