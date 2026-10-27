//
//  Win32MenuBar.swift
//  NucleantApplication
//
#if os(Windows)
import NucleantWindow
import WinSDK

/// `MenuBarHost` for Win32: a menu bar on every window, built from a
/// `MenuBar`.
///
/// Laid out the Windows way — File, Edit, the app's own menus, Window, Help —
/// with SwiftUI's placements mapped onto it: About goes to Help, Settings
/// to File above Exit. The standard items are only those Win32 can carry out
/// by itself: Close and Exit. Undo, Cut, Copy and Paste have nowhere to go on
/// Windows, which has no responder chain — the focused view takes Ctrl+Z,
/// X, C and V as keys — so Edit, Window and Help appear only when the app
/// puts something into them.
///
/// Win32 menus belong to a window, so each window gets its own copy, made
/// from one `Win32MenuTemplate`; windows made later get theirs as they open.
@MainActor
public final class Win32MenuBar: MenuBarHost {

    private var menuBar: MenuBar?

    public init() {}

    public func install(_ menuBar: MenuBar) {
        self.menuBar = menuBar
        refresh()
    }

    public func refresh() {
        guard let menuBar else { return }
        var builder = Builder()
        Win32EventLoop.shared.installMenu(builder.layOut(menuBar))
    }

    /// Lays a `MenuBar` out into a template, numbering its items.
    @MainActor
    private struct Builder {
        private var template = Win32MenuTemplate()
        private var nextID: UInt16 = 1

        mutating func layOut(_ menuBar: MenuBar) -> Win32MenuTemplate {
            var file = StandardMenu(title: "&File", sections: [
                (.newItem, []),
                (.saveItem, [item("Close", MenuBar.Shortcut("w"), perform: closeActiveWindow)]),
                (.appSettings, []),
                (.appTermination, [item("Exit", nil, perform: { Win32EventLoop.shared.stop() })]),
            ])
            var edit = StandardMenu(title: "&Edit", sections: [
                (.undoRedo, []),
                (.pasteboard, []),
                (.textEditing, []),
            ])
            var window = StandardMenu(title: "&Window", sections: [
                (.windowArrangement, []),
            ])
            var help = StandardMenu(title: "&Help", sections: [
                (.help, []),
                (.appInfo, []),
            ])

            for group in menuBar.groups {
                var items: [Win32MenuTemplate.Entry] = []
                for groupItem in group.items {
                    items.append(entry(for: groupItem))
                }
                // Each placement lives in exactly one standard menu.
                _ = file.apply(group, items) || edit.apply(group, items)
                    || window.apply(group, items) || help.apply(group, items)
            }

            // File is always there, even with nothing but Close and Exit.
            template.menus.append((file.title, file.entries))
            if !edit.isEmpty { template.menus.append((edit.title, edit.entries)) }
            for menu in menuBar.menus {
                var entries: [Win32MenuTemplate.Entry] = []
                for menuItem in menu.items {
                    entries.append(entry(for: menuItem))
                }
                template.menus.append((Self.escaped(menu.title), entries))
            }
            if !window.isEmpty { template.menus.append((window.title, window.entries)) }
            if !help.isEmpty { template.menus.append((help.title, help.entries)) }
            return template
        }

        private mutating func entry(for item: MenuBar.Item) -> Win32MenuTemplate.Entry {
            switch item {
            case .divider:
                return .separator
            case .submenu(let menu):
                var entries: [Win32MenuTemplate.Entry] = []
                for menuItem in menu.items {
                    entries.append(entry(for: menuItem))
                }
                return .submenu(title: Self.escaped(menu.title), entries: entries)
            case .command(let command):
                // `isEnabled` is read live, as AppKit's validation does: when
                // the menu opens, and when the shortcut is pressed.
                return self.item(
                    command.title,
                    command.shortcut,
                    perform: { command.action() },
                    isEnabled: { command.isEnabled }
                )
            }
        }

        private mutating func item(
            _ title: String,
            _ shortcut: MenuBar.Shortcut?,
            perform: @escaping @MainActor () -> Void,
            isEnabled: @escaping @MainActor () -> Bool = { true }
        ) -> Win32MenuTemplate.Entry {
            let id = nextID
            nextID += 1
            template.commands[id] = Win32MenuCommand(perform: perform, isEnabled: isEnabled)
            var label = Self.escaped(title)
            if let shortcut, let keys = Win32Shortcut(shortcut) {
                template.shortcuts[keys] = id
                // After a tab, a menu item's text is right-aligned: where
                // Windows shows the shortcut.
                label += "\t" + keys.displayName(for: shortcut.key)
            }
            return .item(id: id, title: label)
        }

        /// A literal "&": a single one marks the next letter as the item's
        /// Alt key.
        private static func escaped(_ title: String) -> String {
            String(title.flatMap { $0 == "&" ? ["&", "&"] : [$0] })
        }
    }

    /// A standard menu under construction: ordered sections, each optionally
    /// owning a placement. Empty sections vanish; a separator goes between
    /// the ones that remain. The same shape as AppKitMenuBar's.
    @MainActor
    private struct StandardMenu {
        let title: String
        var sections: [(placement: MenuBar.Placement?, items: [Win32MenuTemplate.Entry])]

        /// Put `group` relative to its placement's section, if this menu has
        /// that section.
        mutating func apply(_ group: MenuBar.Group, _ items: [Win32MenuTemplate.Entry]) -> Bool {
            guard let index = sections.firstIndex(where: { $0.placement == group.placement }) else {
                return false
            }
            switch group.position {
            case .replacing: sections[index].items = items
            case .before: sections.insert((nil, items), at: index)
            case .after: sections.insert((nil, items), at: index + 1)
            }
            return true
        }

