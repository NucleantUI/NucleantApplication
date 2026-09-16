//
//  AppKitMenuBar.swift
//  NucleantApplication
//
#if os(macOS)
import AppKit
import NucleantWindow

/// `MenuBarHost` for AppKit: builds `NSApp.mainMenu` from a `MenuBar`.
///
/// The standard menus are laid out here, as sections keyed by
/// `MenuBar.Placement`, with the usual first-responder selectors (`copy:`,
/// `performClose:`, `terminate:` …) so AppKit's own validation enables and
/// disables them. An app's groups replace or sit beside those sections; its
/// menus go between Edit and Window, where SwiftUI puts `CommandMenu`s.
@MainActor
public final class AppKitMenuBar: MenuBarHost {

    private var menuBar = MenuBar()

    public init() {}

    public func install(_ menuBar: MenuBar) {
        self.menuBar = menuBar
        refresh()
    }

    public func refresh() {
        let appName = Self.appName
        let main = NSMenu()

        var appMenu = StandardMenu(title: appName, sections: [
            (.appInfo, [
                Self.item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            ]),
            (.appSettings, []),
            (nil, [
                Self.item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
                Self.item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                Self.item("Show All", #selector(NSApplication.unhideAllApplications(_:)))
            ]),
            (.appTermination, [
                Self.item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
            ])
        ])
        var file = StandardMenu(title: "File", sections: [
            (.newItem, []),
            (.saveItem, [
                Self.item("Close", #selector(NSWindow.performClose(_:)), "w")
            ])
        ])
        var edit = StandardMenu(title: "Edit", sections: [
            (.undoRedo, [
                Self.item("Undo", Selector(("undo:")), "z"),
                Self.item("Redo", Selector(("redo:")), "z", [.command, .shift])
            ]),
            (.pasteboard, [
                Self.item("Cut", #selector(NSText.cut(_:)), "x"),
                Self.item("Copy", #selector(NSText.copy(_:)), "c"),
                Self.item("Paste", #selector(NSText.paste(_:)), "v"),
                Self.item("Delete", #selector(NSText.delete(_:))),
                Self.item("Select All", #selector(NSText.selectAll(_:)), "a")
            ]),
            (.textEditing, [])
        ])
        var window = StandardMenu(title: "Window", sections: [
            (.windowArrangement, [
                Self.item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                Self.item("Zoom", #selector(NSWindow.performZoom(_:)))
            ]),
            (nil, [
                Self.item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
            ])
        ])
        var help = StandardMenu(title: "Help", sections: [
            (.help, [])
        ])

        for group in menuBar.groups {
            // Each placement lives in exactly one standard menu.
            let items = group.items.map(Self.item)
            _ = appMenu.apply(group, items) || file.apply(group, items) || edit.apply(group, items)
                || window.apply(group, items) || help.apply(group, items)
        }

        // The app menu is always there, even with nothing but Quit in it.
        main.addItem(Self.submenu(appMenu.build()))
        if let menu = file.buildIfNonEmpty() { main.addItem(Self.submenu(menu)) }
        if let menu = edit.buildIfNonEmpty() { main.addItem(Self.submenu(menu)) }
        for menu in menuBar.menus {
            main.addItem(Self.submenu(Self.menu(menu)))
        }
        let windowMenu = window.build()
        main.addItem(Self.submenu(windowMenu))
        let helpMenu = help.build()
        main.addItem(Self.submenu(helpMenu))

        let app = NSApplication.shared
        app.mainMenu = main
        // AppKit fills the Window menu with the open windows, and puts the
        // search field into the Help menu, once told which they are.
        app.windowsMenu = windowMenu
        app.helpMenu = helpMenu
    }

    // MARK: - Standard menus

    /// A standard menu under construction: ordered sections, each optionally
    /// owning a placement. Empty sections vanish; a separator goes between
    /// the ones that remain.
    @MainActor
    private struct StandardMenu {
        let title: String
        var sections: [(placement: MenuBar.Placement?, items: [NSMenuItem])]

        /// Put `group` relative to its placement's section, if this menu has
        /// that section.
        mutating func apply(_ group: MenuBar.Group, _ items: [NSMenuItem]) -> Bool {
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

        func build() -> NSMenu {
            let menu = NSMenu(title: title)
            for section in sections where !section.items.isEmpty {
                if menu.numberOfItems > 0 {
                    menu.addItem(.separator())
                }
                for item in section.items {
                    menu.addItem(item)
                }
            }
            return menu
        }

        func buildIfNonEmpty() -> NSMenu? {
            sections.contains { !$0.items.isEmpty } ? build() : nil
        }
    }

    /// A first-responder item: no target, so AppKit's validation applies.
    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    // MARK: - The app's items

    private static func menu(_ menu: MenuBar.Menu) -> NSMenu {
        let native = NSMenu(title: menu.title)
        for item in menu.items {
            native.addItem(Self.item(item))
        }
        return native
    }

    private static func item(_ item: MenuBar.Item) -> NSMenuItem {
        switch item {
        case .divider:
            return .separator()
        case .submenu(let menu):
            return submenu(Self.menu(menu))
        case .command(let command):
            let native = NSMenuItem(
                title: command.title,
                action: #selector(CommandTarget.performCommand(_:)),
                keyEquivalent: command.shortcut?.key.keyEquivalent ?? ""
            )
            native.keyEquivalentModifierMask = command.shortcut?.modifiers.flags ?? []
            // `target` is weak; `representedObject` keeps the trampoline —
            // and with it the closure — alive as long as the item.
            let target = CommandTarget(command)
            native.representedObject = target
            native.target = target
            return native
        }
    }
}

/// The target of an app command's `NSMenuItem`.
@MainActor
private final class CommandTarget: NSObject, NSMenuItemValidation {
    let command: MenuBar.Command

    init(_ command: MenuBar.Command) {
        self.command = command
    }

    @objc func performCommand(_ sender: Any?) {
        command.action()
    }

    /// Read live — the app can flip `isEnabled` on the `Command` it kept
    /// and the row follows the next time the menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        command.isEnabled
    }
}

extension MenuBar.Key {
    /// AppKit's key equivalent string: the character itself, or the function
    /// key's private-use code point.
    fileprivate var keyEquivalent: String {
        switch self {
        case .character(let c): return String(c)
        case .return: return "\r"
        case .escape: return "\u{1B}"
        case .delete: return String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        case .tab: return "\t"
        case .space: return " "
        case .upArrow: return Self.functionKey(NSUpArrowFunctionKey)
        case .downArrow: return Self.functionKey(NSDownArrowFunctionKey)
        case .leftArrow: return Self.functionKey(NSLeftArrowFunctionKey)
        case .rightArrow: return Self.functionKey(NSRightArrowFunctionKey)
        case .home: return Self.functionKey(NSHomeFunctionKey)
        case .end: return Self.functionKey(NSEndFunctionKey)
        case .pageUp: return Self.functionKey(NSPageUpFunctionKey)
        case .pageDown: return Self.functionKey(NSPageDownFunctionKey)
        }
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }
}

extension MenuBar.Modifiers {
    fileprivate var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif
