//
//  Win32EventLoop.swift
//  NucleantApplication
//
//  The process-wide half of Win32: the DPI awareness the process runs with,
//  the window class every window is made from, the live windows, and the
//  message loop. The part `X11Display` and `WaylandDisplay` play on Linux,
//  minus a connection: there is no display server to connect to, so what is
//  left of `connect()` is `prepare()`, which sets the process up before its
//  first window.
//
#if os(Windows)
import Foundation
import WinSDK

public enum Win32Error: Error, CustomStringConvertible {
    /// `run()` before `setup()`: there is no lifecycle object to run.
    case notSetUp
    case classRegistrationFailed(DWORD)
    case windowCreationFailed(DWORD)

    public var description: String {
        switch self {
        case .notSetUp:
            return "the app was never set up: call setup() before run()"
        case .classRegistrationFailed(let code):
            return "the window class could not be registered (error \(code))"
        case .windowCreationFailed(let code):
            return "the window could not be created (error \(code))"
        }
    }
}

/// Seconds on the performance counter: the monotonic clock frame times and
/// `FrameLoopTurn` are measured on.
func win32MonotonicSeconds() -> Double {
    var counter = LARGE_INTEGER()
    QueryPerformanceCounter(&counter)
    return Double(counter.QuadPart) / performanceCounterFrequency
}

private let performanceCounterFrequency: Double = {
    var frequency = LARGE_INTEGER()
    QueryPerformanceFrequency(&frequency)
    return Double(frequency.QuadPart)
}()

/// Single-threaded by construction, same contract as `X11Display`: Win32
/// delivers a window's messages to the thread that created it, so windows are
/// made, and every message handled, on the thread that calls `run()`.
public final class Win32EventLoop {

    public nonisolated(unsafe) static let shared = Win32EventLoop()

    /// The window class's name, NUL-terminated for `CreateWindowExW`.
    static let windowClassName: [WCHAR] = Array("NucleantWindow".utf16) + [0]

    /// The module the window class is registered to: the executable's own.
    public let instance: HINSTANCE = GetModuleHandleW(nil)!

    private var classRegistered = false

    /// Live windows, keyed by their handle. Weak, as in `X11Display`: a
    /// window's lifetime belongs to whoever created it.
    private var windows: [HWND: WeakWindow] = [:]
    private struct WeakWindow {
        weak var window: Win32Window?
    }

    /// The installed menu bar, which every window gets its own copy of.
    private(set) var menuTemplate: Win32MenuTemplate?

    private var running = false

    private init() {}

    // MARK: - Prepare

