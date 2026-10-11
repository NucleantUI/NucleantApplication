//
//  BrowserAppearance.swift
//  NucleantApplication
//
#if os(WASI)
import CWasmDOM

/// What the page asks to be rendered as.
///
/// `prefers-color-scheme` has no "no preference" any more — a browser always
/// answers light or dark — so unlike Linux's `DesktopColorScheme` there are
/// only the two.
public enum BrowserColorScheme: UInt32, Sendable {
    case light = 0
    case dark = 1
}

/// The page's light/dark preference, and every change to it.
///
/// The browser's counterpart of macOS's `effectiveAppearance` and Linux's
/// `DesktopAppearance`: `prefers-color-scheme`, which the browser takes from
/// the OS setting, or from its own theme setting where that overrides it.
/// The page watches the media query and reports each change through the
/// `nucleant_color_scheme_changed` export, so — as on macOS — a running app
/// follows the switch.
public enum BrowserAppearance {

    private nonisolated(unsafe) static var observers: [Int: (BrowserColorScheme) -> Void] = [:]
    private nonisolated(unsafe) static var nextID = 0
    /// The scheme the page last reported; nil until first asked.
    private nonisolated(unsafe) static var current: BrowserColorScheme?

    /// The page's preference now.
    public static func colorScheme() -> BrowserColorScheme {
        if let current { return current }
        let scheme: BrowserColorScheme = nwd_color_scheme_is_dark() != 0 ? .dark : .light
        current = scheme
        return scheme
    }

    /// Calls `observer` with the new scheme each time the page's preference
    /// changes. Returns the id to hand to `removeObserver(_:)`.
    public static func addObserver(_ observer: @escaping (BrowserColorScheme) -> Void) -> Int {
        let id = nextID
        nextID += 1
        observers[id] = observer
        return id
    }

    public static func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    static func changed(to scheme: BrowserColorScheme) {
        current = scheme
        // An observer may add or remove observers while running.
        for observer in Array(observers.values) {
            observer(scheme)
        }
    }
}

/// The page's `prefers-color-scheme` changed: `dark` is 1 for dark, 0 for
/// light.
@_expose(wasm, "nucleant_color_scheme_changed")
public func nucleantColorSchemeChanged(_ dark: UInt32) {
    BrowserAppearance.changed(to: dark != 0 ? .dark : .light)
}
#endif
