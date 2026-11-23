//
//  Win32Tray.swift
//  NucleantApplication
//
//  The system tray on Windows: the notification area, by the clock in the
//  taskbar. An item is a notification icon (`Shell_NotifyIconW`), and what
//  happens to it — a click, the keyboard, a right click — comes back as
//  messages to a window of the tray's own.
//
// https://learn.microsoft.com/windows/win32/shell/notification-area
// https://learn.microsoft.com/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw
//
#if os(Windows)
import Foundation
import NucleantWindow
import WinSDK

/// `TrayHost` for Win32: one notification icon per `TrayItem`.
///
/// A `.menu` item's rows drop up as a popup menu from where it was clicked,
/// on the left button or the right, as Windows' own tray menus do. A
/// `.press` item hands the app the icon's rectangle on a left click (or
/// Enter on it), in screen pixels.
///
/// The icon is the item's bitmap, else the executable's icon resource named
/// `iconName`, else the executable's own icon, else Windows' generic one. A
/// notification icon is only an icon: the title is its tooltip, and
/// `showsTitle` has nothing to show it in. Windows gives a person no way to
/// take an icon out — only to tuck it into the overflow — so `onRemove` is
/// never called.
///
/// The icons are put back when Explorer restarts (`TaskbarCreated`), and
/// should be taken out before the app exits (`removeAll()`): an icon whose
/// process is gone stays in the taskbar until the pointer passes over it.
@MainActor
public final class Win32Tray: TrayHost {

    private final class Entry {
        let item: TrayItem
        let id: UINT
        var icon: HICON?
        /// Made for this item, and destroyed with it — not one of Windows'
        /// shared icons.
        var ownsIcon = false
        /// In the notification area now.
        var isAdded = false

        init(item: TrayItem, id: UINT) {
            self.item = item
            self.id = id
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextID: UINT = 1
    private var window: HWND?

    /// The rows of the menu last opened, by the id their WM_COMMAND carries.
    private var menuCommands: [UInt16: MenuBar.Command] = [:]

    public init() {}

    public func insert(_ item: TrayItem) {
        let key = ObjectIdentifier(item)
        guard entries[key] == nil else {
            refresh(item)
            return
        }
        guard makeWindow() != nil else {
            logTrayProblem("NucleantApplication: no window for the notification area to talk to; \"\(item.title)\" is not shown\n")
            return
        }
        let entry = Entry(item: item, id: nextID)
        nextID += 1
        entries[key] = entry
        setIcon(of: entry)
        add(entry)
    }

    public func refresh(_ item: TrayItem) {
        guard let entry = entries[ObjectIdentifier(item)] else { return }
        let old = entry.ownsIcon ? entry.icon : nil
        setIcon(of: entry)
        if entry.isAdded {
            var data = notifyData(for: entry)
            _ = Shell_NotifyIconW(Self.nimModify, &data)
        } else {
            add(entry)
        }
        if let old { DestroyIcon(old) }
    }

    public func remove(_ item: TrayItem) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(item)) else { return }
        delete(entry)
    }

    /// Takes every icon out — as the app quits, so none is left behind in
    /// the taskbar.
    public func removeAll() {
        for entry in entries.values { delete(entry) }
        entries = [:]
    }

    // MARK: Icons in the notification area

    private func add(_ entry: Entry) {
        var data = notifyData(for: entry)
        guard Shell_NotifyIconW(Self.nimAdd, &data) else {
            // No taskbar yet — Explorer starting, or restarting. It says
            // `TaskbarCreated` when it is up, and the icon goes in then.
            entry.isAdded = false
            return
        }
        entry.isAdded = true
        // The current behaviour: NIN_SELECT and WM_CONTEXTMENU, with the
        // place they happened at.
        data.uVersion = Self.notifyIconVersion4
        _ = Shell_NotifyIconW(Self.nimSetVersion, &data)
    }

    private func delete(_ entry: Entry) {
        if entry.isAdded {
            var data = notifyData(for: entry)
            _ = Shell_NotifyIconW(Self.nimDelete, &data)
            entry.isAdded = false
        }
        if entry.ownsIcon, let icon = entry.icon { DestroyIcon(icon) }
        entry.icon = nil
    }

