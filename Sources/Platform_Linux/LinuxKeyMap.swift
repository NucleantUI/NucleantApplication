//
//  LinuxKeyMap.swift
//  NucleantApplication
//
#if os(Linux)
import CWayland

/// Turns an evdev key code into the text it produces.
///
/// Wayland does not send characters. `wl_keyboard.key` carries a raw evdev
/// scan code, and the layout that turns it into a symbol arrives separately
/// as an mmap-able xkb keymap — interpreting which properly means linking
/// libxkbcommon. That's a dependency this target doesn't take: it would be a
/// second system library to install for a `characters` field the widget layer
/// treats as a convenience next to the authoritative `keyCode`.
///
/// So what's here is a US QWERTY table, which is right for the common case
/// and wrong for anyone typing on AZERTY or with a compose key. The
/// `keyCode` passed alongside is layout-independent and always correct;
/// anything that needs real text input (IME, dead keys, non-Latin scripts)
/// wants libxkbcommon plus `zwp_text_input_v3`, at which point this table
/// should go away rather than grow.
enum LinuxKeyMap {

    /// Standard xkb modifier indices, which every keymap in practice shares
    /// for the first two slots: shift then lock.
    static let shiftBit: UInt32 = 1 << 0
    static let capsLockBit: UInt32 = 1 << 1

    static func characters(forKey key: UInt32, shift: Bool, capsLock: Bool) -> String? {
        if let letter = letters[key] {
            // Caps lock and shift both uppercase, and cancel each other out.
            return (shift != capsLock) ? letter.uppercased() : letter
        }
        guard let pair = symbols[key] else { return nil }
        return shift ? pair.shifted : pair.plain
    }

    private static let letters: [UInt32: String] = [
        UInt32(KEY_A): "a", UInt32(KEY_B): "b", UInt32(KEY_C): "c", UInt32(KEY_D): "d",
        UInt32(KEY_E): "e", UInt32(KEY_F): "f", UInt32(KEY_G): "g", UInt32(KEY_H): "h",
        UInt32(KEY_I): "i", UInt32(KEY_J): "j", UInt32(KEY_K): "k", UInt32(KEY_L): "l",
        UInt32(KEY_M): "m", UInt32(KEY_N): "n", UInt32(KEY_O): "o", UInt32(KEY_P): "p",
        UInt32(KEY_Q): "q", UInt32(KEY_R): "r", UInt32(KEY_S): "s", UInt32(KEY_T): "t",
        UInt32(KEY_U): "u", UInt32(KEY_V): "v", UInt32(KEY_W): "w", UInt32(KEY_X): "x",
        UInt32(KEY_Y): "y", UInt32(KEY_Z): "z",
    ]

    private static let symbols: [UInt32: (plain: String, shifted: String)] = [
        UInt32(KEY_1): ("1", "!"), UInt32(KEY_2): ("2", "@"), UInt32(KEY_3): ("3", "#"),
        UInt32(KEY_4): ("4", "$"), UInt32(KEY_5): ("5", "%"), UInt32(KEY_6): ("6", "^"),
        UInt32(KEY_7): ("7", "&"), UInt32(KEY_8): ("8", "*"), UInt32(KEY_9): ("9", "("),
        UInt32(KEY_0): ("0", ")"),

        UInt32(KEY_MINUS): ("-", "_"),
        UInt32(KEY_EQUAL): ("=", "+"),
        UInt32(KEY_LEFTBRACE): ("[", "{"),
        UInt32(KEY_RIGHTBRACE): ("]", "}"),
        UInt32(KEY_BACKSLASH): ("\\", "|"),
        UInt32(KEY_SEMICOLON): (";", ":"),
        UInt32(KEY_APOSTROPHE): ("'", "\""),
        UInt32(KEY_GRAVE): ("`", "~"),
        UInt32(KEY_COMMA): (",", "<"),
        UInt32(KEY_DOT): (".", ">"),
        UInt32(KEY_SLASH): ("/", "?"),
        UInt32(KEY_SPACE): (" ", " "),

        // Control characters, matching what AppKit puts in `NSEvent.characters`
        // for the same keys so a delegate written against macOS behaves the
        // same here.
        UInt32(KEY_ENTER): ("\r", "\r"),
        UInt32(KEY_KPENTER): ("\r", "\r"),
        UInt32(KEY_TAB): ("\t", "\t"),
        UInt32(KEY_BACKSPACE): ("\u{8}", "\u{8}"),
        UInt32(KEY_DELETE): ("\u{7F}", "\u{7F}"),
        UInt32(KEY_ESC): ("\u{1B}", "\u{1B}"),

        // Keypad digits, ignoring num lock — a keypad with num lock off sends
        // the navigation keys' codes instead, so anything arriving here is
        // already a digit.
        UInt32(KEY_KP0): ("0", "0"), UInt32(KEY_KP1): ("1", "1"),
        UInt32(KEY_KP2): ("2", "2"), UInt32(KEY_KP3): ("3", "3"),
        UInt32(KEY_KP4): ("4", "4"), UInt32(KEY_KP5): ("5", "5"),
        UInt32(KEY_KP6): ("6", "6"), UInt32(KEY_KP7): ("7", "7"),
        UInt32(KEY_KP8): ("8", "8"), UInt32(KEY_KP9): ("9", "9"),
        UInt32(KEY_KPDOT): (".", "."),
        UInt32(KEY_KPPLUS): ("+", "+"),
        UInt32(KEY_KPMINUS): ("-", "-"),
        UInt32(KEY_KPASTERISK): ("*", "*"),
        UInt32(KEY_KPSLASH): ("/", "/"),
    ]
}
#endif
