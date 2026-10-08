import XCTest
@testable import OracleKit

#if os(macOS)
import AppKit

/// Right-click → Delete session (Nat, 2026-10-08): herdr's list, what a stopped session holds, the copy kept first.
/// And a click on an app card: the front link, and where the app puts its window.
final class SessionDeleteTests: XCTestCase {
    func testTheListCarriesTheDefaultAndTheFolder() {
        let json = #"{"sessions":[{"default":true,"name":"default","running":true,"session_dir":"/Users/x/.config/herdr"},"# +
                   #"{"default":false,"name":"infra-teamexit","running":false,"session_dir":"/Users/x/.config/herdr/sessions/infra-teamexit"}]}"#
        let s = HubParse.sessions(Data(json.utf8))
        XCTAssertEqual(s.map(\.name), ["default", "infra-teamexit"])
        XCTAssertEqual(s.map(\.isDefault), [true, false])
        XCTAssertEqual(s[1].dir, "/Users/x/.config/herdr/sessions/infra-teamexit")
        XCTAssertFalse(s[1].running)
    }

    func testWhatASessionHoldsAndTheCopyKeptFirst() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-session-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("maeon"), root = tmp.appendingPathComponent("deleted")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let session = #"{"workspaces":[{"custom_name":null,"identity_cwd":"/opt/Code/github.com/x/maeon-craft-oracle","id":"w1"},"# +
                      #"{"custom_name":"pulse-team","id":"w2"},{"id":"w3"}]}"#
        try Data(session.utf8).write(to: dir.appendingPathComponent("session.json"))
        try Data("log line\n".utf8).write(to: dir.appendingPathComponent("logs/herdr-server.log"))
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("herdr.sock").path, 0o600), 0)   // a special file, like a stale socket
        let s = HubSession(name: "maeon", running: false, dir: dir.path)

        let c = HubStore.contents(of: s)
        XCTAssertEqual(c.spaces, ["maeon-craft-oracle", "pulse-team", "w3"])
        XCTAssertEqual(c.files, 2, "the fifo is not a file to keep")

        let when = Date(timeIntervalSince1970: 1_791_000_000)
        guard case .copy(let kept) = HubStore.keepCopy(of: s, at: when, into: root) else { return XCTFail("no copy") }
        XCTAssertTrue(kept.lastPathComponent.hasPrefix("maeon-"))
        XCTAssertEqual(try String(contentsOf: kept.appendingPathComponent("logs/herdr-server.log"), encoding: .utf8), "log line\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("session.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent("herdr.sock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path), "the copy leaves the folder alone")
    }

    func testTheDefaultAndARunningSessionAreRefused() {
        let d = HubStore.refusal(HubSession(name: "default", running: true, isDefault: true, dir: "/tmp/none"))
        XCTAssertTrue(d?.contains("default session") == true, d ?? "")
        let r = HubStore.refusal(HubSession(name: "laris-co", running: true, dir: "/tmp/none"))
        XCTAssertTrue(r?.contains("herdr session stop laris-co") == true, r ?? "")
        XCTAssertNil(HubStore.refusal(HubSession(name: "infra-teamexit", running: false, dir: "/tmp/none")))
    }

    func testTheFrontLinkComesFromTheAppsOwnScheme() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Neo-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let info: [String: Any] = ["CFBundleIdentifier": "co.laris.oracle.test\(UUID().uuidString.prefix(6))", "CFBundlePackageType": "APPL",
                                   "CFBundleURLTypes": [["CFBundleURLName": "x", "CFBundleURLSchemes": ["oracle-neo"]]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(HubStore.frontLink(app: app, display: 7)?.absoluteString, "oracle-neo://front?display=7")
    }

    func testAWindowIsCentredAndFitsTheDisplay() {
        let main = NSRect(x: 0, y: 0, width: 2560, height: 1415)   // the main display's visible frame
        XCTAssertEqual(OracleAppDelegate.centred(NSSize(width: 1120, height: 740), in: main), NSRect(x: 720, y: 338, width: 1120, height: 740))
        // a tall window from the portrait display is shrunk to fit
        XCTAssertEqual(OracleAppDelegate.centred(NSSize(width: 1500, height: 2900), in: main), NSRect(x: 530, y: 0, width: 1500, height: 1415))
    }
}
#endif
