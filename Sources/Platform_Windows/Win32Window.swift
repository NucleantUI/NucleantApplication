//
//  Win32Window.swift
//  NucleantApplication
//
//  A single top-level Win32 window — the counterpart of `X11Window` and
//  `WaylandSurface`. The window procedure (`Win32EventLoop`) hands every
//  message for it to `handle(_:wParam:lParam:)`; what comes out is the same
//  set of calls the Linux backends make, in points rather than pixels.
//
//  Like X11, Win32 has no per-window frame callback to pace rendering off;
//  `tick(now:)`, driven by the event loop's turns, is the frame clock.
//
#if os(Windows)
import WinSDK

/// What a `Win32Window` reports, the Windows counterpart of
/// `WaylandSurfaceHandler`. Locations are in client-area points: pixels over
/// the window's scale, the space `on_size` reports in.
protocol Win32WindowHandler: AnyObject {
    func win32WindowDidTick(dt: Double)
    func win32WindowDidResize(width: Double, height: Double)
    func win32WindowDidRequestClose()

    func win32PointerDown(at location: SIMD2<Double>)
    func win32PointerUp(at location: SIMD2<Double>)
    func win32PointerDragged(at location: SIMD2<Double>)
    func win32PointerMoved(to location: SIMD2<Double>)
    func win32RightPointerDown(at location: SIMD2<Double>)
    func win32RightPointerUp(at location: SIMD2<Double>)
    func win32Scrolled(dx: Double, dy: Double)

    func win32KeyDown(key: UInt16, chars: String?)
    func win32KeyUp(key: UInt16, chars: String?)

    func win32TouchDown(id: Int, at location: SIMD2<Double>)
    func win32TouchMoved(id: Int, at location: SIMD2<Double>)
    func win32TouchUp(id: Int, at location: SIMD2<Double>)
    func win32TouchCancelled(id: Int, at location: SIMD2<Double>)
}

final class Win32Window {

    weak var handler: Win32WindowHandler?

    let handle: HWND

    /// The client area in pixels, and the window's DPI, as last reported.
    private(set) var pixelWidth: Int32 = 0
    private(set) var pixelHeight: Int32 = 0
    private(set) var dpi: UINT = 96
    private var reportedDPI: UINT = 96

    /// Device pixels per point: the window's DPI over Windows' 96, which
    /// changes as the window moves between monitors.
    var scale: Double { Double(dpi) / 96 }
    var width: Double { Double(pixelWidth) / scale }
    var height: Double { Double(pixelHeight) / scale }
    var bufferWidth: UInt32 { UInt32(max(pixelWidth, 0)) }
    var bufferHeight: UInt32 { UInt32(max(pixelHeight, 0)) }

    private(set) var isDestroyed = false

    private var frameLoopRunning = false
    private var lastFrameTime: Double?

    /// This window's copy of the menu bar. While full screen it is detached
    /// from the window, but kept.
    private var menu: HMENU?
    /// What full screen took away, to put back when it ends.
    private var windowedState: (style: LONG_PTR, placement: WINDOWPLACEMENT)?
    var isFullscreen: Bool { windowedState != nil }

    /// Set while the menu bar changes, so the size in between — the content
    /// shrunk by the new bar, before the window grows around it — isn't
    /// reported.
    private var changingMenu = false

    /// The characters each held key typed, by key code, for its key-up.
    private var heldCharacters: [UInt16: String] = [:]
    /// Fingers down, by pointer id, where each last was.
    private var touches: [UInt32: SIMD2<Double>] = [:]

    private static let style = DWORD(WS_OVERLAPPEDWINDOW)

    /// - Parameters:
    ///   - width: the client area's width in points, at the DPI of the
    ///     monitor the window opens on.
    ///   - height: the client area's height in points.
    ///   - title: shown in the title bar and on the taskbar.
    init(width: Double, height: Double, title: String) throws {
        let loop = Win32EventLoop.shared
        try loop.prepare()
        let created = title.withCString(encodedAs: UTF16.self) { title in
            Win32EventLoop.windowClassName.withUnsafeBufferPointer { className in
                // Placed by Windows (CW_USEDEFAULT), as Linux leaves placement
                // to the window manager; sized below, once it has a DPI.
                CreateWindowExW(
                    0, className.baseAddress, title, Self.style,
                    CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
                    nil, nil, loop.instance, nil
                )
            }
        }
        guard let created else {
            throw Win32Error.windowCreationFailed(GetLastError())
        }
        handle = created
        dpi = GetDpiForWindow(created)
        reportedDPI = dpi
        loop.register(self)

        WindowsAppearance.applyTitleBar(to: created)
        if let template = loop.menuTemplate {
            menu = template.makeMenu()
            SetMenu(created, menu)
        }
        // Only now is the window on a monitor, and so has a DPI to turn the
        // points asked for into pixels with.
        setClientSize(width: width, height: height)
        readClientSize()
    }

