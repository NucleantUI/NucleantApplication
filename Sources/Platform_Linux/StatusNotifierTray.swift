//
//  StatusNotifierTray.swift
//  NucleantApplication
//
//  The system tray on Linux: StatusNotifierItem, the freedesktop tray that
//  KDE Plasma, Cinnamon, Xfce, MATE, Budgie, GNOME's AppIndicator extension
//  and the wlroots bars host, on X11 and Wayland alike. An item is an object
//  on the session bus that the desktop's tray (the "host") reads and draws;
//  its menu is a second object in the dbusmenu format, which the host draws
//  natively too. Neither needs a window of the app's own.
//
// https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/
// https://github.com/AyatanaIndicators/libdbusmenu/blob/master/libdbusmenu-glib/dbus-menu.xml
//
#if os(Linux)
import Foundation
import NucleantWindow

/// `TrayHost` for Linux: one StatusNotifierItem per `TrayItem`, each on a
/// session-bus connection of its own, registered with the desktop's
/// `org.kde.StatusNotifierWatcher`.
///
/// A `.menu` item's rows are served as a dbusmenu, which the host drops down
/// on a click. It sits at an `/org/ayatana/NotificationItem/…` path, as
/// libayatana-appindicator's items do: Cinnamon's host shows the menu on the
/// left click only for those, and KDE and GNOME follow `ItemIsMenu`. A
/// `.press` item has no menu; the host's `Activate(x, y)` is the press, with
/// the point it gives as the item's place — X11 root-window pixels, or
/// nothing much on Wayland, where a client can't place a window anyway.
///
/// The item shows its bitmap, else the icon-theme icon named by `iconName`
/// (a freedesktop name, such as `media-playback-start`), else the generic
/// `application-x-executable`. The title is its tooltip and accessible name,
/// and its text label where a host shows one (`XAyatanaLabel`): with
/// `showsTitle`, or when there is no icon of its own. A person can't take
/// an item out of the tray here, so `onRemove` is never called.
///
/// Messages are read once a turn of the event loop (`FrameLoopTurn`), while
/// there are items; no thread of its own.
@MainActor
public final class StatusNotifierTray: TrayHost {

    private var items: [ObjectIdentifier: StatusNotifierItem] = [:]
    private var turnObserver: Int?
    private var nextNumber = 1
    private var saidNoBus = false

    public init() {}

    public func insert(_ item: TrayItem) {
        let key = ObjectIdentifier(item)
        guard items[key] == nil else {
            refresh(item)
            return
        }
        guard let entry = StatusNotifierItem(item: item, number: nextNumber) else {
            if !saidNoBus {
                saidNoBus = true
                logTrayProblem("NucleantApplication: no session bus to put a tray item on — it is not shown\n")
            }
            return
        }
        nextNumber += 1
        items[key] = entry
        if turnObserver == nil {
            turnObserver = FrameLoopTurn.add { [weak self] _ in
                MainActor.assumeIsolated { self?.dispatch() }
            }
        }
    }

    public func refresh(_ item: TrayItem) {
        items[ObjectIdentifier(item)]?.refresh()
    }

    public func remove(_ item: TrayItem) {
        guard let entry = items.removeValue(forKey: ObjectIdentifier(item)) else { return }
        entry.close()
        if items.isEmpty, let turnObserver {
            FrameLoopTurn.remove(turnObserver)
            self.turnObserver = nil
        }
    }

    /// Takes every item out — as the app quits, so none outlives it on a
    /// host slow to notice.
    public func removeAll() {
        for entry in items.values { entry.close() }
        items = [:]
        if let turnObserver {
            FrameLoopTurn.remove(turnObserver)
            self.turnObserver = nil
        }
    }

    /// What the hosts sent since the last turn, answered.
    func dispatch() {
        for entry in Array(items.values) {
            entry.dispatch()
        }
    }

    /// The item's object, for tests: its bus name and object path.
    func address(of item: TrayItem) -> (busName: String, path: String)? {
        items[ObjectIdentifier(item)].map { ($0.uniqueName, $0.itemPath) }
    }
}

// MARK: - One item

