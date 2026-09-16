//
//  UIKitMenuBar.swift
//  NucleantApplication
//
#if os(iOS)
import UIKit
import NucleantWindow

/// `MenuBarHost` for UIKit: the iPad menu bar (and the hardware-keyboard
/// shortcut HUD), through `UIMenuBuilder`.
///
/// UIKit builds the main menu itself, on its own schedule, by calling
/// `buildMenu(with:)` on the app delegate — so unlike AppKit there is nothing
/// to hand it. `install` keeps the menu bar and asks for a rebuild; the app
/// delegate's `buildMenu(with:)` then forwards to `build(with:)`. One shared
/// instance, because that delegate is instantiated by UIKit from a class
/// name and has no other way to find its host.
///
/// Commands are `UICommand`s whose action is the `UIResponder` extension
/// below, so whichever responder UIKit picks routes back here by index.
@MainActor
public final class UIKitMenuBar: MenuBarHost {

    public static let shared = UIKitMenuBar()

    private var menuBar = MenuBar()

    /// The commands of the last build, indexed by `UICommand.propertyList`.
    private var commands: [MenuBar.Command] = []

    private init() {}

    public func install(_ menuBar: MenuBar) {
        self.menuBar = menuBar
        refresh()
    }

    public func refresh() {
        UIMenuSystem.main.setNeedsRebuild()
    }

    /// Call from the app delegate's `buildMenu(with:)`.
    public func build(with builder: any UIMenuBuilder) {
        guard builder.system == .main else { return }
        commands = []
        for group in menuBar.groups {
            apply(group, builder)
        }
        for menu in menuBar.menus {
            // Each goes in just before Window, so they keep their order.
            builder.insertSibling(self.menu(menu), beforeMenu: .window)
        }
    }

    func perform(_ sender: UICommand) {
        guard let index = sender.propertyList as? Int, commands.indices.contains(index) else { return }
        commands[index].action()
    }

    private func apply(_ group: MenuBar.Group, _ builder: any UIMenuBuilder) {
        let (identifier, parent) = group.placement.uikit
        let items = elements(group.items)
        guard builder.menu(for: identifier) != nil else {
            // A system without that group: put the items in its menu.
            builder.insertChild(inline(items), atEndOfMenu: parent)
            return
        }
        switch group.position {
        case .replacing:
            builder.replace(menu: identifier, with: UIMenu(
                title: "", identifier: identifier, options: .displayInline, children: items
            ))
        case .before:
            if group.placement == .help {
                builder.insertChild(inline(items), atStartOfMenu: identifier)
            } else {
                builder.insertSibling(inline(items), beforeMenu: identifier)
            }
        case .after:
            if group.placement == .help {
                builder.insertChild(inline(items), atEndOfMenu: identifier)
            } else {
                builder.insertSibling(inline(items), afterMenu: identifier)
            }
        }
    }

    private func inline(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(title: "", options: .displayInline, children: children)
    }

    private func menu(_ menu: MenuBar.Menu) -> UIMenu {
        UIMenu(title: menu.title, children: elements(menu.items))
    }

    /// UIKit has no separator: runs of items between dividers become inline
    /// menus, which it draws with a rule between them.
    private func elements(_ items: [MenuBar.Item]) -> [UIMenuElement] {
        var runs: [[UIMenuElement]] = [[]]
        for item in items {
            switch item {
            case .divider:
                runs.append([])
            case .submenu(let menu):
                runs[runs.count - 1].append(self.menu(menu))
            case .command(let command):
                runs[runs.count - 1].append(element(command))
            }
        }
        let nonEmpty = runs.filter { !$0.isEmpty }
        return nonEmpty.count > 1 ? nonEmpty.map(inline) : nonEmpty.first ?? []
    }

    private func element(_ command: MenuBar.Command) -> UICommand {
        let index = commands.count
        commands.append(command)
        let action = #selector(UIResponder._nucleantPerformCommand(_:))
        let element: UICommand
        if let shortcut = command.shortcut {
            element = UIKeyCommand(
                title: command.title,
                action: action,
                input: shortcut.key.input,
                modifierFlags: shortcut.modifiers.flags,
                propertyList: index
            )
        } else {
            element = UICommand(title: command.title, action: action, propertyList: index)
        }
        element.attributes = command.isEnabled ? [] : .disabled
        return element
    }
}

extension UIResponder {
    /// The action of every command `UIKitMenuBar` builds. On the base class
    /// so that whichever responder UIKit resolves the command to — the first
    /// responder, a window, the application — answers it.
    @objc public func _nucleantPerformCommand(_ sender: UICommand) {
        MainActor.assumeIsolated { UIKitMenuBar.shared.perform(sender) }
    }
}

extension MenuBar.Placement {
    /// The standard group's identifier and the menu it belongs to.
    fileprivate var uikit: (group: UIMenu.Identifier, parent: UIMenu.Identifier) {
        switch self {
        case .appInfo: return (.about, .application)
        case .appSettings: return (.preferences, .application)
        case .appTermination: return (.quit, .application)
        case .newItem: return (.newScene, .file)
        case .saveItem: return (.close, .file)
        case .undoRedo: return (.undoRedo, .edit)
        case .pasteboard: return (.standardEdit, .edit)
        case .textEditing: return (.spelling, .edit)
        case .windowArrangement: return (.minimizeAndZoom, .window)
        case .help: return (.help, .help)
        }
    }
}

extension MenuBar.Key {
    fileprivate var input: String {
        switch self {
        case .character(let c): return String(c)
        case .return: return "\r"
        case .escape: return UIKeyCommand.inputEscape
        case .delete: return UIKeyCommand.inputDelete
        case .tab: return "\t"
        case .space: return " "
        case .upArrow: return UIKeyCommand.inputUpArrow
        case .downArrow: return UIKeyCommand.inputDownArrow
        case .leftArrow: return UIKeyCommand.inputLeftArrow
        case .rightArrow: return UIKeyCommand.inputRightArrow
        case .home: return UIKeyCommand.inputHome
        case .end: return UIKeyCommand.inputEnd
        case .pageUp: return UIKeyCommand.inputPageUp
        case .pageDown: return UIKeyCommand.inputPageDown
        }
    }
}

extension MenuBar.Modifiers {
    fileprivate var flags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.alternate) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif
