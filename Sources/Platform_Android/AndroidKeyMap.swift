//
//  AndroidKeyMap.swift
//  NucleantApplication
//
#if os(Android)

/// Turns an Android key code (`KeyEvent.getKeyCode()`) into the `keyCode`
/// every window reports.
///
/// `keyCode` is the macOS virtual key code (`NSEvent.keyCode`), the code
/// space the UI layer reads keys in on every platform — as `Win32KeyMap`
/// and `BrowserKeyMap` do for theirs. Android's own numbering is passed on
/// nowhere: a text field reading 0x33 for Backspace would otherwise see
/// `KEYCODE_DEL` (67) and do nothing.
///
/// `characters` needs no table: Android resolves the layout itself and the
/// view hands over `KeyEvent.getUnicodeChar()` alongside, and the soft
/// keyboard's text arrives as characters with no key at all.
enum AndroidKeyMap {

    /// A key the table doesn't know — and text typed on the soft keyboard,
    /// which has none: still reported, so its characters reach the window.
    static let unknownKeyCode: UInt16 = 0xFFFF

    static func keyCode(_ androidKeyCode: Int) -> UInt16 {
        codes[androidKeyCode] ?? unknownKeyCode
    }

    private static let codes: [Int: UInt16] = {
        var codes: [Int: UInt16] = [
            19: 0x7E, 20: 0x7D, 21: 0x7B, 22: 0x7C, // DPAD up down left right
            55: 0x2B, 56: 0x2F, // , .
            57: 0x3A, 58: 0x3D, 59: 0x38, 60: 0x3C, // Alt L/R, Shift L/R
            61: 0x30, 62: 0x31, 66: 0x24, 67: 0x33, // Tab Space Enter Del(backspace)
            68: 0x32, 69: 0x1B, 70: 0x18, 71: 0x21, 72: 0x1E, // ` - = [ ]
            73: 0x2A, 74: 0x29, 75: 0x27, 76: 0x2C, // \ ; ' /
            92: 0x74, 93: 0x79, // Page up, Page down
            111: 0x35, 112: 0x75, // Escape, Forward delete
            113: 0x3B, 114: 0x3E, 115: 0x39, // Ctrl L/R, Caps lock
            117: 0x37, 118: 0x36, // Meta L/R (⌘)
            122: 0x73, 123: 0x77, // Home, End
            154: 0x4B, 155: 0x43, 156: 0x4E, 157: 0x45, // Keypad / * - +
            158: 0x41, 160: 0x4C, 161: 0x51, // Keypad . Enter =
        ]
        // KEYCODE_0 … KEYCODE_9
        for (offset, mac) in [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19].enumerated() {
            codes[7 + offset] = UInt16(mac)
        }
        // KEYCODE_A … KEYCODE_Z
        let letters: [UInt16] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // A–M
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // N–Z
        ]
        for (offset, mac) in letters.enumerated() {
            codes[29 + offset] = mac
        }
        // KEYCODE_F1 … KEYCODE_F12
        for (offset, mac) in [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F].enumerated() {
            codes[131 + offset] = UInt16(mac)
        }
        // KEYCODE_NUMPAD_0 … KEYCODE_NUMPAD_9
        for (offset, mac) in [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C].enumerated() {
            codes[144 + offset] = UInt16(mac)
        }
        return codes
    }()
}
#endif
