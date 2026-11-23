//
//  LinuxTrayTests.swift
//  NucleantApplicationTests
//
//  The Linux system tray (Linux only): D-Bus values through the wire format
//  and back, and a StatusNotifierItem on the real session bus, asked what a
//  tray host asks it — its properties, its menu, a click on a row, a press
//  — from a second connection, as a host would. Needs a session bus; no
//  tray host, and no display.
//
#if os(Linux)
import Testing
import Foundation
import NucleantWindow
@testable import Platform_Linux

@Suite(.serialized)
@MainActor
struct LinuxTrayTests {

    // MARK: Wire format

    @Test func valuesComeBackAsTheyWent() throws {
        let layout = DBusValue.structure([
            .int32(0),
            .properties([("children-display", .string("submenu")), ("enabled", .boolean(false))]),
            .array(element: "v", [.variant(.structure([
                .int32(1), .properties([("label", .string("Ünïcode _ row"))]), .array(element: "v", []),
            ]))]),
        ])
        let pixmap = DBusValue.array(element: "(iiay)", [
            .structure([.int32(2), .int32(1), .bytes([255, 1, 2, 3, 128, 4, 5, 6])]),
        ])
        let message = DBusMessage(
            kind: .methodReturn, replySerial: 7, destination: ":1.42",
            body: [.uint32(3), layout, pixmap, .variant(.variant(.uint32(1))), .double(-2.5), .int64(-9),
                   .objectPath("/StatusNotifierItem"), .array(element: "s", [])]
        )
        var malformed = false
        let encoded = message.encoded(serial: 99)
        let (decoded, length) = try #require(DBusMessage.decode(encoded, malformed: &malformed))
        #expect(!malformed)
        #expect(length == encoded.count)
        #expect(decoded.kind == .methodReturn)
        #expect(decoded.serial == 99)
        #expect(decoded.replySerial == 7)
        #expect(decoded.destination == ":1.42")
        #expect(decoded.body == message.body)
        #expect(decoded.body[3].uint32 == 1)
    }

    @Test func aMessageCutShortWaitsForTheRest() {
        let encoded = DBusMessage.signal(path: "/a", interface: "a.b", member: "C", body: [.string("x")])
            .encoded(serial: 1)
        var malformed = false
        #expect(DBusMessage.decode(Array(encoded.dropLast(3)), malformed: &malformed) == nil)
        #expect(!malformed)
        // A header saying 8 bytes of body follow, without them.
        #expect(DBusMessage.decode([0x6c, 1, 0, 1, 8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0], malformed: &malformed) == nil)
        #expect(!malformed)
        #expect(DBusMessage.decode([0x7a] + Array(repeating: 0, count: 15), malformed: &malformed) == nil)
        #expect(malformed)
    }

    // MARK: Placement

    @Test func aTrayWindowDropsTowardsTheRestOfTheScreen() {
        let screen = TrayAnchor(x: 0, y: 0, width: 1920, height: 1040)
        // A taskbar at the bottom: above the item, centred on it.
        var origin = TrayAnchor(x: 1600, y: 1045, width: 30, height: 30).dropDownOrigin(width: 300, height: 200, in: screen)
        #expect(origin.x == 1465 && origin.y == 1040 - 200)
        // A panel at the top: under it.
        let below = TrayAnchor(x: 0, y: 30, width: 1920, height: 1050)
        origin = TrayAnchor(x: 500, y: 0, width: 24, height: 24).dropDownOrigin(width: 300, height: 200, in: below)
        #expect(origin.x == 362 && origin.y == 30)
        // A click near the edge: kept on the screen.
        origin = TrayAnchor(x: 1910, y: 1060, width: 0, height: 0).dropDownOrigin(width: 300, height: 200, in: screen)
        #expect(origin.x == 1620)
        // A taskbar down the left: beside it.
        let right = TrayAnchor(x: 48, y: 0, width: 1872, height: 1080)
        origin = TrayAnchor(x: 8, y: 900, width: 32, height: 32).dropDownOrigin(width: 300, height: 200, in: right)
        #expect(origin.x == 48 && origin.y == 816)
    }

    // MARK: On the bus

    /// The item's tray, and a second connection to ask it what a host asks.
    private func makeTray(with item: TrayItem) throws -> (StatusNotifierTray, DBusConnection, (busName: String, path: String)) {
        let tray = StatusNotifierTray()
        tray.insert(item)
        let host = try #require(DBusConnection.session(), "no session bus")
        let address = try #require(tray.address(of: item))
        return (tray, host, address)
    }