    deinit {
        guard !isDestroyed else { return }
        // The window procedure finds nothing for the handle from here on (a
        // weak reference to an object being deinitialized reads nil), so
        // what WM_DESTROY would do is done here.
        Win32EventLoop.shared.unregister(handle)
        if isFullscreen, let menu { DestroyMenu(menu) }
        DestroyWindow(handle)
    }

    // MARK: - Window

    func setTitle(_ title: String) {
        guard !isDestroyed else { return }
        title.withCString(encodedAs: UTF16.self) { title in
            _ = SetWindowTextW(handle, title)
        }
    }

    func minimize() {
        guard !isDestroyed else { return }
        ShowWindow(handle, SW_MINIMIZE)
    }

    func setMaximized(_ maximized: Bool) {
        guard !isDestroyed else { return }
        ShowWindow(handle, maximized ? SW_MAXIMIZE : SW_RESTORE)
    }

    /// Borderless and menu-less over the whole monitor, which Windows treats
    /// as full screen (the taskbar gets out of the way); back to the window
    /// it was, where it was, after.
    func setFullscreen(_ fullscreen: Bool) {
        guard !isDestroyed, fullscreen != isFullscreen else { return }
        if fullscreen {
            var placement = WINDOWPLACEMENT()
            placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
            GetWindowPlacement(handle, &placement)
            let style = GetWindowLongPtrW(handle, GWL_STYLE)
            windowedState = (style, placement)

            var monitor = MONITORINFO()
            monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            GetMonitorInfoW(MonitorFromWindow(handle, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor)
            let area = monitor.rcMonitor
            SetMenu(handle, nil)
            SetWindowLongPtrW(handle, GWL_STYLE, style & ~LONG_PTR(Self.style))
            SetWindowPos(handle, nil, area.left, area.top, area.right - area.left, area.bottom - area.top,
                         UINT(SWP_NOOWNERZORDER | SWP_FRAMECHANGED))
        } else if let windowed = windowedState {
            windowedState = nil
            SetWindowLongPtrW(handle, GWL_STYLE, windowed.style)
            SetMenu(handle, menu)
            var placement = windowed.placement
            SetWindowPlacement(handle, &placement)
            SetWindowPos(handle, nil, 0, 0, 0, 0,
                         UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED))
        }
    }

    func show() {
        guard !isDestroyed else { return }
        ShowWindow(handle, SW_SHOWNORMAL)
    }

    func destroy() {
        guard !isDestroyed else { return }
        DestroyWindow(handle)
    }

    /// Replaces the menu bar with `newMenu` (nil: none). The content keeps
    /// its size and the window grows around the menu bar — the size an app
    /// asked for is its content's — unless the window is maximized, when the
    /// window's size is the monitor's and the content gives way.
    func setMenu(_ newMenu: HMENU?) {
        guard !isDestroyed else {
            if let newMenu { DestroyMenu(newMenu) }
            return
        }
        let old = menu
        menu = newMenu
        if !isFullscreen {
            let size = (width: width, height: height)
            changingMenu = true
            SetMenu(handle, newMenu)
            if !IsZoomed(handle) {
                setClientSize(width: size.width, height: size.height)
            }
            changingMenu = false
            clientAreaChanged()
        }
        if let old { DestroyMenu(old) }
    }

    // MARK: - Frame loop

    func startFrameLoop() {
        frameLoopRunning = true
    }

    func stopFrameLoop() {
        frameLoopRunning = false
    }

    /// Called every event-loop turn, and from the modal-loop timer.
    ///
    /// Not while minimized: the client area is 0×0 then, and so would be the
    /// swapchain's extent. The first frame back gets one frame's Δt rather
    /// than however long the window was down.
    func tick(now: Double) {
        guard frameLoopRunning, !isDestroyed, !IsIconic(handle) else {
            lastFrameTime = nil
            return
        }
        let dt = lastFrameTime.map { now - $0 } ?? (1.0 / 60.0)
        lastFrameTime = now
        handler?.win32WindowDidTick(dt: dt)
    }