    private func notifyData(for entry: Entry) -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = entry.id
        data.uFlags = Self.nifMessage | Self.nifIcon | Self.nifTip | Self.nifShowTip
        data.uCallbackMessage = Self.callbackMessage
        data.hIcon = entry.icon
        let tip = Array(entry.item.title.utf16.prefix(127))
        withUnsafeMutableBytes(of: &data.szTip) { raw in
            let units = raw.bindMemory(to: UInt16.self)
            for (index, unit) in tip.enumerated() { units[index] = unit }
            units[tip.count] = 0
        }
        return data
    }

    private func setIcon(of entry: Entry) {
        let (icon, owned) = Self.icon(for: entry.item)
        entry.icon = icon
        entry.ownsIcon = owned
    }

    /// The icon `item` shows, and whether it was made for it.
    private static func icon(for item: TrayItem) -> (HICON?, owned: Bool) {
        if let bitmap = item.icon, let icon = makeIcon(bitmap) {
            return (icon, true)
        }
        let instance = GetModuleHandleW(nil)
        let size = (GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON))
        if let name = item.iconName {
            let loaded = name.withCString(encodedAs: UTF16.self) {
                LoadImageW(instance, $0, UINT(IMAGE_ICON), size.0, size.1, 0)
            }
            if let loaded { return (HICON(OpaquePointer(loaded)), true) }
        }
        var path = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        if GetModuleFileNameW(nil, &path, DWORD(MAX_PATH)) > 0 {
            var small: HICON?
            if ExtractIconExW(path, 0, nil, &small, 1) > 0, let small {
                return (small, true)
            }
        }
        // IDI_APPLICATION is MAKEINTRESOURCE(32512), a cast Swift doesn't
        // import. Shared: never destroyed.
        return (LoadIconW(nil, UnsafePointer(bitPattern: 32512)), false)
    }

    /// An icon from a bitmap: a 32-bit top-down DIB with its alpha, which
    /// an icon has straight rather than premultiplied.
    private static func makeIcon(_ bitmap: TrayIcon) -> HICON? {
        guard bitmap.width > 0, bitmap.height > 0, bitmap.pixels.count == bitmap.width * bitmap.height else {
            return nil
        }
        var header = BITMAPV5HEADER()
        header.bV5Size = DWORD(MemoryLayout<BITMAPV5HEADER>.size)
        header.bV5Width = LONG(bitmap.width)
        header.bV5Height = -LONG(bitmap.height)
        header.bV5Planes = 1
        header.bV5BitCount = 32
        header.bV5Compression = DWORD(BI_BITFIELDS)
        header.bV5RedMask = 0x00FF_0000
        header.bV5GreenMask = 0x0000_FF00
        header.bV5BlueMask = 0x0000_00FF
        header.bV5AlphaMask = 0xFF00_0000

        let screen = GetDC(nil)
        var bits: UnsafeMutableRawPointer?
        let color = withUnsafePointer(to: &header) {
            $0.withMemoryRebound(to: BITMAPINFO.self, capacity: 1) {
                CreateDIBSection(screen, $0, UINT(DIB_RGB_COLORS), &bits, nil, 0)
            }
        }
        ReleaseDC(nil, screen)
        guard let color, let bits else { return nil }
        let words = bits.assumingMemoryBound(to: UInt32.self)
        for (index, pixel) in bitmap.pixels.enumerated() {
            words[index] = straightAlpha(pixel)
        }
        let mask = CreateBitmap(Int32(bitmap.width), Int32(bitmap.height), 1, 1, nil)
        var info = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
        let icon = CreateIconIndirect(&info)
        DeleteObject(UnsafeMutableRawPointer(color))
        if let mask { DeleteObject(UnsafeMutableRawPointer(mask)) }
        return icon
    }

    private static func straightAlpha(_ pixel: UInt32) -> UInt32 {
        let alpha = pixel >> 24
        guard alpha > 0, alpha < 255 else { return alpha == 0 ? 0 : pixel }
        func channel(_ shift: UInt32) -> UInt32 {
            min(255, (((pixel >> shift) & 0xFF) * 255 + alpha / 2) / alpha) << shift
        }
        return alpha << 24 | channel(16) | channel(8) | channel(0)
    }

    // MARK: The tray's window

    /// A hidden top-level window: what the icons' messages come to. Not a
    /// message-only one, which would miss `TaskbarCreated`, a broadcast to
    /// top-level windows — and the popup menus need a window to go with.
    private func makeWindow() -> HWND? {
        if let window { return window }
        let instance = GetModuleHandleW(nil)
        if !Self.classRegistered {
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = trayWindowProcedure
            windowClass.hInstance = instance
            let atom = Self.className.withUnsafeBufferPointer { name in
                windowClass.lpszClassName = name.baseAddress
                return RegisterClassExW(&windowClass)
            }
            guard atom != 0 else { return nil }
            Self.classRegistered = true
        }
        let created = Self.className.withUnsafeBufferPointer {
            CreateWindowExW(0, $0.baseAddress, nil, DWORD(WS_POPUP), 0, 0, 0, 0, nil, nil, instance, nil)
        }
        guard let created else { return nil }
        SetWindowLongPtrW(created, GWLP_USERDATA, LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())))
        window = created
        return created
    }

    /// Answers a message to the tray's window, or nil to leave it to
    /// `DefWindowProcW`.
    fileprivate func handle(_ message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        if message == Self.callbackMessage {
            // NOTIFYICON_VERSION_4: the event and the icon in lParam, where
            // it happened — the pointer, or the icon for the keyboard — in
            // wParam.
            let event = UINT(lParam & 0xFFFF)
            let id = UINT((lParam >> 16) & 0xFFFF)
            let x = Int32(Int16(truncatingIfNeeded: wParam)), y = Int32(Int16(truncatingIfNeeded: wParam >> 16))
            guard let entry = entries.values.first(where: { $0.id == id }) else { return 0 }
            switch event {
            case Self.ninSelect, Self.ninKeySelect:
                activate(entry, x: x, y: y)
            case UINT(WM_CONTEXTMENU):
                if case .menu(let rows) = entry.item.action {
                    showMenu(rows, x: x, y: y)
                }
            default:
                break
            }
            return 0
        }
        if message == Self.taskbarCreated {
            // Explorer restarted, and its new taskbar has none of the icons.
            for entry in entries.values {
                entry.isAdded = false
                add(entry)
            }
            return 0
        }
        switch Int32(bitPattern: message) {
        case WM_COMMAND:
            guard lParam == 0, (wParam >> 16) & 0xFFFF == 0,
                  let command = menuCommands[UInt16(truncatingIfNeeded: wParam)] else { return nil }
            if command.isEnabled { command.action() }
            return 0
        case WM_ENTERMENULOOP:
            // Win32 runs its own loop while the menu is open; the windows
            // keep their frames through a timer, as with their own menus.
            if let window { Win32EventLoop.shared.enterModalLoop(window) }
            return nil
        case WM_EXITMENULOOP:
            if let window { Win32EventLoop.shared.exitModalLoop(window) }
            return nil
        case WM_TIMER:
            guard wParam == WPARAM(Win32EventLoop.modalTimerID) else { return nil }
            Win32EventLoop.shared.tick()
            return 0
        default:
            return nil
        }
    }

    /// A left click, or Enter: the menu, or the press with the icon's
    /// rectangle.
    private func activate(_ entry: Entry, x: Int32, y: Int32) {
        switch entry.item.action {
        case .menu(let rows):
            showMenu(rows, x: x, y: y)
        case .press(let pressed):
            var identifier = NOTIFYICONIDENTIFIER()
            identifier.cbSize = DWORD(MemoryLayout<NOTIFYICONIDENTIFIER>.size)
            identifier.hWnd = window
            identifier.uID = entry.id
            var rect = RECT()
            let anchor = Shell_NotifyIconGetRect(&identifier, &rect) == S_OK
                ? TrayAnchor(x: Double(rect.left), y: Double(rect.top),
                             width: Double(rect.right - rect.left), height: Double(rect.bottom - rect.top))
                : TrayAnchor(x: Double(x), y: Double(y), width: 0, height: 0)
            pressed(anchor)
        }
    }

    // MARK: The menu

    /// `rows` as a popup menu at `x`, `y`, rising from the taskbar. The
    /// chosen row comes back as a WM_COMMAND.
    private func showMenu(_ rows: [MenuBar.Item], x: Int32, y: Int32) {
        guard let window, let menu = CreatePopupMenu() else { return }
        menuCommands = [:]
        var nextID: UInt16 = 1
        append(rows, to: menu, nextID: &nextID)
        // In the foreground, so a click anywhere else closes the menu; and
        // a message after, so a second click on the icon opens it again.
        SetForegroundWindow(window)
        let alignment = GetSystemMetrics(SM_MENUDROPALIGNMENT) != 0 ? TPM_RIGHTALIGN : TPM_LEFTALIGN
        _ = TrackPopupMenuEx(menu, UINT(alignment | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON), x, y, window, nil)
        PostMessageW(window, UINT(WM_NULL), 0, 0)
        DestroyMenu(menu)
    }

    private func append(_ rows: [MenuBar.Item], to menu: HMENU, nextID: inout UInt16) {
        for row in rows {
            switch row {
            case .divider:
                AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
            case .command(let command):
                let id = nextID
                nextID += 1
                menuCommands[id] = command
                var label = Self.escaped(command.title)
                if let shortcut = command.shortcut, let keys = Win32Shortcut(shortcut) {
                    label += "\t" + keys.displayName(for: shortcut.key)
                }
                let flags = UINT(MF_STRING) | UINT(command.isEnabled ? MF_ENABLED : MF_GRAYED)
                label.withCString(encodedAs: UTF16.self) { _ = AppendMenuW(menu, flags, UINT_PTR(id), $0) }
            case .submenu(let submenu):
                guard let popup = CreatePopupMenu() else { continue }
                append(submenu.items, to: popup, nextID: &nextID)
                Self.escaped(submenu.title).withCString(encodedAs: UTF16.self) {
                    _ = AppendMenuW(menu, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: popup)), $0)
                }
            }
        }
    }

    /// A literal "&": a single one marks the next letter as the row's Alt
    /// key.
    private static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "&", with: "&&")
    }

    // MARK: Constants

    static let className: [WCHAR] = Array("NucleantTray".utf16) + [0]
    private static var classRegistered = false

    /// What the icons' messages arrive as.
    static let callbackMessage = UINT(WM_APP) + 1

    /// Broadcast when Explorer's taskbar (re)starts.
    private static let taskbarCreated: UINT = "TaskbarCreated".withCString(encodedAs: UTF16.self) {
        RegisterWindowMessageW($0)
    }

    // shellapi.h's, spelled out: some are macros Swift doesn't import.
    private static let nimAdd = DWORD(0)
    private static let nimModify = DWORD(1)
    private static let nimDelete = DWORD(2)
    private static let nimSetVersion = DWORD(4)
    private static let nifMessage = UINT(0x01)
    private static let nifIcon = UINT(0x02)
    private static let nifTip = UINT(0x04)
    private static let nifShowTip = UINT(0x80)
    private static let notifyIconVersion4 = UINT(4)
    private static let ninSelect = UINT(WM_USER) + 0
    private static let ninKeySelect = UINT(WM_USER) + 1
}

/// The tray's window procedure: its `Win32Tray` is in the window's user
/// data.
private func trayWindowProcedure(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let hwnd, let tray = UnsafeRawPointer(bitPattern: Int(GetWindowLongPtrW(hwnd, GWLP_USERDATA))) {
        let host = Unmanaged<Win32Tray>.fromOpaque(tray).takeUnretainedValue()
        // Window messages come on the thread that made the window: the main
        // one.
        if let result = MainActor.assumeIsolated({ host.handle(message, wParam: wParam, lParam: lParam) }) {
            return result
        }
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

/// A line on standard error: what the tray couldn't do.
private func logTrayProblem(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
#endif