/// One `TrayItem` on the bus: its StatusNotifierItem object, and for a menu
/// its dbusmenu object, on a connection of its own — so taking it away is
/// closing that, which every watcher notices.
@MainActor
private final class StatusNotifierItem {

    static let itemInterface = "org.kde.StatusNotifierItem"
    static let menuInterface = "com.canonical.dbusmenu"
    static let watcherName = "org.kde.StatusNotifierWatcher"
    static let menuPath = "/MenuBar"
    static let noMenuPath = "/NO_DBUSMENU"

    let item: TrayItem
    let number: Int
    private var connection: DBusConnection
    private(set) var itemPath: String
    private var isMenu: Bool

    /// What the host was last told, to say only what changed.
    private var shown: Appearance
    private var menu: MenuLayout
    private var revision: UInt32 = 1

    /// The serial of the registration with the watcher, to hear its answer.
    private var registration: UInt32?
    private var saidNoWatcher = false

    /// What the host asked for, run once its messages are answered: a
    /// chosen row, a press.
    private var actions: [@MainActor () -> Void] = []

    var uniqueName: String { connection.uniqueName }

    init?(item: TrayItem, number: Int) {
        guard let connection = DBusConnection.session() else { return nil }
        self.item = item
        self.number = number
        self.connection = connection
        self.isMenu = Self.isMenu(item)
        self.itemPath = Self.itemPath(isMenu: isMenu, number: number)
        self.shown = Appearance(item)
        self.menu = MenuLayout(item)
        announce()
    }

    private static func isMenu(_ item: TrayItem) -> Bool {
        if case .menu = item.action { true } else { false }
    }

    private static func itemPath(isMenu: Bool, number: Int) -> String {
        isMenu ? "/org/ayatana/NotificationItem/nucleant_\(getpid())_\(number)" : "/StatusNotifierItem"
    }

    /// Take the conventional name, hear when a watcher comes and goes, and
    /// register with the one there is.
    private func announce() {
        connection.send(.methodCall(
            destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus", member: "RequestName",
            body: [.string("org.kde.StatusNotifierItem-\(getpid())-\(number)"), .uint32(4)]  // DO_NOT_QUEUE
        ))
        connection.send(.methodCall(
            destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus", member: "AddMatch",
            body: [.string(
                "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus'," +
                "member='NameOwnerChanged',arg0='\(Self.watcherName)'"
            )]
        ))
        register()
    }

    /// Registered by object path: the watcher pairs it with this
    /// connection's name. A bus name alone would mean `/StatusNotifierItem`.
    private func register() {
        registration = connection.send(.methodCall(
            destination: Self.watcherName, path: "/StatusNotifierWatcher",
            interface: Self.watcherName, member: "RegisterStatusNotifierItem",
            body: [.string(itemPath)]
        ))
    }

    func close() {
        connection.close()
    }

    // MARK: Changes

    func refresh() {
        let isMenu = Self.isMenu(item)
        guard isMenu == self.isMenu else {
            // A menu now, or a press: it lives at another path, and a host
            // reads the path only when the item registers. So it registers
            // again, as a new item.
            reconnect(isMenu: isMenu)
            return
        }
        let appearance = Appearance(item)
        let old = shown
        shown = appearance
        var changed: [String] = []
        if appearance.title != old.title {
            emit("NewTitle")
            emit("NewToolTip")
            changed += ["Title", "ToolTip"]
        }
        if appearance.iconName != old.iconName || appearance.pixmap != old.pixmap {
            emit("NewIcon")
            changed += ["IconName", "IconPixmap"]
        }
        if appearance.label != old.label {
            emit("XAyatanaNewLabel", [.string(appearance.label), .string("")])
            changed += ["XAyatanaLabel"]
        }
        if !changed.isEmpty {
            let properties = itemProperties()
            connection.send(.signal(
                path: itemPath, interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
                body: [
                    .string(Self.itemInterface),
                    .properties(properties.filter { changed.contains($0.0) }),
                    .array(element: "s", []),
                ]
            ))
        }
        updateMenu()
    }