    // MARK: - Geometry

    /// Sizes the window so its client area is `width` × `height` points at
    /// its DPI.
    private func setClientSize(width: Double, height: Double) {
        let wanted = (width: Int32((width * scale).rounded()), height: Int32((height * scale).rounded()))
        var rect = RECT(left: 0, top: 0, right: wanted.width, bottom: wanted.height)
        AdjustWindowRectExForDpi(&rect, Self.style, GetMenu(handle) != nil, 0, dpi)
        let flags = UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)
        SetWindowPos(handle, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top, flags)
        // AdjustWindowRectExForDpi counts one row of menu bar, and a window
        // too narrow for its menus wraps them onto more: measured, and made
        // up.
        var client = RECT()
        GetClientRect(handle, &client)
        let short = (width: wanted.width - (client.right - client.left), height: wanted.height - (client.bottom - client.top))
        if short != (0, 0) {
            SetWindowPos(handle, nil, 0, 0, rect.right - rect.left + short.width, rect.bottom - rect.top + short.height, flags)
        }
    }

    /// Re-reads the client area. True if it, or the scale, changed since
    /// last time.
    @discardableResult
    private func readClientSize() -> Bool {
        var rect = RECT()
        GetClientRect(handle, &rect)
        let width = rect.right - rect.left, height = rect.bottom - rect.top
        guard width != pixelWidth || height != pixelHeight || dpi != reportedDPI else { return false }
        pixelWidth = width
        pixelHeight = height
        reportedDPI = dpi
        return true
    }

    private func clientAreaChanged() {
        if readClientSize() {
            handler?.win32WindowDidResize(width: width, height: height)
        }
    }

    /// A client-area position from a mouse message's `lParam`, in points.
    private func point(_ lParam: LPARAM) -> SIMD2<Double> {
        // Signed: a captured drag reports positions left of or above the
        // window as negative.
        let x = Int16(truncatingIfNeeded: lParam), y = Int16(truncatingIfNeeded: lParam >> 16)
        return SIMD2(Double(x), Double(y)) / scale
    }

    /// A client-area position, in points, from a screen position in pixels —
    /// what the pointer messages carry.
    private func point(fromScreen lParam: LPARAM) -> SIMD2<Double> {
        var position = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        ScreenToClient(handle, &position)
        return SIMD2(Double(position.x), Double(position.y)) / scale
    }

    // MARK: - Messages

    /// Answers `message`, or nil to leave it to `DefWindowProcW`.
    func handle(_ message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(bitPattern: message) {
        case WM_SIZE:
            if wParam != WPARAM(SIZE_MINIMIZED), !changingMenu {
                clientAreaChanged()
            }
            return 0

        case WM_DPICHANGED:
            // Moved onto a monitor with another scale: Windows suggests the
            // rect that keeps the window the same size in points.
            dpi = UINT(highWord(wParam))
            if let suggested = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                SetWindowPos(handle, nil, suggested.left, suggested.top,
                             suggested.right - suggested.left, suggested.bottom - suggested.top,
                             UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            clientAreaChanged()
            return 0

        case WM_CLOSE:
            // DefWindowProcW would destroy the window; what closing means is
            // the handler's to say.
            handler?.win32WindowDidRequestClose()
            return 0

        case WM_DESTROY:
            isDestroyed = true
            Win32EventLoop.shared.unregister(handle)
            // Attached, the menu went with the window; detached for full
            // screen, it is still ours.
            if isFullscreen, let menu { DestroyMenu(menu) }
            menu = nil
            return 0

        case WM_ERASEBKGND:
            // Nothing to erase: the swapchain covers the client area.
            return 1

        case WM_PAINT:
            // Validated and nothing else — the frame loop draws. Left
            // invalid, the window would be sent WM_PAINT forever.
            var paint = PAINTSTRUCT()
            BeginPaint(handle, &paint)
            EndPaint(handle, &paint)
            return 0

        case WM_ENTERSIZEMOVE, WM_ENTERMENULOOP:
            Win32EventLoop.shared.enterModalLoop(handle)
            return nil

        case WM_EXITSIZEMOVE, WM_EXITMENULOOP:
            Win32EventLoop.shared.exitModalLoop(handle)
            return nil

        case WM_TIMER:
            guard wParam == WPARAM(Win32EventLoop.modalTimerID) else { return nil }
            Win32EventLoop.shared.tick()
            return 0

        case WM_INITMENUPOPUP:
            if let popup = HMENU(bitPattern: UInt(wParam)) {
                Win32EventLoop.shared.validateMenu(popup)
            }
            return 0

        case WM_COMMAND:
            // From a menu: no control handle, and notification code 0.
            guard lParam == 0, highWord(wParam) == 0 else { return nil }
            return Win32EventLoop.shared.performMenuItem(lowWord(wParam)) ? 0 : nil

        case WM_SETTINGCHANGE:
            // "ImmersiveColorSet": the app mode (light or dark) changed.
            if let area = UnsafePointer<WCHAR>(bitPattern: Int(lParam)),
               String(decodingCString: area, as: UTF16.self) == "ImmersiveColorSet" {
                WindowsAppearance.refresh()
            }
            return nil

        // MARK: Mouse

        case WM_LBUTTONDOWN:
            // Captured, so a drag that leaves the window still reports, and
            // its release arrives here.
            SetCapture(handle)
            handler?.win32PointerDown(at: point(lParam))
            return 0

        case WM_LBUTTONUP:
            releaseCaptureIfUp(wParam)
            handler?.win32PointerUp(at: point(lParam))
            return 0

        case WM_RBUTTONDOWN:
            SetCapture(handle)
            handler?.win32RightPointerDown(at: point(lParam))
            return 0

        case WM_RBUTTONUP:
            releaseCaptureIfUp(wParam)
            handler?.win32RightPointerUp(at: point(lParam))
            return 0

        case WM_MOUSEMOVE:
            let location = point(lParam)
            if wParam & WPARAM(MK_LBUTTON) != 0 {
                handler?.win32PointerDragged(at: location)
            } else {
                handler?.win32PointerMoved(to: location)
            }
            return 0

        case WM_MOUSEWHEEL:
            handler?.win32Scrolled(dx: 0, dy: wheelPoints(wParam))
            return 0

        case WM_MOUSEHWHEEL:
            // Tilted right is positive here; `on_scroll` follows AppKit,
            // where positive is a scroll left — as X11's buttons 6 and 7.
            handler?.win32Scrolled(dx: -wheelPoints(wParam), dy: 0)
            return 0

        // MARK: Keyboard

        case WM_KEYDOWN:
            if performShortcut(wParam) { return 0 }
            keyDown(wParam: wParam, lParam: lParam, typed: true)
            return 0

        case WM_SYSKEYDOWN:
            if performShortcut(wParam) { return 0 }
            // Alt held, or F10. Reported, and then left to DefWindowProcW as
            // well: Alt+F4, Alt+Space and the menu bar's keys are its.
            keyDown(wParam: wParam, lParam: lParam, typed: false)
            return nil

        case WM_KEYUP:
            keyUp(wParam: wParam, lParam: lParam)
            return 0

        case WM_SYSKEYUP:
            keyUp(wParam: wParam, lParam: lParam)
            return nil

        case WM_CHAR:
            // A press's characters reach the window with its key-down (see
            // `typedCharacters`). One that arrives alone came from no key —
            // an input method's composition, which isn't supported yet.
            return 0

        // MARK: Touch

        case WM_POINTERDOWN, WM_POINTERUPDATE, WM_POINTERUP, WM_POINTERCAPTURECHANGED:
            return touch(message, wParam: wParam, lParam: lParam) ? 0 : nil

        default:
            return nil
        }
    }

    /// Lets go of the mouse once no button is down any more. `wParam` is the
    /// buttons still held after this release.
    private func releaseCaptureIfUp(_ wParam: WPARAM) {
        let buttons = WPARAM(MK_LBUTTON | MK_RBUTTON | MK_MBUTTON)
        if wParam & buttons == 0, GetCapture() == handle {
            ReleaseCapture()
        }
    }

    /// `on_scroll`'s points for a wheel message: notches of WHEEL_DELTA, each
    /// as many lines as the user's wheel setting asks for, at the 16 points a
    /// line Platform_MacOS and X11 scroll by. Precision touchpads send parts
    /// of a notch, which scroll by that part.
    private func wheelPoints(_ wParam: WPARAM) -> Double {
        let delta = Double(Int16(truncatingIfNeeded: wParam >> 16))
        var lines: UINT = 3
        SystemParametersInfoW(UINT(SPI_GETWHEELSCROLLLINES), 0, &lines, 0)
        // WHEEL_PAGESCROLL: a page per notch, which a view's points can't
        // express. Three lines, the default, instead.
        if lines == UINT.max { lines = 3 }
        return delta / Double(WHEEL_DELTA) * Double(lines) * 16
    }

    // MARK: Keys

    /// A press that is a menu command's shortcut runs the command and goes
    /// no further: not to the handler, and not as the characters
    /// `TranslateMessage` already queued for it.
    private func performShortcut(_ wParam: WPARAM) -> Bool {
        guard Win32EventLoop.shared.performShortcut(virtualKey: UInt16(truncatingIfNeeded: wParam)) else { return false }
        var message = MSG()
        while PeekMessageW(&message, handle, UINT(WM_CHAR), UINT(WM_CHAR), UINT(PM_REMOVE)) {}
        while PeekMessageW(&message, handle, UINT(WM_SYSCHAR), UINT(WM_SYSCHAR), UINT(PM_REMOVE)) {}
        return true
    }

    private func keyDown(wParam: WPARAM, lParam: LPARAM, typed: Bool) {
        let virtualKey = UInt32(truncatingIfNeeded: wParam)
        let key = Win32KeyMap.keyCode(lParam: lParam, virtualKey: virtualKey)
        let characters = Win32KeyMap.characters(
            typed: typed ? typedCharacters() : [],
            keyCode: key,
            virtualKey: virtualKey,
            scanCode: UInt32(truncatingIfNeeded: lParam >> 16) & 0xFF
        )
        heldCharacters[key] = characters
        handler?.win32KeyDown(key: key, chars: characters)
    }

    private func keyUp(wParam: WPARAM, lParam: LPARAM) {
        let key = Win32KeyMap.keyCode(lParam: lParam, virtualKey: UInt32(truncatingIfNeeded: wParam))
        let characters = heldCharacters.removeValue(forKey: key) ?? Win32KeyMap.characters(forKeyCode: key)
        handler?.win32KeyUp(key: key, chars: characters)
    }

    /// The text this press typed, in UTF-16: the WM_CHARs `TranslateMessage`
    /// queued for it, which are next in the queue while its WM_KEYDOWN is
    /// being handled — two of them for a character beyond the BMP. Taken
    /// out, so the key-down carries its characters, as on every other
    /// platform.
    private func typedCharacters() -> [UInt16] {
        var units: [UInt16] = []
        var message = MSG()
        while PeekMessageW(&message, handle, UINT(WM_CHAR), UINT(WM_CHAR), UINT(PM_REMOVE)) {
            units.append(UInt16(truncatingIfNeeded: message.wParam))
        }
        return units
    }

    // MARK: Touch

    /// A finger, from the pointer messages. True if it was one — pens and the
    /// mouse are left alone, and Windows turns them into mouse messages, as
    /// it would a finger's that went unhandled.
    private func touch(_ message: UINT, wParam: WPARAM, lParam: LPARAM) -> Bool {
        let id = UInt32(truncatingIfNeeded: wParam & 0xFFFF)
        if message == UINT(WM_POINTERCAPTURECHANGED) {
            guard let last = touches.removeValue(forKey: id) else { return false }
            handler?.win32TouchCancelled(id: Int(id), at: last)
            return true
        }
        var type = POINTER_INPUT_TYPE(0)
        guard GetPointerType(id, &type), type == POINTER_INPUT_TYPE(PT_TOUCH.rawValue) else { return false }

        let location = point(fromScreen: lParam)
        switch Int32(bitPattern: message) {
        case WM_POINTERDOWN:
            touches[id] = location
            handler?.win32TouchDown(id: Int(id), at: location)
        case WM_POINTERUPDATE:
            guard touches[id] != nil else { return true }
            touches[id] = location
            handler?.win32TouchMoved(id: Int(id), at: location)
        default: // WM_POINTERUP
            guard touches.removeValue(forKey: id) != nil else { return true }
            if UInt32(highWord(wParam)) & UInt32(POINTER_FLAG_CANCELED) != 0 {
                handler?.win32TouchCancelled(id: Int(id), at: location)
            } else {
                handler?.win32TouchUp(id: Int(id), at: location)
            }
        }
        return true
    }
}

private func lowWord(_ value: WPARAM) -> UInt16 {
    UInt16(truncatingIfNeeded: value)
}

private func highWord(_ value: WPARAM) -> UInt16 {
    UInt16(truncatingIfNeeded: value >> 16)
}
#endif
