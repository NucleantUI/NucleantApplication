//
//  HIDKeyMap.swift
//  NucleantApplication
//
#if os(iOS)
import UIKit

/// A hardware key's `UIKey.keyCode`, a USB HID usage, as the `keyCode`
/// every window reports.
///
/// `keyCode` is the macOS virtual key code (`NSEvent.keyCode`), the code
/// space the UI layer reads keys in on every platform — as `AndroidKeyMap`,
/// `Win32KeyMap` and `BrowserKeyMap` do for theirs. A text field reading
/// 0x33 for Backspace would otherwise see HID's 0x2A and do nothing.
///
/// `characters` needs no table: UIKit resolves the layout itself
/// (`UIKey.characters`), and the on-screen keyboard's text arrives as
/// characters with no key at all.
extension UIKeyboardHIDUsage {

    /// A key the table doesn't know — and text typed on the on-screen
    /// keyboard, which has none: still reported, so its characters reach the
    /// window.
    public static let unknownWindowKeyCode: UInt16 = 0xFFFF

    /// The key's macOS virtual key code, or `unknownWindowKeyCode`.
    public var windowKeyCode: UInt16 {
        Self.windowKeyCodes[rawValue] ?? Self.unknownWindowKeyCode
    }

    /// Shift, Control, Option, Command and Caps Lock: keys that change what
    /// the others type rather than being typed. Like macOS, which reports
    /// them as flag changes rather than key presses, they reach the window
    /// only through the modifiers.
    public var isModifier: Bool {
        (0xE0...0xE7).contains(rawValue) || self == .keyboardCapsLock
    }

    private static let windowKeyCodes: [Int: UInt16] = {
        var codes: [Int: UInt16] = [
            0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31, // Return Escape Backspace Tab Space
            0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, // - = [ ]
            0x31: 0x2A, 0x32: 0x2A, 0x33: 0x29, 0x34: 0x27, 0x35: 0x32, // \ non-US# ; ' `
            0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C, 0x39: 0x39, // , . / Caps lock
            0x64: 0x0A, // non-US \ (ISO §)
            0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79, // Home PageUp ForwardDelete End PageDown
            0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E, // right left down up
            0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, // Keypad / * - +
            0x58: 0x4C, 0x63: 0x41, 0x67: 0x51, // Keypad Enter . =
            0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37, // Ctrl Shift Alt GUI (left)
            0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36, // Ctrl Shift Alt GUI (right)
        ]
        // A … Z
        let letters: [UInt16] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // A–M
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06, // N–Z
        ]
        for (offset, mac) in letters.enumerated() {
            codes[0x04 + offset] = mac
        }
        // 1 … 9, 0
        for (offset, mac) in [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D].enumerated() {
            codes[0x1E + offset] = UInt16(mac)
        }
        // F1 … F12
        for (offset, mac) in [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F].enumerated() {
            codes[0x3A + offset] = UInt16(mac)
        }
        // Keypad 1 … 9, 0
        for (offset, mac) in [0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x52].enumerated() {
            codes[0x59 + offset] = UInt16(mac)
        }
        return codes
    }()
}
#endif