    /// Per-monitor DPI awareness, and the window class. Idempotent; every
    /// window calls it too, so one made outside `run()` (a test) works.
    public func prepare() throws {
        guard !classRegistered else { return }

        // Per-monitor v2: the process sees real pixels on every monitor, and
        // hears through WM_DPICHANGED when a window moves to one with another
        // scale, rather than being bitmap-stretched by the system. Refused,
        // harmlessly, when the executable's manifest has already chosen.
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = win32WindowProcedure
        windowClass.hInstance = instance
        // IDC_ARROW is MAKEINTRESOURCE(32512), a cast Swift doesn't import.
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer(bitPattern: 32512))
        // No background brush: every pixel comes from the swapchain, and a
        // window erased to white first is what flickers on resize.
        let atom = Self.windowClassName.withUnsafeBufferPointer { name in
            windowClass.lpszClassName = name.baseAddress
            return RegisterClassExW(&windowClass)
        }
        guard atom != 0 else {
            throw Win32Error.classRegistrationFailed(GetLastError())
        }
        classRegistered = true
    }

    // MARK: - Window registry

    func register(_ window: Win32Window) {
        windows[window.handle] = WeakWindow(window: window)
    }

    func unregister(_ handle: HWND) {
        windows.removeValue(forKey: handle)
    }

    /// Whether every window is gone — what `PlatformWindow`'s default close
    /// handler checks before stopping the loop, so closing one of several
    /// windows doesn't end the whole app.
    var hasNoLiveWindows: Bool { liveWindows.isEmpty }

    var liveWindows: [Win32Window] {
        windows.values.compactMap(\.window)
    }

    func window(for handle: HWND) -> Win32Window? {
        guard let box = windows[handle] else { return nil }
        guard let window = box.window else {
            windows.removeValue(forKey: handle)
            return nil
        }
        return window
    }

    // MARK: - Menu bar

    /// Puts `template` up as every window's menu bar, now and for windows
    /// made later; nil takes it down.
    func installMenu(_ template: Win32MenuTemplate?) {
        menuTemplate = template
        for window in liveWindows {
            window.setMenu(template?.makeMenu())
        }
    }

    /// Runs the command behind menu item `id`. False if there is none.
    @discardableResult
    func performMenuItem(_ id: UInt16) -> Bool {
        guard let command = menuTemplate?.commands[id] else { return false }
        MainActor.assumeIsolated {
            if command.isEnabled() { command.perform() }
        }
        return true
    }

    /// Brings the items of a menu about to open up to date with their
    /// commands' `isEnabled`, which an app changes in place.
    func validateMenu(_ menu: HMENU) {
        guard let template = menuTemplate else { return }
        for position in 0..<max(GetMenuItemCount(menu), 0) {
            let id = GetMenuItemID(menu, position)
            guard id != UINT.max, let command = template.commands[UInt16(truncatingIfNeeded: id)] else { continue }
            let enabled = MainActor.assumeIsolated { command.isEnabled() }
            EnableMenuItem(menu, id, UINT(MF_BYCOMMAND) | UINT(enabled ? MF_ENABLED : MF_GRAYED))
        }
    }

    /// Runs the menu command whose shortcut `virtualKey` is, with the
    /// modifiers held now — what `TranslateAcceleratorW` does. False if it is
    /// none, or its command is disabled: then the press is an ordinary key.
    func performShortcut(virtualKey: UInt16) -> Bool {
        guard let template = menuTemplate else { return false }
        let pressed = Win32Shortcut(
            virtualKey: virtualKey,
            control: GetKeyState(VK_CONTROL) < 0,
            alt: GetKeyState(VK_MENU) < 0,
            shift: GetKeyState(VK_SHIFT) < 0
        )
        guard let id = template.shortcuts[pressed], let command = template.commands[id] else { return false }
        return MainActor.assumeIsolated {
            guard command.isEnabled() else { return false }
            command.perform()
            return true
        }
    }

    // MARK: - Event loop

    /// Runs until `stop()`, or until the last window closes with no
    /// `on_close` to say otherwise.
    ///
    /// Each turn also gives Foundation's main run loop one pass: nothing else
    /// runs it here, and it is what drains the main dispatch queue — so
    /// `DispatchQueue.main.async`, `Task { @MainActor in … }` and `Timer`s
    /// run, as they do under `NSApplication.run()`. Not in `pumpEvents`,
    /// which a test calls from inside a main-actor job. That pass can
    /// dispatch window messages itself, so nothing a window needs may happen
    /// only here, between `PeekMessageW` and `DispatchMessageW`: shortcuts
    /// are matched in the window procedure.
    public func run() {
        running = true
        while running {
            pumpEvents(timeoutMilliseconds: Self.waitMilliseconds)
            _ = RunLoop.main.run(mode: .default, before: Date())
        }
    }

    public func stop() {
        running = false
    }

    /// The longest a turn waits for a message. Every turn ticks the windows,
    /// so this is also the slowest the frame loop runs when nothing happens.
    /// Rendering itself is paced by the swapchain, whose present waits for
    /// the display, as on Linux.
    private static let waitMilliseconds: DWORD = 8

    /// One turn: every queued message, one tick of every window, then a wait
    /// of up to `timeoutMilliseconds` for the next message.
    public func pumpEvents(timeoutMilliseconds: DWORD = 0) {
        var message = MSG()
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            if message.message == UINT(WM_QUIT) {
                running = false
                return
            }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        tick()
        _ = MsgWaitForMultipleObjectsEx(0, nil, timeoutMilliseconds, QS_ALLINPUT, DWORD(MWMO_INPUTAVAILABLE))
    }

    /// Fires `FrameLoopTurn`, and gives every window whose frame loop is
    /// running its frame.
    func tick() {
        let now = win32MonotonicSeconds()
        FrameLoopTurn.fire(now: now)
        for (handle, box) in windows {
            guard let window = box.window else {
                windows.removeValue(forKey: handle)
                continue
            }
            window.tick(now: now)
        }
    }

    // MARK: - Modal loops

    /// While a window is dragged or resized, or one of its menus is open,
    /// Win32 runs a loop of its own inside `DispatchMessageW`, and `run()`
    /// gets no turns until it ends. A timer on the window keeps the frames
    /// coming meanwhile: its WM_TIMER is delivered by that loop.
    static let modalTimerID: UINT_PTR = 1

    func enterModalLoop(_ handle: HWND) {
        SetTimer(handle, Self.modalTimerID, UINT(USER_TIMER_MINIMUM), nil)
    }

    func exitModalLoop(_ handle: HWND) {
        KillTimer(handle, Self.modalTimerID)
    }
}

/// Every window's window procedure: the `Win32Window` behind the handle
/// answers what it handles, and `DefWindowProcW` the rest.
private func win32WindowProcedure(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let hwnd, let window = Win32EventLoop.shared.window(for: hwnd),
       let result = window.handle(message, wParam: wParam, lParam: lParam) {
        return result
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}
#endif