    /// The rows as they are now; the host told if they changed.
    @discardableResult
    private func updateMenu() -> Bool {
        guard isMenu else { return false }
        let layout = MenuLayout(item)
        guard layout != menu else { return false }
        menu = layout
        revision += 1
        connection.send(.signal(
            path: Self.menuPath, interface: Self.menuInterface, member: "LayoutUpdated",
            body: [.uint32(revision), .int32(0)]
        ))
        return true
    }

    private func reconnect(isMenu: Bool) {
        guard let connection = DBusConnection.session() else { return }
        self.connection.close()
        self.connection = connection
        self.isMenu = isMenu
        itemPath = Self.itemPath(isMenu: isMenu, number: number)
        shown = Appearance(item)
        menu = MenuLayout(item)
        revision += 1
        announce()
    }

    private func emit(_ member: String, _ body: [DBusValue] = []) {
        connection.send(.signal(path: itemPath, interface: Self.itemInterface, member: member, body: body))
    }

    // MARK: Messages

    func dispatch() {
        guard let messages = connection.receive() else {
            // The bus hung up on us. A new connection is a new item, which
            // registers itself.
            reconnect(isMenu: isMenu)
            return
        }
        for message in messages {
            switch message.kind {
            case .methodCall:
                handle(message)
            case .signal:
                // A watcher came: register with it. (One that goes takes its
                // items with it, and the next one is told about them again.)
                if message.member == "NameOwnerChanged", message.body.count == 3,
                   message.body[0].string == Self.watcherName, message.body[2].string?.isEmpty == false {
                    register()
                }
            case .error:
                if message.replySerial == registration, registration != nil, !saidNoWatcher {
                    saidNoWatcher = true
                    logTrayProblem("""
                        NucleantApplication: no system tray to show "\(item.title)" in \
                        (\(message.errorName ?? "no StatusNotifierWatcher")); it appears once one starts

                        """)
                }
            case .methodReturn:
                break
            }
        }
        let actions = self.actions
        self.actions = []
        for action in actions { action() }
    }

    private func handle(_ call: DBusMessage) {
        guard let member = call.member, let path = call.path else { return }
        // A call may leave the interface out; then the member alone says.
        switch call.interface ?? "" {
        case "org.freedesktop.DBus.Properties":
            handleProperties(call, member: member, path: path)
        case "org.freedesktop.DBus.Introspectable":
            guard member == "Introspect" else { return unknownMethod(call) }
            connection.reply(to: call, [.string(introspection(of: path))])
        case "org.freedesktop.DBus.Peer":
            switch member {
            case "Ping": connection.reply(to: call)
            case "GetMachineId": connection.reply(to: call, [.string(Self.machineID)])
            default: unknownMethod(call)
            }
        case Self.itemInterface where path == itemPath:
            handleItem(call, member: member)
        case Self.menuInterface where path == Self.menuPath && isMenu:
            handleMenu(call, member: member)
        case "" where path == itemPath:
            handleItem(call, member: member)
        case "" where path == Self.menuPath && isMenu:
            handleMenu(call, member: member)
        default:
            connection.replyError(to: call, name: DBusError.unknownObject, text: "No such object or interface at \(path)")
        }
    }

    private func unknownMethod(_ call: DBusMessage) {
        connection.replyError(to: call, name: DBusError.unknownMethod,
                              text: "No method \(call.member ?? "") on \(call.interface ?? "")")
    }

    // MARK: org.kde.StatusNotifierItem

    private func handleItem(_ call: DBusMessage, member: String) {
        switch member {
        case "Activate":
            // The primary click — on a `.press` item, the press. A `.menu`
            // item's menu is the host's to show.
            if case .press(let pressed) = item.action {
                let x = Double(call.body.first?.int32 ?? 0)
                let y = Double(call.body.dropFirst().first?.int32 ?? 0)
                actions.append { pressed(TrayAnchor(x: x, y: y, width: 0, height: 0)) }
            }
            connection.reply(to: call)
        case "ContextMenu", "SecondaryActivate", "Scroll", "ProvideXdgActivationToken":
            connection.reply(to: call)
        default:
            unknownMethod(call)
        }
    }