        var isEmpty: Bool {
            !sections.contains { !$0.items.isEmpty }
        }

        var entries: [Win32MenuTemplate.Entry] {
            var entries: [Win32MenuTemplate.Entry] = []
            for section in sections where !section.items.isEmpty {
                if !entries.isEmpty { entries.append(.separator) }
                entries += section.items
            }
            return entries
        }
    }
}

/// Close, from the File menu: asks the active window to close, as its title
/// bar's ✕ would, so `on_close` has its say.
@MainActor
private func closeActiveWindow() {
    if let window = GetActiveWindow() {
        PostMessageW(window, UINT(WM_CLOSE), 0, 0)
    }
}

/// What a menu item runs, and whether it can now — both on the main actor.
struct Win32MenuCommand {
    let perform: @MainActor () -> Void
    let isEnabled: @MainActor () -> Bool
}

/// A menu bar laid out and numbered: what `makeMenu` turns into a window's
/// HMENU, as many times as there are windows. The commands and shortcuts are
/// the same for all of them.
struct Win32MenuTemplate {
    indirect enum Entry {
        /// `id` is what WM_COMMAND carries back when the item is chosen.
        case item(id: UInt16, title: String)
        case separator
        case submenu(title: String, entries: [Entry])
    }

    var menus: [(title: String, entries: [Entry])] = []
    var commands: [UInt16: Win32MenuCommand] = [:]
    var shortcuts: [Win32Shortcut: UInt16] = [:]

    /// A new menu bar, for one window. The window owns it once attached.
    func makeMenu() -> HMENU? {
        guard let bar = CreateMenu() else { return nil }
        for menu in menus {
            append(.submenu(title: menu.title, entries: menu.entries), to: bar)
        }
        return bar
    }

    private func append(_ entry: Entry, to menu: HMENU) {
        switch entry {
        case .separator:
            AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        case .item(let id, let title):
            title.withCString(encodedAs: UTF16.self) { title in
                _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(id), title)
            }
        case .submenu(let title, let entries):
            guard let popup = CreatePopupMenu() else { return }
            for entry in entries {
                append(entry, to: popup)
            }
            title.withCString(encodedAs: UTF16.self) { title in
                _ = AppendMenuW(menu, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: popup)), title)
            }
        }
    }
}

/// A key and modifiers as Win32 reports a press: the virtual key, and
/// whether Ctrl, Alt and Shift were down.
struct Win32Shortcut: Hashable {
    var virtualKey: UInt16
    var control: Bool
    var alt: Bool
    var shift: Bool
}

extension Win32Shortcut {
    /// The keys `shortcut` is pressed with on this keyboard layout. `.command`
    /// is Ctrl, Windows' command key, and so is `.control`, there being no
    /// second one. Nil for a character no key on the layout types.
    init?(_ shortcut: MenuBar.Shortcut) {
        control = !shortcut.modifiers.isDisjoint(with: [.command, .control])
        alt = shortcut.modifiers.contains(.option)
        shift = shortcut.modifiers.contains(.shift)
        switch shortcut.key {
        case .character(let character):
            let units = Array(String(character).utf16)
            guard units.count == 1 else { return nil }
            let keys = VkKeyScanW(units[0])
            guard keys != -1 else { return nil }
            virtualKey = UInt16(keys & 0xFF)
            // What the character needs held on this layout: Shift for "S"
            // (as AppKit's key equivalents read an uppercase letter) or for
            // "?", AltGr — Ctrl+Alt — for "@" on a German keyboard.
            let state = (keys >> 8) & 0xFF
            if state & 1 != 0 { shift = true }
            if state & 2 != 0 { control = true }
            if state & 4 != 0 { alt = true }
        case .return: virtualKey = UInt16(VK_RETURN)
        case .escape: virtualKey = UInt16(VK_ESCAPE)
        case .delete: virtualKey = UInt16(VK_BACK)
        case .tab: virtualKey = UInt16(VK_TAB)
        case .space: virtualKey = UInt16(VK_SPACE)
        case .upArrow: virtualKey = UInt16(VK_UP)
        case .downArrow: virtualKey = UInt16(VK_DOWN)
        case .leftArrow: virtualKey = UInt16(VK_LEFT)
        case .rightArrow: virtualKey = UInt16(VK_RIGHT)
        case .home: virtualKey = UInt16(VK_HOME)
        case .end: virtualKey = UInt16(VK_END)
        case .pageUp: virtualKey = UInt16(VK_PRIOR)
        case .pageDown: virtualKey = UInt16(VK_NEXT)
        }
    }

    /// How a Windows menu writes it: "Ctrl+Shift+S".
    func displayName(for key: MenuBar.Key) -> String {
        var parts: [String] = []
        if control { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        switch key {
        case .character(let character): parts.append(String(character).uppercased())
        case .return: parts.append("Enter")
        case .escape: parts.append("Esc")
        case .delete: parts.append("Backspace")
        case .tab: parts.append("Tab")
        case .space: parts.append("Space")
        case .upArrow: parts.append("Up")
        case .downArrow: parts.append("Down")
        case .leftArrow: parts.append("Left")
        case .rightArrow: parts.append("Right")
        case .home: parts.append("Home")
        case .end: parts.append("End")
        case .pageUp: parts.append("PgUp")
        case .pageDown: parts.append("PgDn")
        }
        return parts.joined(separator: "+")
    }
}
#endif