    /// Sends `call` and turns the tray until its reply comes.
    private func ask(_ host: DBusConnection, _ tray: StatusNotifierTray, _ call: DBusMessage) throws -> DBusMessage {
        let serial = try #require(host.send(call))
        for _ in 0..<200 {
            tray.dispatch()
            for message in host.receive() ?? [] where message.replySerial == serial {
                return message
            }
            usleep(5000)
        }
        Issue.record("no reply to \(call.member ?? "")")
        throw CancellationError()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil))
    func aHostReadsTheItemAndChoosesARow() throws {
        var chosen: [String] = []
        let item = TrayItem(title: "Timer_1", iconName: "media-playback-start", action: .menu([
            .command(MenuBar.Command(title: "Start", shortcut: MenuBar.Shortcut("s")) { chosen.append("start") }),
            .divider,
            .command(MenuBar.Command(title: "Reset", isEnabled: false) { chosen.append("reset") }),
        ]))
        let (tray, host, address) = try makeTray(with: item)
        defer { tray.removeAll(); host.close() }
        #expect(address.path.hasPrefix("/org/ayatana/NotificationItem/"))

        let all = try ask(host, tray, .methodCall(
            destination: address.busName, path: address.path,
            interface: "org.freedesktop.DBus.Properties", member: "GetAll",
            body: [.string("org.kde.StatusNotifierItem")]
        ))
        var properties: [String: DBusValue] = [:]
        for entry in all.body.first?.elements ?? [] {
            if case .dictEntry(let key, let value) = entry, let name = key.string { properties[name] = value }
        }
        #expect(properties["Title"]?.string == "Timer_1")
        #expect(properties["IconName"]?.string == "media-playback-start")
        #expect(properties["ItemIsMenu"]?.unwrapped == .boolean(true))
        #expect(properties["Menu"]?.string == "/MenuBar")

        let layout = try ask(host, tray, .methodCall(
            destination: address.busName, path: "/MenuBar", interface: "com.canonical.dbusmenu",
            member: "GetLayout", body: [.int32(0), .int32(-1), .array(element: "s", [])]
        ))
        let rows = try #require(layout.body.dropFirst().first?.fields?[2].elements)
        let labels = rows.map { row -> String in
            let fields = row.fields ?? []
            for entry in fields.dropFirst().first?.elements ?? [] {
                if case .dictEntry(let key, let value) = entry {
                    if key.string == "label" { return value.string ?? "" }
                    if key.string == "type" { return "—" }
                }
            }
            return "?"
        }
        #expect(labels == ["Start", "—", "Reset"])
        let startID = try #require(rows.first?.fields?.first?.int32)
        let resetID = try #require(rows.last?.fields?.first?.int32)

        for id in [startID, resetID] {
            _ = try ask(host, tray, .methodCall(
                destination: address.busName, path: "/MenuBar", interface: "com.canonical.dbusmenu",
                member: "Event", body: [.int32(id), .string("clicked"), .variant(.int32(0)), .uint32(0)]
            ))
        }
        // The disabled row does nothing.
        #expect(chosen == ["start"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil))
    func activatingAPressItemPressesItAtThePoint() throws {
        var anchors: [TrayAnchor] = []
        let item = TrayItem(title: "Panel", action: .press { anchors.append($0) })
        let (tray, host, address) = try makeTray(with: item)
        defer { tray.removeAll(); host.close() }
        #expect(address.path == "/StatusNotifierItem")

        let menu = try ask(host, tray, .methodCall(
            destination: address.busName, path: address.path,
            interface: "org.freedesktop.DBus.Properties", member: "Get",
            body: [.string("org.kde.StatusNotifierItem"), .string("Menu")]
        ))
        #expect(menu.body.first?.string == "/NO_DBUSMENU")

        _ = try ask(host, tray, .methodCall(
            destination: address.busName, path: address.path, interface: "org.kde.StatusNotifierItem",
            member: "Activate", body: [.int32(1600), .int32(1060)]
        ))
        #expect(anchors == [TrayAnchor(x: 1600, y: 1060, width: 0, height: 0)])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil))
    func aChangeIsSignalledAndRead() throws {
        let item = TrayItem(title: "12:00", action: .menu([]))
        let (tray, host, address) = try makeTray(with: item)
        defer { tray.removeAll(); host.close() }
        _ = try ask(host, tray, .methodCall(
            destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus", member: "AddMatch",
            body: [.string("type='signal',sender='\(address.busName)'")]
        ))

        item.title = "12:01"
        item.icon = TrayIcon(width: 1, height: 1, pixels: [0x8040_2010])
        tray.refresh(item)
        var signals: [String] = []
        for _ in 0..<100 where !signals.contains("NewIcon") {
            tray.dispatch()
            signals += (host.receive() ?? []).filter { $0.kind == .signal }.compactMap(\.member)
            usleep(5000)
        }
        #expect(signals.contains("NewTitle"))
        #expect(signals.contains("NewIcon"))

        let pixmap = try ask(host, tray, .methodCall(
            destination: address.busName, path: address.path,
            interface: "org.freedesktop.DBus.Properties", member: "Get",
            body: [.string("org.kde.StatusNotifierItem"), .string("IconPixmap")]
        ))
        // ARGB in network byte order, the alpha taken out of the colour.
        let image = try #require(pixmap.body.first?.elements?.first?.fields)
        #expect(image[2] == .bytes([0x80, 0x80, 0x40, 0x20]))
    }
}
#endif