    /// The item's properties, as the spec names them, with the extensions
    /// KDE and Ayatana hosts read.
    private func itemProperties() -> [(String, DBusValue)] {
        let noPixmaps = DBusValue.array(element: "(iiay)", [])
        return [
            ("Category", .string("ApplicationStatus")),
            ("Id", .string(number == 1 ? Self.appID : "\(Self.appID)-\(number)")),
            ("Title", .string(item.title)),
            ("Status", .string("Active")),
            ("WindowId", .int32(0)),
            ("IconThemePath", .string("")),
            ("IconName", .string(shown.iconName)),
            ("IconPixmap", .array(element: "(iiay)", shown.pixmap.map { [$0] } ?? [])),
            ("OverlayIconName", .string("")),
            ("OverlayIconPixmap", noPixmaps),
            ("AttentionIconName", .string("")),
            ("AttentionIconPixmap", noPixmaps),
            ("AttentionMovieName", .string("")),
            ("ToolTip", .structure([.string(""), noPixmaps, .string(item.title), .string("")])),
            ("ItemIsMenu", .boolean(isMenu)),
            ("Menu", .objectPath(isMenu ? Self.menuPath : Self.noMenuPath)),
            ("XAyatanaLabel", .string(shown.label)),
            ("XAyatanaLabelGuide", .string("")),
        ]
    }

    private static let menuProperties: [(String, DBusValue)] = [
        ("Version", .uint32(3)),
        ("TextDirection", .string("ltr")),
        ("Status", .string("normal")),
        ("IconThemePath", .array(element: "s", [])),
    ]

    private func handleProperties(_ call: DBusMessage, member: String, path: String) {
        let interface = call.body.first?.string ?? ""
        let properties: [(String, DBusValue)]?
        switch (path, interface) {
        case (itemPath, Self.itemInterface): properties = itemProperties()
        case (Self.menuPath, Self.menuInterface) where isMenu: properties = Self.menuProperties
        default: properties = nil
        }
        switch member {
        case "GetAll":
            connection.reply(to: call, [.properties(properties ?? [])])
        case "Get":
            let name = call.body.dropFirst().first?.string
            guard let value = properties?.first(where: { $0.0 == name })?.1 else {
                connection.replyError(to: call, name: DBusError.unknownProperty,
                                      text: "No property \(name ?? "") on \(interface)")
                return
            }
            connection.reply(to: call, [.variant(value)])
        case "Set":
            connection.replyError(to: call, name: DBusError.propertyReadOnly, text: "The properties are read-only")
        default:
            unknownMethod(call)
        }
    }

    // MARK: com.canonical.dbusmenu

    private func handleMenu(_ call: DBusMessage, member: String) {
        switch member {
        case "GetLayout":
            let parent = call.body.first?.int32 ?? 0
            let depth = call.body.dropFirst().first?.int32 ?? -1
            let names = Set(call.body.dropFirst(2).first?.elements?.compactMap(\.string) ?? [])
            guard let node = menu.node(parent) else {
                connection.replyError(to: call, name: DBusError.invalidArgs, text: "No menu item \(parent)")
                return
            }
            connection.reply(to: call, [.uint32(revision), node.layout(depth: depth, names: names)])
        case "GetGroupProperties":
            let ids = call.body.first?.elements?.compactMap(\.int32) ?? []
            let names = Set(call.body.dropFirst().first?.elements?.compactMap(\.string) ?? [])
            let nodes = ids.isEmpty ? menu.allNodes : ids.compactMap(menu.node)
            connection.reply(to: call, [.array(element: "(ia{sv})", nodes.map {
                .structure([.int32($0.id), $0.propertyMap(names)])
            })])
        case "GetProperty":
            let id = call.body.first?.int32 ?? -1
            let name = call.body.dropFirst().first?.string ?? ""
            guard let value = menu.node(id)?.properties.first(where: { $0.0 == name })?.1 else {
                connection.replyError(to: call, name: DBusError.invalidArgs, text: "No property \(name) on item \(id)")
                return
            }
            connection.reply(to: call, [.variant(value)])
        case "Event":
            if let id = call.body.first?.int32, call.body.dropFirst().first?.string == "clicked" {
                choose(id)
            }
            connection.reply(to: call)
        case "EventGroup":
            for event in call.body.first?.elements ?? [] {
                guard let fields = event.fields, fields.count >= 2,
                      let id = fields[0].int32, fields[1].string == "clicked" else { continue }
                choose(id)
            }
            connection.reply(to: call, [.array(element: "i", [])])
        case "AboutToShow":
            // The menu is about to open: what the rows say now — a
            // command's `isEnabled` the app changed in place, say.
            connection.reply(to: call, [.boolean(updateMenu())])
        case "AboutToShowGroup":
            let updated = updateMenu()
            connection.reply(to: call, [.array(element: "i", updated ? [.int32(0)] : []), .array(element: "i", [])])
        default:
            unknownMethod(call)
        }
    }

