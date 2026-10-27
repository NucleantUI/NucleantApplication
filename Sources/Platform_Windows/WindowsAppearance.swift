//
//  WindowsAppearance.swift
//  NucleantApplication
//
#if os(Windows)
import WinSDK

/// What Windows asks apps to render as. The app mode has no "no
/// preference": it is always one or the other.
public enum WindowsColorScheme: Sendable {
    case light
    case dark
}

/// The app mode — Settings › Personalization › Colors, "Choose your app
/// mode" — and every change to it.
///
/// The Windows counterpart of macOS's `effectiveAppearance`, Linux's
/// `DesktopAppearance` and the page's `BrowserAppearance`. Windows keeps the
/// setting in the registry (`AppsUseLightTheme`), which is where every
/// toolkit reads it, and announces a change by sending every top-level
/// window WM_SETTINGCHANGE for "ImmersiveColorSet" — so, as on macOS, a
/// running app follows the switch. Title bars follow it too: dark mode on
/// Windows is something each window opts its frame into.
public enum WindowsAppearance {

    private nonisolated(unsafe) static var observers: [Int: (WindowsColorScheme) -> Void] = [:]
    private nonisolated(unsafe) static var nextID = 0
    /// The mode last read; nil until first asked.
    private nonisolated(unsafe) static var current: WindowsColorScheme?

    /// The app mode now.
    public static func colorScheme() -> WindowsColorScheme {
        if let current { return current }
        let scheme = readSetting()
        current = scheme
        return scheme
    }

    /// Calls `observer` with the new mode each time it changes. Returns the
    /// id to hand to `removeObserver(_:)`.
    public static func addObserver(_ observer: @escaping (WindowsColorScheme) -> Void) -> Int {
        let id = nextID
        nextID += 1
        observers[id] = observer
        return id
    }

    public static func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    /// Reads the setting again, after Windows said it changed. Every window
    /// hears the broadcast, so this runs once per window; only the first
    /// finds anything new.
    static func refresh() {
        let scheme = readSetting()
        guard scheme != current else { return }
        current = scheme
        for window in Win32EventLoop.shared.liveWindows {
            applyTitleBar(to: window.handle)
        }
        // An observer may add or remove observers while running.
        for observer in Array(observers.values) {
            observer(scheme)
        }
    }

    /// A dark title bar and frame in dark mode, as Windows' own apps have.
    /// Windows 11, and 10 from 20H1; earlier, refused and left light.
    static func applyTitleBar(to handle: HWND) {
        var dark: WindowsBool = colorScheme() == .dark ? true : false
        _ = DwmSetWindowAttribute(
            handle,
            DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue),
            &dark,
            DWORD(MemoryLayout<WindowsBool>.size)
        )
    }

    /// `AppsUseLightTheme` is 1 for light and 0 for dark. Missing — a
    /// Windows that predates the setting — is light, Windows' default.
    private static func readSetting() -> WindowsColorScheme {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".withCString(encodedAs: UTF16.self) { key in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == ERROR_SUCCESS && value == 0 ? .dark : .light
    }
}
#endif
