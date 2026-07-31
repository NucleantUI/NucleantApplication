//
//  LinuxSession.swift
//  NucleantApplication
//
#if os(Linux)
import Foundation

/// Which windowing system to talk to. Most desktop Linux is still X11 by
/// default (Cinnamon, MATE, XFCE, and GNOME/KDE whenever their X11 session is
/// what's actually running) — Wayland is only picked when the environment
/// genuinely says so, never assumed.
public enum LinuxSession {
    case wayland
    case x11

    /// `XDG_SESSION_TYPE=wayland` (set by every major display manager for a
    /// Wayland session) or a `WAYLAND_DISPLAY` naming a real socket is treated
    /// as Wayland; everything else — including no session information at all,
    /// e.g. a bare SSH shell — falls back to X11, which is what a `DISPLAY`
    /// forwarded or set locally actually needs.
    public static func detect() -> LinuxSession {
        let env = ProcessInfo.processInfo.environment
        if env["XDG_SESSION_TYPE"] == "wayland" {
            return .wayland
        }
        if let waylandDisplay = env["WAYLAND_DISPLAY"], !waylandDisplay.isEmpty {
            return .wayland
        }
        return .x11
    }
}
#endif
