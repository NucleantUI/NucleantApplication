//
//  AppKitTray.swift
//  NucleantApplication
//
#if os(macOS)
import AppKit
import NucleantWindow

/// `TrayHost` for AppKit: one `NSStatusItem` per `TrayItem`, at the right
/// end of the menu bar.
///
/// A `.menu` item gets an `NSMenu` built the way the app's menus are
/// (`AppKitMenuBar`), which AppKit drops down on a click. A `.press` item
/// calls back on the mouse going down, with the status item's frame, for
/// the app to show its own window there.
@MainActor
public final class AppKitTray: TrayHost {

    @MainActor
    private final class Entry {
        let statusItem: NSStatusItem
        let target = PressTarget()
        var visibility: NSKeyValueObservation?

        init(statusItem: NSStatusItem) {
            self.statusItem = statusItem
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    public func insert(_ item: TrayItem) {
        guard entries[ObjectIdentifier(item)] == nil else {
            refresh(item)
            return
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Shown, whatever an earlier launch's person did with it.
        statusItem.isVisible = true
        let entry = Entry(statusItem: statusItem)
        entries[ObjectIdentifier(item)] = entry
        refresh(item)
        // Dragged out of the menu bar by the person: gone, and the app told.
        entry.visibility = statusItem.observe(\.isVisible, options: [.new]) { [weak self, weak item] _, change in
            guard change.newValue == false else { return }
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.remove(item)
                item.onRemove?()
            }
        }
    }

    public func refresh(_ item: TrayItem) {
        guard let entry = entries[ObjectIdentifier(item)] else { return }
        let statusItem = entry.statusItem
        statusItem.behavior = item.onRemove == nil ? [] : .removalAllowed
        guard let button = statusItem.button else { return }

        let image = Self.image(for: item)
        button.image = image
        button.title = image == nil || item.showsTitle ? item.title : ""
        button.imagePosition = image == nil ? .noImage : (item.showsTitle ? .imageLeading : .imageOnly)
        button.setAccessibilityLabel(item.title)

        switch item.action {
        case .menu(let rows):
            let menu = NSMenu(title: item.title)
            for row in rows {
                menu.addItem(AppKitMenuBar.item(row))
            }
            statusItem.menu = menu
            button.target = nil
            button.action = nil
        case .press(let pressed):
            statusItem.menu = nil
            entry.target.pressed = pressed
            button.target = entry.target
            button.action = #selector(PressTarget.press(_:))
            button.sendAction(on: [.leftMouseDown])
        }
    }

    public func remove(_ item: TrayItem) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(item)) else { return }
        entry.visibility?.invalidate()
        NSStatusBar.system.removeStatusItem(entry.statusItem)
    }

    // MARK: - Icon

    /// The bitmap if there is one, else the named symbol, as a template
    /// image that takes the menu bar's colour.
    private static func image(for item: TrayItem) -> NSImage? {
        if let icon = item.icon, let image = bitmap(icon) {
            return image
        }
        if let name = item.iconName,
           let image = NSImage(systemSymbolName: name, accessibilityDescription: item.title) {
            image.isTemplate = true
            return image
        }
        return nil
    }

    private static func bitmap(_ icon: TrayIcon) -> NSImage? {
        guard icon.width > 0, icon.height > 0, icon.pixels.count == icon.width * icon.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let data = icon.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: icon.width,
                height: icon.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: icon.width * 4,
                space: space,
                // ARGB words, little-endian: BGRA bytes.
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }
        let scale = icon.scale > 0 ? icon.scale : 1
        return NSImage(cgImage: image, size: NSSize(width: Double(icon.width) / scale, height: Double(icon.height) / scale))
    }
}

/// The target of a `.press` item's button.
@MainActor
private final class PressTarget: NSObject {
    var pressed: ((TrayAnchor) -> Void)?

    @objc func press(_ sender: NSStatusBarButton) {
        guard let frame = sender.window?.frame else { return }
        pressed?(TrayAnchor(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
    }
}
#endif