    private func choose(_ id: Int32) {
        guard let command = menu.commands[id], command.isEnabled else { return }
        actions.append { command.action() }
    }

    // MARK: Introspection

    private func introspection(of path: String) -> String {
        var interfaces = ""
        if path == itemPath {
            interfaces = Self.itemIntrospection
        } else if path == Self.menuPath, isMenu {
            interfaces = Self.menuIntrospection
        }
        let objects = isMenu ? [itemPath, Self.menuPath] : [itemPath]
        let prefix = path == "/" ? "/" : path + "/"
        var children: [String] = []
        for object in objects where object.hasPrefix(prefix) {
            if let child = object.dropFirst(prefix.count).split(separator: "/").first, !children.contains(String(child)) {
                children.append(String(child))
            }
        }
        return """
            <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
             "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
            <node>
            \(interfaces)\(children.map { "  <node name=\"\($0)\"/>\n" }.joined())</node>
            """
    }

    private static let itemIntrospection = """
          <interface name="org.kde.StatusNotifierItem">
            <property name="Category" type="s" access="read"/>
            <property name="Id" type="s" access="read"/>
            <property name="Title" type="s" access="read"/>
            <property name="Status" type="s" access="read"/>
            <property name="WindowId" type="i" access="read"/>
            <property name="IconThemePath" type="s" access="read"/>
            <property name="IconName" type="s" access="read"/>
            <property name="IconPixmap" type="a(iiay)" access="read"/>
            <property name="OverlayIconName" type="s" access="read"/>
            <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
            <property name="AttentionIconName" type="s" access="read"/>
            <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
            <property name="AttentionMovieName" type="s" access="read"/>
            <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
            <property name="ItemIsMenu" type="b" access="read"/>
            <property name="Menu" type="o" access="read"/>
            <property name="XAyatanaLabel" type="s" access="read"/>
            <property name="XAyatanaLabelGuide" type="s" access="read"/>
            <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
            <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
            <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
            <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
            <method name="ProvideXdgActivationToken"><arg name="token" type="s" direction="in"/></method>
            <signal name="NewTitle"/>
            <signal name="NewIcon"/>
            <signal name="NewAttentionIcon"/>
            <signal name="NewOverlayIcon"/>
            <signal name="NewToolTip"/>
            <signal name="NewStatus"><arg name="status" type="s"/></signal>
            <signal name="XAyatanaNewLabel"><arg name="label" type="s"/><arg name="guide" type="s"/></signal>
          </interface>

        """

