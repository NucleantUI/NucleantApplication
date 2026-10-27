//
//  Win32KeyMap.swift
//  NucleantApplication
//
#if os(Windows)
import WinSDK

/// Turns a Win32 key message into the `keyCode` / `characters` pair every
/// window reports.
///
/// `keyCode` is the macOS virtual key code (`NSEvent.keyCode`), the code
/// space the UI layer reads keys in on every platform — as `BrowserKeyMap`
/// does for the page. It comes from the key's scan code, which names the
/// physical key whatever the layout (as a Mac key code does), not from the
/// virtual key, which follows the layout: VK_A is wherever the layout puts
/// "A".
///
/// `characters` is what Windows typed for the press — through the user's
/// layout and dead keys — or, for a key that types nothing, the character
/// AppKit reports for it.
enum Win32KeyMap {

    /// A key the table doesn't know, as on the page: still reported, so its
    /// characters reach the window.
    static let unknownKeyCode: UInt16 = 0xFFFF

    /// `lParam` carries the scan code in bits 16–23 and the extended-key
    /// flag in bit 24.
    static func keyCode(lParam: LPARAM, virtualKey: UInt32) -> UInt16 {
        var scanCode = UInt32(truncatingIfNeeded: lParam >> 16) & 0xFF
        var extended = (lParam >> 24) & 1 != 0
        if scanCode == 0 {
            // Synthesized input can carry a virtual key alone: the layout's
            // scan code for it. Whether it's the extended key of the two
            // that share that code is the virtual key's to say — the 0xE0
            // MapVirtualKeyW is documented to put above an extended code
            // isn't there for the arrows.
            let mapped = MapVirtualKeyW(virtualKey, UINT(MAPVK_VK_TO_VSC_EX))
            scanCode = mapped & 0xFF
            extended = mapped >> 8 == 0xE0 || extendedVirtualKeys.contains(Int32(virtualKey))
        }
        return keyCode(scanCode: scanCode, extended: extended)
    }

    /// The virtual keys whose scan code carries the extended flag: those
    /// that share a code with a keypad key or a left-hand modifier.
    private static let extendedVirtualKeys: Set<Int32> = [
        VK_INSERT, VK_DELETE, VK_HOME, VK_END, VK_PRIOR, VK_NEXT,
        VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN,
        VK_RCONTROL, VK_RMENU, VK_LWIN, VK_RWIN, VK_APPS, VK_DIVIDE, VK_NUMLOCK,
    ]

    static func keyCode(scanCode: UInt32, extended: Bool) -> UInt16 {
        (extended ? extendedCodes[scanCode] : codes[scanCode]) ?? unknownKeyCode
    }

    /// The press's characters, from the UTF-16 Windows typed for it.
    static func characters(typed units: [UInt16], keyCode: UInt16, virtualKey: UInt32, scanCode: UInt32) -> String? {
        guard !units.isEmpty else { return characters(forKeyCode: keyCode) }
        if units.count == 1 {
            switch units[0] {
            case 0x08:
                // Backspace types BS on Windows, DEL in AppKit.
                return "\u{7F}"
            case ..<0x20 where GetKeyState(VK_CONTROL) < 0 && GetKeyState(VK_MENU) >= 0:
                // Ctrl held — and not as half of AltGr, which is Ctrl+Alt:
                // Windows types a control character (Ctrl+A is 0x01). Ctrl is
                // the command key here, and AppKit reports a ⌘ press with the
                // key's own character, so that is what this reports too.
                if let plain = characterWithoutControl(virtualKey: virtualKey, scanCode: scanCode) {
                    return plain
                }
            default:
                break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The character AppKit reports for a key that types nothing on its own,
    /// or nil.
    static func characters(forKeyCode keyCode: UInt16) -> String? {
        named[keyCode]
    }

    /// What the key types on this layout with Ctrl let go, the rest of the
    /// keyboard state (Shift, Caps Lock) as it is. Flag 0x4 keeps the
    /// layout's dead-key state as it was, so asking changes nothing.
    private static func characterWithoutControl(virtualKey: UInt32, scanCode: UInt32) -> String? {
        var state = [UInt8](repeating: 0, count: 256)
        guard GetKeyboardState(&state) else { return nil }
        for control in [VK_CONTROL, VK_LCONTROL, VK_RCONTROL] {
            state[Int(control)] = 0
        }
        var buffer = [UInt16](repeating: 0, count: 8)
        let count = ToUnicodeEx(virtualKey, scanCode, state, &buffer, Int32(buffer.count), 0x4, GetKeyboardLayout(0))
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<Int(count)], as: UTF16.self)
    }

    /// AppKit's characters for the keys that type none: the control
    /// characters of Return, Tab, Escape and Backspace (for when Ctrl held
    /// them back), and the private-use function-key code points.
    private static let named: [UInt16: String] = [
        0x24: "\r", 0x4C: "\r", 0x30: "\t", 0x35: "\u{1B}", 0x33: "\u{7F}",
        0x75: "\u{F728}",
        0x7E: "\u{F700}", 0x7D: "\u{F701}", 0x7B: "\u{F702}", 0x7C: "\u{F703}",
        0x73: "\u{F729}", 0x77: "\u{F72B}", 0x74: "\u{F72C}", 0x79: "\u{F72D}",
    ]

    /// Scan codes (set 1, as Windows reports them) without the extended
    /// flag.
    private static let codes: [UInt32: UInt16] = [
        0x01: 0x35, // Escape
        0x02: 0x12, 0x03: 0x13, 0x04: 0x14, 0x05: 0x15, 0x06: 0x17, // 1–5
        0x07: 0x16, 0x08: 0x1A, 0x09: 0x1C, 0x0A: 0x19, 0x0B: 0x1D, // 6–0
        0x0C: 0x1B, 0x0D: 0x18, 0x0E: 0x33, 0x0F: 0x30, // - = Backspace Tab
        0x10: 0x0C, 0x11: 0x0D, 0x12: 0x0E, 0x13: 0x0F, 0x14: 0x11, // Q W E R T
        0x15: 0x10, 0x16: 0x20, 0x17: 0x22, 0x18: 0x1F, 0x19: 0x23, // Y U I O P
        0x1A: 0x21, 0x1B: 0x1E, 0x1C: 0x24, 0x1D: 0x3B, // [ ] Return LeftControl
        0x1E: 0x00, 0x1F: 0x01, 0x20: 0x02, 0x21: 0x03, 0x22: 0x05, // A S D F G
        0x23: 0x04, 0x24: 0x26, 0x25: 0x28, 0x26: 0x25, // H J K L
        0x27: 0x29, 0x28: 0x27, 0x29: 0x32, 0x2A: 0x38, 0x2B: 0x2A, // ; ' ` LeftShift \
        0x2C: 0x06, 0x2D: 0x07, 0x2E: 0x08, 0x2F: 0x09, 0x30: 0x0B, // Z X C V B
        0x31: 0x2D, 0x32: 0x2E, 0x33: 0x2B, 0x34: 0x2F, 0x35: 0x2C, // N M , . /
        0x36: 0x3C, 0x37: 0x43, 0x38: 0x3A, 0x39: 0x31, 0x3A: 0x39, // RightShift Keypad* LeftAlt Space CapsLock
        0x3B: 0x7A, 0x3C: 0x78, 0x3D: 0x63, 0x3E: 0x76, 0x3F: 0x60, // F1–F5
        0x40: 0x61, 0x41: 0x62, 0x42: 0x64, 0x43: 0x65, 0x44: 0x6D, // F6–F10
        0x47: 0x59, 0x48: 0x5B, 0x49: 0x5C, 0x4A: 0x4E, // Keypad 7 8 9 -
        0x4B: 0x56, 0x4C: 0x57, 0x4D: 0x58, 0x4E: 0x45, // Keypad 4 5 6 +
        0x4F: 0x53, 0x50: 0x54, 0x51: 0x55, 0x52: 0x52, 0x53: 0x41, // Keypad 1 2 3 0 .
        0x56: 0x0A, 0x57: 0x67, 0x58: 0x6F, 0x59: 0x51, // ISO \ F11 F12 Keypad=
        0x64: 0x69, 0x65: 0x6B, 0x66: 0x71, 0x67: 0x6A, // F13–F16
        0x68: 0x40, 0x69: 0x4F, 0x6A: 0x50, 0x6B: 0x5A, // F17–F20
        0x73: 0x5E, 0x7D: 0x5D, // JIS Ro, Yen
    ]

    /// Scan codes with the extended flag: the keys the original keyboard had
    /// one of, added again elsewhere (right Ctrl/Alt, the arrow block, the
    /// keypad's Enter and /).
    private static let extendedCodes: [UInt32: UInt16] = [
        0x1C: 0x4C, 0x1D: 0x3E, 0x35: 0x4B, 0x38: 0x3D, // Keypad Enter, RightControl, Keypad /, RightAlt
        0x45: 0x47, // NumLock (Clear on a Mac keypad)
        0x47: 0x73, 0x48: 0x7E, 0x49: 0x74, // Home Up PageUp
        0x4B: 0x7B, 0x4D: 0x7C, // Left Right
        0x4F: 0x77, 0x50: 0x7D, 0x51: 0x79, // End Down PageDown
        0x52: 0x72, 0x53: 0x75, // Insert (Help) Delete
        0x5B: 0x37, 0x5C: 0x36, 0x5D: 0x6E, // LeftWindows RightWindows Menu: Command, Command, ContextMenu
        0x20: 0x4A, 0x2E: 0x49, 0x30: 0x48, // Mute VolumeDown VolumeUp
    ]
}
#endif
