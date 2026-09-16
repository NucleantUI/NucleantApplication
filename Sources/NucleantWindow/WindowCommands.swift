//
//  WindowCommands.swift
//  NucleantApplication
//
//  The platform-neutral description of an app's menu bar, and the two
//  protocols on either side of it: `WindowCommands` is what a UI layer
//  (NucleantSwiftUI, a Python app) provides, `MenuBarHost` is what a platform
//  provider (Platform_MacOS, Platform_iOS — later Windows, Linux, Android)
//  turns it into. Neither side sees the other's framework types.
//
// https://developer.apple.com/documentation/swiftui/commands
// https://developer.apple.com/documentation/appkit/menus
// https://developer.apple.com/documentation/uikit/adding-menus-and-shortcuts-to-the-menu-bar-and-user-interface
//

/// A menu bar: the app's own top-level menus, plus groups of items to put
/// into the menus every platform already has (the app, File, Edit, Window
/// and Help menus). The host builds the standard menus itself, so an empty
/// `MenuBar` still gets the app a working Quit, Close, Copy and Paste.
///
/// Reference types throughout, so an app keeps hold of a `Menu` or a
/// `Command` and edits it in place — retitle, toggle `isEnabled`, append a
/// row — then `MenuBarHost.refresh()` shows the change.
@MainActor
public final class MenuBar {

    /// Top-level menus of the app's own, placed between Edit and Window.
    public var menus: [Menu]

    /// Insertions into, and replacements of, the standard menus' groups.
    public var groups: [Group]

    public init(menus: [Menu] = [], groups: [Group] = []) {
        self.menus = menus
        self.groups = groups
    }

    /// A titled list of items — a top-level menu or a submenu.
    @MainActor
    public final class Menu {
        public var title: String
        public var items: [Item]

        public init(title: String, items: [Item] = []) {
            self.title = title
            self.items = items
        }
    }

    public enum Item {
        case command(Command)
        case divider
        case submenu(Menu)
    }

    /// One choosable row. `action` runs on the main thread when the row is
    /// chosen or its shortcut pressed.
    @MainActor
    public final class Command {
        public var title: String
        public var shortcut: Shortcut?
        public var isEnabled: Bool
        public var action: @MainActor () -> Void

        public init(
            title: String,
            shortcut: Shortcut? = nil,
            isEnabled: Bool = true,
            action: @escaping @MainActor () -> Void
        ) {
            self.title = title
            self.shortcut = shortcut
            self.isEnabled = isEnabled
            self.action = action
        }
    }

    /// A key plus modifiers. `modifiers` defaults to the platform's primary
    /// command key, as SwiftUI's `KeyboardShortcut` does.
    public struct Shortcut: Hashable, Sendable {
        public var key: Key
        public var modifiers: Modifiers

        public init(_ key: Key, modifiers: Modifiers = .command) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// The key of a shortcut. A string literal is a character key, so
    /// `Shortcut("s")` reads as it would in SwiftUI.
    public enum Key: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
        case character(Character)
        case `return`
        case escape
        case delete
        case tab
        case space
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
        case home
        case end
        case pageUp
        case pageDown

        public init(extendedGraphemeClusterLiteral value: Character) {
            self = .character(value)
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The standard groups a host lays out on its own, which an app's
    /// `Group` can replace or sit next to. The same set SwiftUI's
    /// `CommandGroupPlacement` names; a host without one of these menus
    /// (a platform with no app menu, say) puts the group where it fits.
    public enum Placement: Hashable, Sendable, CaseIterable {
        /// About.
        case appInfo
        /// Settings… / Preferences….
        case appSettings
        /// Quit.
        case appTermination
        /// New….
        case newItem
        /// Save, Close.
        case saveItem
        /// Undo, Redo.
        case undoRedo
        /// Cut, Copy, Paste, Select All.
        case pasteboard
        /// Spelling, substitutions, transformations.
        case textEditing
        /// Minimize, Zoom.
        case windowArrangement
        /// The Help menu's contents.
        case help
    }

    /// Items placed relative to one of the standard groups.
    @MainActor
    public final class Group {
        public enum Position: Sendable {
            /// In place of the standard items.
            case replacing
            case before
            case after
        }

        public var placement: Placement
        public var position: Position
        public var items: [Item]

        public init(_ placement: Placement, position: Position, items: [Item]) {
            self.placement = placement
            self.position = position
            self.items = items
        }
    }
}

/// What an app hands the platform to describe its menus — the counterpart of
/// SwiftUI's `Commands`, without the view layer. `menuBar` is read whenever
/// the menus are (re)installed, so a conformer can build it from live state.
@MainActor
public protocol WindowCommands {
    var menuBar: MenuBar { get }
}

/// A platform's menu bar. `install` replaces whatever was installed before
/// and keeps the `MenuBar`; `refresh` rebuilds the native menus from it, for
/// after its menus or commands were edited in place. The host owns the
/// native menu objects.
@MainActor
public protocol MenuBarHost: AnyObject {
    func install(_ menuBar: MenuBar)
    func refresh()
}

/// The host for a platform with no menu bar to populate (Linux, Android):
/// installing is accepted and does nothing, so the app layer is the same
/// everywhere.
@MainActor
public final class NoMenuBar: MenuBarHost {
    public init() {}

    public func install(_ menuBar: MenuBar) {}

    public func refresh() {}
}