    private static let menuIntrospection = """
          <interface name="com.canonical.dbusmenu">
            <property name="Version" type="u" access="read"/>
            <property name="TextDirection" type="s" access="read"/>
            <property name="Status" type="s" access="read"/>
            <property name="IconThemePath" type="as" access="read"/>
            <method name="GetLayout">
              <arg name="parentId" type="i" direction="in"/><arg name="recursionDepth" type="i" direction="in"/>
              <arg name="propertyNames" type="as" direction="in"/>
              <arg name="revision" type="u" direction="out"/><arg name="layout" type="(ia{sv}av)" direction="out"/>
            </method>
            <method name="GetGroupProperties">
              <arg name="ids" type="ai" direction="in"/><arg name="propertyNames" type="as" direction="in"/>
              <arg name="properties" type="a(ia{sv})" direction="out"/>
            </method>
            <method name="GetProperty">
              <arg name="id" type="i" direction="in"/><arg name="name" type="s" direction="in"/>
              <arg name="value" type="v" direction="out"/>
            </method>
            <method name="Event">
              <arg name="id" type="i" direction="in"/><arg name="eventId" type="s" direction="in"/>
              <arg name="data" type="v" direction="in"/><arg name="timestamp" type="u" direction="in"/>
            </method>
            <method name="EventGroup">
              <arg name="events" type="a(isvu)" direction="in"/><arg name="idErrors" type="ai" direction="out"/>
            </method>
            <method name="AboutToShow">
              <arg name="id" type="i" direction="in"/><arg name="needUpdate" type="b" direction="out"/>
            </method>
            <method name="AboutToShowGroup">
              <arg name="ids" type="ai" direction="in"/>
              <arg name="updatesNeeded" type="ai" direction="out"/><arg name="idErrors" type="ai" direction="out"/>
            </method>
            <signal name="ItemsPropertiesUpdated">
              <arg name="updatedProps" type="a(ia{sv})"/><arg name="removedProps" type="a(ias)"/>
            </signal>
            <signal name="LayoutUpdated"><arg name="revision" type="u"/><arg name="parent" type="i"/></signal>
            <signal name="ItemActivationRequested"><arg name="id" type="i"/><arg name="timestamp" type="u"/></signal>
          </interface>

        """

    // MARK: Identity

    /// The executable's name: what a host groups the item under.
    private static let appID: String = {
        let name = ProcessInfo.processInfo.processName
        return name.isEmpty ? "nucleant" : name
    }()

    private static let machineID: String = {
        for path in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
            if let id = try? String(contentsOfFile: path, encoding: .utf8) {
                return id.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }()
}

/// A line on standard error: what the tray couldn't do.
private func logTrayProblem(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

// MARK: - What the item shows

/// The item as the host draws it, worked out from a `TrayItem`.
private struct Appearance: Equatable {
    var title: String
    var iconName: String
    /// `(iiay)`: the bitmap, ARGB in network byte order, not premultiplied.
    var pixmap: DBusValue?
    var label: String

    @MainActor
    init(_ item: TrayItem) {
        title = item.title
        if let icon = item.icon, icon.width > 0, icon.height > 0, icon.pixels.count == icon.width * icon.height {
            pixmap = Self.pixmap(icon)
            iconName = ""
        } else {
            pixmap = nil
            iconName = item.iconName ?? Self.fallbackIconName
        }
        let hasOwnIcon = pixmap != nil || item.iconName != nil
        label = item.showsTitle || !hasOwnIcon ? item.title : ""
    }

    /// For an item with no icon of its own: a host draws something, and
    /// this is the theme's icon for a program.
    static let fallbackIconName = "application-x-executable"

    private static func pixmap(_ icon: TrayIcon) -> DBusValue {
        var bytes = [UInt8]()
        bytes.reserveCapacity(icon.pixels.count * 4)
        for pixel in icon.pixels {
            let alpha = UInt32(pixel >> 24)
            func straight(_ shift: UInt32) -> UInt8 {
                let channel = (pixel >> shift) & 0xFF
                guard alpha > 0 else { return 0 }
                return UInt8(min(255, (channel * 255 + alpha / 2) / alpha))
            }
            bytes += [UInt8(alpha), straight(16), straight(8), straight(0)]
        }
        return .structure([.int32(Int32(icon.width)), .int32(Int32(icon.height)), .bytes(bytes)])
    }
}

// MARK: - The menu

/// A `.menu` item's rows, numbered for dbusmenu: the root is 0, the rows
/// from 1 in the order they appear. Two layouts of the same rows are equal,
/// so an item whose rows haven't changed tells the host nothing.
private struct MenuLayout: Equatable {
    struct Node: Equatable {
        let id: Int32
        var properties: [(String, DBusValue)]
        var children: [Node]

        static func == (lhs: Node, rhs: Node) -> Bool {
            lhs.id == rhs.id && lhs.children == rhs.children
                && lhs.properties.map(\.0) == rhs.properties.map(\.0)
                && lhs.properties.map(\.1) == rhs.properties.map(\.1)
        }

        func propertyMap(_ names: Set<String>) -> DBusValue {
            .properties(names.isEmpty ? properties : properties.filter { names.contains($0.0) })
        }

        /// `(ia{sv}av)`, `depth` levels down (-1: all of them).
        func layout(depth: Int32, names: Set<String>) -> DBusValue {
            let children = depth == 0 ? [] : self.children.map {
                DBusValue.variant($0.layout(depth: depth < 0 ? -1 : depth - 1, names: names))
            }
            return .structure([.int32(id), propertyMap(names), .array(element: "v", children)])
        }
    }

    private(set) var root = Node(id: 0, properties: [("children-display", .string("submenu"))], children: [])
    private(set) var commands: [Int32: MenuBar.Command] = [:]

    static func == (lhs: MenuLayout, rhs: MenuLayout) -> Bool {
        lhs.root == rhs.root
    }

    @MainActor
    init(_ item: TrayItem) {
        guard case .menu(let rows) = item.action else { return }
        var nextID: Int32 = 1
        let children = nodes(rows, nextID: &nextID)
        root.children = children
    }

    @MainActor
    private mutating func nodes(_ rows: [MenuBar.Item], nextID: inout Int32) -> [Node] {
        var nodes: [Node] = []
        for row in rows {
            let id = nextID
            nextID += 1
            switch row {
            case .divider:
                nodes.append(Node(id: id, properties: [("type", .string("separator"))], children: []))
            case .command(let command):
                commands[id] = command
                var properties: [(String, DBusValue)] = [
                    ("label", .string(Self.label(command.title))),
                    ("enabled", .boolean(command.isEnabled)),
                ]
                if let shortcut = command.shortcut.flatMap(Self.shortcut) {
                    properties.append(("shortcut", shortcut))
                }
                nodes.append(Node(id: id, properties: properties, children: []))
            case .submenu(let submenu):
                let children = self.nodes(submenu.items, nextID: &nextID)
                nodes.append(Node(id: id, properties: [
                    ("label", .string(Self.label(submenu.title))),
                    ("children-display", .string("submenu")),
                ], children: children))
            }
        }
        return nodes
    }

    func node(_ id: Int32) -> Node? {
        func find(_ node: Node) -> Node? {
            if node.id == id { return node }
            for child in node.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(root)
    }

    var allNodes: [Node] {
        var nodes: [Node] = []
        func walk(_ node: Node) {
            nodes.append(node)
            node.children.forEach(walk)
        }
        walk(root)
        return nodes
    }

    /// A literal underscore: a single one marks the next letter as the
    /// row's access key.
    private static func label(_ title: String) -> String {
        title.replacingOccurrences(of: "_", with: "__")
    }

    /// `aas`: the keys of the shortcut, each combination a list of names.
    private static func shortcut(_ shortcut: MenuBar.Shortcut) -> DBusValue? {
        var keys: [String] = []
        // The primary command key is Control on Linux, as on Windows.
        if !shortcut.modifiers.isDisjoint(with: [.command, .control]) { keys.append("Control") }
        if shortcut.modifiers.contains(.option) { keys.append("Alt") }
        if shortcut.modifiers.contains(.shift) { keys.append("Shift") }
        switch shortcut.key {
        case .character(let character): keys.append(String(character))
        case .return: keys.append("Return")
        case .escape: keys.append("Escape")
        case .delete: keys.append("BackSpace")
        case .tab: keys.append("Tab")
        case .space: keys.append("space")
        case .upArrow: keys.append("Up")
        case .downArrow: keys.append("Down")
        case .leftArrow: keys.append("Left")
        case .rightArrow: keys.append("Right")
        case .home: keys.append("Home")
        case .end: keys.append("End")
        case .pageUp: keys.append("Page_Up")
        case .pageDown: keys.append("Page_Down")
        }
        return .array(element: "as", [.array(element: "s", keys.map(DBusValue.string))])
    }
}
#endif
