#if os(macOS)
import XCTest
import Network
import Security
import CoreImage
import SwiftUI
@testable import OracleKit

/// Whole seconds: ISO 8601 keeps no fraction, so a round trip is exact.
private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

// MARK: - the payloads

/// Every CompanionAPI payload, through the encoder the Mac answers with and the decoder the phone reads with.
final class CompanionMacPayloadTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ v: T, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try CompanionAPI.encoder.encode(v)
        XCTAssertEqual(try CompanionAPI.decoder.decode(T.self, from: data), v, "\(what) did not survive the encoder and decoder", file: file, line: line)
    }

    func testEveryPayloadRoundTrips() throws {
        let pane = CompanionAPI.Pane(place: "laris-co:w22:p1", title: "Building the companion", status: "working", since: t0, cwd: "/opt/Code/x")
        let bare = CompanionAPI.Pane(place: "laris-co:w22:p2", title: "shell", status: "idle")
        let item = CompanionAPI.WorkItem(path: "/opt/Code/x/wt/companion-neo-issue46-7oct-wed2026", folder: "companion-neo-issue46-7oct-wed2026",
                                         branch: "feat/companion", isMain: false, issue: 46, prNumber: 44, prTitle: "companion: the contract",
                                         state: "needs you", panes: [pane, bare], resumeCommand: "cd '/opt/Code/x' && claude --resume abc")
        let main = CompanionAPI.WorkItem(path: "/opt/Code/x", folder: "x", branch: "main", isMain: true, issue: nil, prNumber: nil, prTitle: nil,
                                         state: "cold", panes: [], resumeCommand: nil)
        let entry = CompanionAPI.InboxEntry(path: "handoff/2026-10-05_x.md", name: "2026-10-05_x.md", folder: "handoff", modified: t0, unread: true)
        let pr = CompanionAPI.GHEntry(number: 44, title: "companion: ψ", author: "nazt", updatedAt: t0, url: URL(string: "https://github.com/a/b/pull/44"), isDraft: true, branch: "feat/companion")
        let issue = CompanionAPI.GHEntry(number: 46, title: "iPhone & iPad", author: "nazt", updatedAt: nil, url: nil, isDraft: false, branch: nil)
        let hit = CompanionAPI.SearchHit(id: "hist:ab12", kind: "history", title: "A session", snippet: "what was said", state: "user",
                                         url: "cd '/x' && claude --resume ab12", updated: "2026-10-07T01:02:03Z", repo: "laris-co/x", number: 2, score: 0.8125)

        try roundTrip(CompanionAPI.Hello(name: "Pulse", repoSlug: "laris-co/pulse", colorHex: "#ef5350", symbol: "waveform.path.ecg",
                                         appVersion: "v26.10.7-alpha.1841", api: CompanionAPI.version, host: "m5", allowsMessages: true), "Hello")
        try roundTrip(pane, "Pane"); try roundTrip(bare, "Pane without since and cwd")
        try roundTrip(item, "WorkItem"); try roundTrip(main, "WorkItem without issue, PR and resume")
        try roundTrip(CompanionAPI.Work(items: [item, main], activity: [pane, bare], problems: ["maw / herdr not answering"], refreshed: t0), "Work")
        try roundTrip(CompanionAPI.Work(items: [], activity: [], problems: [], refreshed: nil), "Work, nothing read yet")
        try roundTrip(CompanionAPI.Screen(place: "laris-co:w22:p1", text: "❯ claude\n  ψ\tฮัลโหล 🙂\n", read: t0), "Screen")
        try roundTrip(entry, "InboxEntry"); try roundTrip(CompanionAPI.Inbox(items: [entry]), "Inbox")
        try roundTrip(CompanionAPI.InboxFile(path: "handoff/2026-10-05_x.md", text: "# ψ ฿ 🙂\n\n- a\n", modified: t0), "InboxFile")
        try roundTrip(pr, "GHEntry"); try roundTrip(issue, "GHEntry without url, branch and date")
        try roundTrip(CompanionAPI.GitHub(prs: [pr], issues: [issue]), "GitHub")
        try roundTrip(hit, "SearchHit")
        try roundTrip(CompanionAPI.Search(query: "heartrate", hits: [hit], embedMs: 12.5, rankMs: 0.25, pool: 1_234), "Search")
        try roundTrip(CompanionAPI.MemoryStatus(items: 10, byKind: ["history": 7, "note": 3], sessions: 2, engine: "bundled CoreML/ANE", built: t0, hasMap: true), "MemoryStatus")
        try roundTrip(CompanionAPI.MemoryStatus(items: 0, byKind: [:], sessions: 0, engine: nil, built: nil, hasMap: false), "MemoryStatus, empty memory")
        try roundTrip(CompanionAPI.MapGroup(id: 3, count: 40, keywords: ["heart", "ble"]), "MapGroup")
        try roundTrip(CompanionAPI.MapGroup(id: 4, count: 12, keywords: ["ตรวจ"], title: "ตรวจสอบใหม่จริง"), "MapGroup, titled")
        XCTAssertNil(try CompanionAPI.decoder.decode(CompanionAPI.MapGroup.self, from: Data(#"{"id":1,"count":2,"keywords":[]}"#.utf8)).title,
                     "an older Mac sends no title")
        try roundTrip(CompanionAPI.MapData(ids: ["a", "b"], kinds: ["history", "note"], titles: ["one", "two"],
                                           xyz: MapLayout.pack([SIMD3(0.1, -0.2, 0.3), SIMD3(1, 2, 3)]),
                                           knn: Data([1, 0, 0, 0, 255, 255, 255, 255]), k: 1, labels: [0, 1],
                                           groups: [CompanionAPI.MapGroup(id: 0, count: 1, keywords: ["x"]), CompanionAPI.MapGroup(id: 1, count: 1, keywords: [])]), "MapData")
        try roundTrip(CompanionAPI.Hey(place: "laris-co:w22:p1", text: "ทำต่อเลย ✓"), "Hey")
        try roundTrip(CompanionAPI.Sent(ok: true), "Sent")
        try roundTrip(CompanionAPI.Problem(error: "unauthorized", fix: "on the Mac: Settings → Companion"), "Problem")
        try roundTrip(CompanionAPI.Problem(error: "no fix"), "Problem without a fix")
        try roundTrip(CompanionAPI.Pairing(host: "100.92.18.7", port: 4802, token: "00ff", name: "Pulse"), "Pairing")
    }

    /// Trace carries TraceLog.Entry, which is not Equatable: compare what the phone shows.
    func testTraceRoundTrips() throws {
        let e = TraceLog.Entry(at: t0, source: "companion", index: "history/laris-co__pulse", query: "ฮัลโหล map", filter: "kind=history who=user",
                               embedMs: 12.5, rankMs: 0.5, pool: 900, via: "in-process ANE",
                               top: [.init(id: "hist:1", title: "best", score: 0.75), .init(id: "hist:2", title: "next", score: 0.5)],
                               caller: "phone · companion")
        let back = try CompanionAPI.decoder.decode(CompanionAPI.Trace.self, from: CompanionAPI.encoder.encode(CompanionAPI.Trace(entries: [e, e])))
        XCTAssertEqual(back.entries.count, 2)
        let b = try XCTUnwrap(back.entries.first)
        XCTAssertEqual(b.id, e.id); XCTAssertEqual(b.at, e.at); XCTAssertEqual(b.source, "companion"); XCTAssertEqual(b.query, "ฮัลโหล map")
        XCTAssertEqual(b.filter, e.filter); XCTAssertEqual(b.embedMs, 12.5); XCTAssertEqual(b.rankMs, 0.5); XCTAssertEqual(b.pool, 900)
        XCTAssertEqual(b.top.map(\.id), ["hist:1", "hist:2"]); XCTAssertEqual(b.top.map(\.score), [0.75, 0.5]); XCTAssertEqual(b.caller, "phone · companion")
    }

    func testWireShape() throws {
        // dates are ISO 8601 strings, Data is base64, an error with no fix still decodes
        let json = String(decoding: try CompanionAPI.encoder.encode(CompanionAPI.Screen(place: "p", text: "t", read: t0)), as: UTF8.self)
        XCTAssertNotNil(json.range(of: #""read":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z""#, options: .regularExpression), json)
        let map = String(decoding: try CompanionAPI.encoder.encode(CompanionAPI.MapData(ids: [], kinds: [], titles: [], xyz: Data([0, 0, 128, 63]), knn: Data(), k: 0, labels: [], groups: [])), as: UTF8.self)
        XCTAssertTrue(map.contains(#""xyz":"AACAPw==""#), map)
        XCTAssertEqual(try CompanionAPI.decoder.decode(CompanionAPI.Problem.self, from: Data(#"{"error":"x"}"#.utf8)), CompanionAPI.Problem(error: "x"))
    }

    func testPortIsMCPPlusTen() {
        XCTAssertEqual([4791, 4792, 4793].map { CompanionAPI.port(mcp: UInt16($0)) }, [4801, 4802, 4803])
    }
}

// MARK: - the pairing link

final class CompanionMacPairingTests: XCTestCase {
    func testLinkRoundTripIPv4() throws {
        let p = CompanionAPI.Pairing(host: "100.92.18.7", port: 4802, token: String(repeating: "ab", count: 32), name: "Pulse")
        let url = try XCTUnwrap(p.link(scheme: "oracle-pulse"))
        XCTAssertEqual(url.scheme, "oracle-pulse"); XCTAssertEqual(url.host, "pair")
        XCTAssertTrue(url.absoluteString.hasPrefix("oracle-pulse://pair?host=100.92.18.7&port=4802&token="), url.absoluteString)
        XCTAssertEqual(CompanionAPI.Pairing.parse(url), p)
        XCTAssertEqual(p.baseURL?.absoluteString, "http://100.92.18.7:4802")
    }

    func testLinkRoundTripIPv6() throws {
        let p = CompanionAPI.Pairing(host: "fd7a:115c:a1e0::1", port: 4801, token: "00ff", name: "Neo")
        let url = try XCTUnwrap(p.link(scheme: "oracle-neo"))
        XCTAssertEqual(CompanionAPI.Pairing.parse(url), p, url.absoluteString)
        XCTAssertEqual(p.baseURL?.absoluteString, "http://[fd7a:115c:a1e0::1]:4801")   // an IPv6 host needs its brackets
        // the same link as a QR code or a paste: text out, URL in
        XCTAssertEqual(URL(string: url.absoluteString).flatMap(CompanionAPI.Pairing.parse), p)
    }

    func testLinkKeepsAnAwkwardName() throws {
        let p = CompanionAPI.Pairing(host: "127.0.0.1", port: 4803, token: "00ff", name: "Nëxus & Co ψ")
        let url = try XCTUnwrap(p.link(scheme: "oracle-nexus"))
        XCTAssertEqual(CompanionAPI.Pairing.parse(url), p, url.absoluteString)
    }

    /// Only the addresses a Mac serves on pair: a link in a web page or a message cannot point the phone at any server.
    func testOnlyTheMacsAddressesPair() {
        for ok in ["127.0.0.1", "127.8.0.2", "::1", "100.64.0.1", "100.92.18.7", "100.127.255.254"] {
            XCTAssertTrue(CompanionPairLink.servedAddress(ok), ok)
        }
        for no in ["attacker.example", "8.8.8.8", "100.128.0.1", "100.63.255.255", "192.168.1.10", "10.0.0.1", "100.064.0.1",
                   "1.2.3", "1.2.3.4.5", "256.1.1.1", "+1.2.3.4", "", "fd7a:115c:a1e0::1", "localhost"] {
            XCTAssertFalse(CompanionPairLink.servedAddress(no), no)
        }
        let link = URL(string: "oracle-test://pair?host=attacker.example&port=80&token=00ff&name=Test")!
        let found = CompanionPairLink.Found(url: link, pairing: CompanionAPI.Pairing.parse(link)!)
        let config = OracleConfig(name: "Test", tagline: "", repoSlug: "laris-co/test-oracle", localPath: "/tmp", colorHex: "#64b5f6", symbol: "circle")
        XCTAssertTrue(CompanionPairLink.mismatch(found, oracle: config)?.contains("Copy link") == true)
    }

    func testParseRefusesWhatIsMissing() {
        func parse(_ s: String) -> CompanionAPI.Pairing? { URL(string: s).flatMap(CompanionAPI.Pairing.parse) }
        XCTAssertNil(parse("oracle-pulse://pair?host=1.2.3.4&port=4802&name=Pulse"))             // no token
        XCTAssertNil(parse("oracle-pulse://pair?host=1.2.3.4&token=00ff&name=Pulse"))            // no port
        XCTAssertNil(parse("oracle-pulse://pair?host=1.2.3.4&port=70000&token=00ff&name=Pulse")) // not a port
        XCTAssertNil(parse("oracle-pulse://open?host=1.2.3.4&port=4802&token=00ff&name=Pulse"))  // not a pairing link
        XCTAssertNil(parse("oracle-pulse://pair?host=&port=4802&token=00ff&name=Pulse"))         // empty host
    }

    /// The code in Settings must scan: decode our own image back to the link.
    func testQRCodeCarriesTheLink() throws {
        let p = CompanionAPI.Pairing(host: "100.92.18.7", port: 4802, token: String(repeating: "9f", count: 32), name: "Pulse")
        let link = try XCTUnwrap(p.link(scheme: "oracle-pulse")).absoluteString
        let image = try XCTUnwrap(CompanionQR.image(link))
        XCTAssertGreaterThanOrEqual(image.width, 360)
        XCTAssertEqual(image.width, image.height)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]), "no QR detector here")
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [link])
    }
}

// MARK: - ψ/inbox stays ψ/inbox

final class CompanionMacConfineTests: XCTestCase {
    private var tmp: URL!
    private var root: String { tmp.appendingPathComponent("root").path }
    private var outside: String { tmp.appendingPathComponent("outside").path }

    override func setUpWithError() throws {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent("companion-confine-\(UUID().uuidString)")
        let r = tmp.appendingPathComponent("root"), o = tmp.appendingPathComponent("outside")
        for d in [r.appendingPathComponent("handoff/deep"), r.appendingPathComponent(".hidden"), o] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try "a".write(to: r.appendingPathComponent("handoff/a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: r.appendingPathComponent("handoff/deep/b.md"), atomically: true, encoding: .utf8)
        try "h".write(to: r.appendingPathComponent(".hidden/x.md"), atomically: true, encoding: .utf8)
        try "e".write(to: r.appendingPathComponent("handoff/.env"), atomically: true, encoding: .utf8)
        try "secret".write(to: o.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: r.appendingPathComponent("linkdir"), withDestinationURL: o)                                    // a folder that leaves
        try fm.createSymbolicLink(at: r.appendingPathComponent("linkfile.md"), withDestinationURL: o.appendingPathComponent("secret.txt"))   // a file that leaves
        try fm.createSymbolicLink(at: r.appendingPathComponent("inner"), withDestinationURL: r.appendingPathComponent("handoff"))      // a link that stays
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testAcceptsANestedFile() throws {
        let a = try XCTUnwrap(CompanionServer.confine(relative: "handoff/a.md", root: root))
        XCTAssertTrue(a.path.hasSuffix("/root/handoff/a.md"), a.path)
        let b = try XCTUnwrap(CompanionServer.confine(relative: "handoff/deep/b.md", root: root))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
        XCTAssertNotNil(CompanionServer.confine(relative: "inner/a.md", root: root), "a symlink that stays inside is fine")
        XCTAssertNotNil(CompanionServer.confine(relative: "handoff/deep/", root: root), "a folder is inside; the reader refuses it as not a file")
    }

    func testRejectsDotDot() {
        for rel in ["../outside/secret.txt", "handoff/../../outside/secret.txt", "..", "handoff/..", "handoff/deep/../../../outside/secret.txt"] {
            XCTAssertNil(CompanionServer.confine(relative: rel, root: root), rel)
        }
    }

    func testRejectsAbsolute() {
        for rel in ["/etc/passwd", "/", outside + "/secret.txt", root + "/handoff/a.md", "//etc/passwd"] {
            XCTAssertNil(CompanionServer.confine(relative: rel, root: root), rel)
        }
    }

    func testRejectsSymlinkOut() {
        XCTAssertNil(CompanionServer.confine(relative: "linkdir/secret.txt", root: root), "a folder link that leaves")
        XCTAssertNil(CompanionServer.confine(relative: "linkfile.md", root: root), "a file link that leaves")
        XCTAssertNil(CompanionServer.confine(relative: "linkdir", root: root), "the link itself resolves outside")
    }

    func testRejectsHiddenAndOddSpellings() {
        for rel in [".hidden/x.md", "handoff/.env", ".", "handoff/./a.md", "./handoff/a.md", "", "handoff/\u{0}a.md", "handoff/a\n.md"] {
            XCTAssertNil(CompanionServer.confine(relative: rel, root: root), rel.debugDescription)
        }
        XCTAssertNil(CompanionServer.confine(relative: "handoff/nope.md", root: root), "a file that is not there")
        XCTAssertNil(CompanionServer.confine(relative: "handoff/a.md", root: root + "/nope"), "a root that is not there")
        XCTAssertNil(CompanionServer.confine(relative: "handoff/a.md", root: ""))
    }

    func testSpellingRules() {
        XCTAssertTrue(CompanionServer.safe(relative: "handoff/2026-10-05_x.md"))
        XCTAssertTrue(CompanionServer.safe(relative: "dropped/ψ notes/ข้อความ.md"))
        XCTAssertFalse(CompanionServer.safe(relative: "a/../b"))
        XCTAssertTrue(CompanionServer.safe(relative: "~/b"), "a tilde is an ordinary name here; only the dots and the slash matter")
    }

    func testReadsOnlyRegularTextFiles() throws {
        let r = tmp.appendingPathComponent("root")
        func read(_ name: String) -> CompanionServer.FileRead { CompanionServer.readText(r.appendingPathComponent(name), limit: 512 * 1024) }
        if case .text(let t, let m) = read("handoff/a.md") { XCTAssertEqual(t, "a"); XCTAssertLessThan(abs(m.timeIntervalSinceNow), 60) } else { XCTFail("a.md") }
        try Data().write(to: r.appendingPathComponent("empty.md"))
        XCTAssertEqual(read("empty.md").textValue, "", "an empty file is an empty text, not an error")
        try "สวัสดี ψ 🙂".write(to: r.appendingPathComponent("thai.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(read("thai.md").textValue, "สวัสดี ψ 🙂")
        try Data(repeating: 0x61, count: 512 * 1024).write(to: r.appendingPathComponent("limit.txt"))
        XCTAssertNotNil(read("limit.txt").textValue, "exactly 512 KB is allowed")
        try Data(repeating: 0x61, count: 512 * 1024 + 1).write(to: r.appendingPathComponent("big.txt"))
        XCTAssertEqual(read("big.txt"), .tooLarge)
        try Data([0x68, 0x00, 0x69]).write(to: r.appendingPathComponent("nul.dat"))
        XCTAssertEqual(read("nul.dat"), .notText, "a NUL byte is a binary file")
        try Data([0xFF, 0xFE, 0x41]).write(to: r.appendingPathComponent("latin.txt"))
        XCTAssertEqual(read("latin.txt"), .notText, "not UTF-8")
        XCTAssertEqual(read("handoff"), .notRegular, "a folder")
        XCTAssertEqual(read("handoff/nope.md"), .missing)
        XCTAssertEqual(read("linkfile.md"), .notRegular, "a last symlink is never followed")
        XCTAssertEqual(mkfifo(r.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertEqual(read("pipe"), .notRegular, "a pipe is refused without waiting on it")
    }
}

private extension CompanionServer.FileRead {
    var textValue: String? { if case .text(let t, _) = self { t } else { nil } }
}

// MARK: - what the Mac maps into the payloads

final class CompanionMacMappingTests: XCTestCase {
    private func activity(_ place: String, _ status: String, _ cwd: String, _ title: String = "task") -> OracleSnapshot.Activity {
        .init(title: title, status: status, place: place, since: t0, cwd: cwd)
    }

    func testWorkItemsPanesAndTheOrderOfTheActivity() throws {
        let wt = "/r/neo-oracle/wt/companion-neo-issue46-7oct-wed2026"
        let ls = #"{"worktrees":[{"path":"/r/neo-oracle","branch":"main","linked":false,"state":"running","agents":1},{"path":"\#(wt)","branch":"feat/companion","linked":true,"state":"resumable","agents":0,"resume":{"id":"abc-123","provider":"claude"}}]}"#
        let acts = [activity("laris-co:w22:p1", "working", "/r/neo-oracle"), activity("laris-co:w22:p2", "blocked", wt), activity("laris-co:w22:p3", "idle", "/r/neo-oracle")]
        let pr = GHItem(number: 44, title: "companion: the contract", author: "nazt", updatedAt: nil, url: nil, isDraft: false, branch: "feat/companion")
        let items = WorkParse.items(ls: Data(ls.utf8), locks: [:], activity: acts, prs: [pr], localPath: "/r/neo-oracle")
        let w = CompanionServer.work(items: items, activity: acts, problems: ["gh failed"], refreshed: t0)

        XCTAssertEqual(w.activity.map(\.place), ["laris-co:w22:p2", "laris-co:w22:p1", "laris-co:w22:p3"], "blocked, working, idle")
        XCTAssertEqual(w.problems, ["gh failed"]); XCTAssertEqual(w.refreshed, t0)
        let tree = try XCTUnwrap(w.items.first { !$0.isMain }), main = try XCTUnwrap(w.items.first { $0.isMain })
        XCTAssertEqual(w.items.first?.id, tree.id, "needs-you work comes first")
        XCTAssertEqual(tree.state, "needs you"); XCTAssertEqual(tree.issue, 46)
        XCTAssertEqual(tree.prNumber, 44); XCTAssertEqual(tree.prTitle, "companion: the contract")
        XCTAssertEqual(tree.panes.map(\.place), ["laris-co:w22:p2"])
        XCTAssertEqual(tree.resumeCommand, "cd '\(wt)' && claude --resume abc-123")
        XCTAssertEqual(main.state, "working"); XCTAssertNil(main.resumeCommand); XCTAssertNil(main.prNumber)
        XCTAssertEqual(main.panes.map(\.place), ["laris-co:w22:p1", "laris-co:w22:p3"])
        XCTAssertEqual(main.panes.first?.since, t0)
        _ = try CompanionAPI.encoder.encode(w)
    }

    func testOnlyListedPlacesAreReadOrMessaged() {
        let a = activity("laris-co:w22:p1", "idle", "/r"), b = activity("laris-co:w22:p9", "idle", "/r/wt/x")
        let item = WorkParse.items(ls: Data(#"{"worktrees":[{"path":"/r","branch":"main","linked":false,"state":"running"}]}"#.utf8), locks: [:],
                                   activity: [b], prs: [], localPath: "/r")
        XCTAssertTrue(CompanionServer.listed("laris-co:w22:p1", activity: [a], work: []))
        XCTAssertTrue(CompanionServer.listed("laris-co:w22:p9", activity: [], work: item), "a pane a work item holds")
        XCTAssertFalse(CompanionServer.listed("laris-co:w22:p2", activity: [a], work: item))
        XCTAssertFalse(CompanionServer.listed("laris-co:w22", activity: [a], work: item), "a space is not a pane")
        XCTAssertFalse(CompanionServer.listed("", activity: [a], work: item))
        XCTAssertFalse(CompanionServer.listed("w22:p1", activity: [a], work: item), "the session is part of the place")
    }

    func testAMessageIsSafeToPassOn() {
        XCTAssertEqual(CompanionServer.safeMessage("  hello there \n"), "hello there")
        XCTAssertEqual(CompanionServer.safeMessage("ทำต่อเลย ✓\nline two\tend"), "ทำต่อเลย ✓\nline two\tend", "newline, tab and every script stay")
        XCTAssertEqual(CompanionServer.safeMessage("a\u{0}b"), "ab", "a NUL in a Process argument kills the app")
        XCTAssertEqual(CompanionServer.safeMessage("a\u{1B}[31mred\u{3}\r\u{7F}"), "a[31mred", "no ESC, Ctrl-C, CR or DEL")
        XCTAssertEqual(CompanionServer.safeMessage("--help"), " --help", "maw herdr hey would read it as an option")
        XCTAssertEqual(CompanionServer.safeMessage("- item one\n- item two"), " - item one\n- item two")
        XCTAssertEqual(CompanionServer.safeMessage("a - b --dry"), "a - b --dry", "only a leading dash is an option")
        XCTAssertEqual(CompanionServer.safeMessage(" \u{0} \n\t "), "")
        XCTAssertEqual(CompanionServer.printable("GET /v1/\u{1B}[2J\u{0}x"), "GET /v1/?[2J?x")
    }

    func testPaneReadCommand() {
        XCTAssertEqual(CompanionServer.readArgs(place: "laris-co:w22:p1"), ["--session", "laris-co", "pane", "read", "w22:p1", "--source", "recent", "--lines", "400"])
        XCTAssertNil(CompanionServer.readArgs(place: "w22"))
        XCTAssertNil(CompanionServer.readArgs(place: "-x:w22:p1"), "an option is never a session")
        XCTAssertNil(CompanionServer.readArgs(place: "laris-co:--help"))
        XCTAssertNil(CompanionServer.readArgs(place: ":w22"))
        XCTAssertEqual(CompanionServer.trimmed("a  \nb   \n\n  \n"), "a  \nb")
        XCTAssertEqual(CompanionServer.trimmed("   \n"), "")
    }

    func testInboxPathsAreRelativeToPsiInbox() {
        let root = "/r/neo/ψ/inbox"
        let items = [InboxItem(path: root + "/handoff/old.md", name: "old.md", folder: "handoff", modified: t0),
                     InboxItem(path: root + "/dropped/new.md", name: "new.md", folder: "dropped", modified: t0.addingTimeInterval(60)),
                     InboxItem(path: "/elsewhere/x.md", name: "x.md", folder: "inbox", modified: t0)]
        let inbox = CompanionServer.inbox(items: items, unread: [root + "/dropped/new.md"], root: root)
        XCTAssertEqual(inbox.items.map(\.path), ["dropped/new.md", "handoff/old.md"], "newest first; a path outside the inbox is dropped")
        XCTAssertEqual(inbox.items.map(\.unread), [true, false])
        XCTAssertEqual(inbox.items.first?.folder, "dropped")
        XCTAssertEqual(CompanionServer.inbox(items: items, unread: [], root: root + "/").items.count, 2, "a trailing slash on the root changes nothing")
    }

    @MainActor func testSearchKindsAreMCPsKinds() {
        XCTAssertTrue(MCPServer.kinds.filter { $0 != "all" }.allSatisfy { CompanionServer.filter(kind: $0).kind != nil }, "every MCP kind but all narrows the search")
        let f = { (k: String) in CompanionServer.filter(kind: k) }
        XCTAssertTrue(f("all") == (nil, nil)); XCTAssertTrue(f("sessions") == ("history", nil)); XCTAssertTrue(f("you") == ("history", "user"))
        XCTAssertTrue(f("oracle") == ("history", "assistant")); XCTAssertTrue(f("notes") == ("note", nil))
        XCTAssertTrue(f("issues") == ("issue", nil)); XCTAssertTrue(f("prs") == ("pr", nil))
    }

    private func doc(_ kind: String, _ title: String, _ snippet: String, hash: String, number: Int = 0) -> IndexDoc {
        IndexDoc(repo: "laris-co/x", kind: kind, number: number, title: title, state: kind == "history" ? "user" : "OPEN", url: "file:///\(hash)",
                 updated: "2026-10-07T00:00:00Z", snippet: snippet, hash: hash, vec: [1, 0])
    }

    func testSearchHitAndCounts() {
        let d = doc("pr", "A PR", "body", hash: "p", number: 44)
        let h = CompanionServer.hit(IndexHit(doc: d, score: 0.5))
        XCTAssertEqual(h.id, "laris-co/x#44"); XCTAssertEqual(h.kind, "pr"); XCTAssertEqual(h.number, 44); XCTAssertEqual(h.score, 0.5)
        XCTAssertEqual(CompanionServer.hit(IndexHit(doc: d, score: .nan)).score, 0, "a NaN would fail the whole answer")
        let c = CompanionServer.counts([doc("history", "a", "", hash: "1"), doc("history", "b", "", hash: "2"), d])
        XCTAssertEqual(c.byKind, ["history": 2, "pr": 1])
        XCTAssertEqual(c.sessions, 2, "sessions are counted by their resume command")
    }

    func testMapRowsAlignAcrossArrays() throws {
        let long = String(repeating: "ก", count: 300)
        let h1 = doc("history", "Session title", long, hash: "h1"), h2 = doc("history", "Only a title", "", hash: "h2")
        let note = doc("note", "A note\nwith lines", "body", hash: "n")
        let ids = [h1.id, h2.id, note.id, "hist:gone"]
        let xyz: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let knn: [Int32] = [1, 2, 0, -1, 2, 3, 0, 1]
        let groups = [MapClusters.Group(id: 0, count: 2, keywords: ["a", "b"]), MapClusters.Group(id: 1, count: 2, keywords: ["c"])]
        let m = CompanionServer.mapData(ids: ids, xyz: xyz, knn: knn, k: 2, docs: [h1, h2, note], labels: [0, 0, 1, 1], groups: groups)
        XCTAssertEqual(m.ids, ids)
        XCTAssertEqual(m.kinds, ["history", "history", "note", ""])
        XCTAssertEqual(m.titles[0], String(long.prefix(120)), "a session piece is named by what was said, cut at 120")
        XCTAssertEqual(m.titles[1], "Only a title", "no snippet: the title")
        XCTAssertEqual(m.titles[2], "A note with lines")
        XCTAssertEqual(m.titles[3], "hist:gone", "a doc the index lost keeps its id")
        XCTAssertEqual(m.xyz.count, 48); XCTAssertEqual(m.xyz, MapLayout.pack(xyz))
        XCTAssertEqual(m.knn.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }, knn); XCTAssertEqual(m.k, 2)
        XCTAssertEqual(m.labels, [0, 0, 1, 1]); XCTAssertEqual(m.groups.map(\.keywords), [["a", "b"], ["c"]])
        // a layout whose knn or groups do not match its rows says so with empty arrays, never with misaligned ones
        let odd = CompanionServer.mapData(ids: ids, xyz: xyz, knn: [1, 2, 3], k: 2, docs: [h1], labels: [0], groups: groups)
        XCTAssertEqual(odd.k, 0); XCTAssertTrue(odd.knn.isEmpty); XCTAssertTrue(odd.labels.isEmpty); XCTAssertTrue(odd.groups.isEmpty)
        XCTAssertEqual(odd.ids.count, odd.titles.count)
    }

    func testANaNInATraceDoesNotFailTheAnswer() throws {
        let bad = TraceLog.Entry(at: t0, source: "page", index: "i", query: "q", filter: "all", embedMs: .nan, rankMs: 1, pool: 1, via: "v",
                                 top: [.init(id: "a", title: "t", score: .infinity)])
        let fixed = CompanionServer.finite(bad)
        XCTAssertEqual(fixed.id, bad.id); XCTAssertEqual(fixed.embedMs, 0); XCTAssertEqual(fixed.top.first?.score, 0)
        _ = try CompanionAPI.encoder.encode(CompanionAPI.Trace(entries: [fixed]))
        let fine = TraceLog.Entry(at: t0, source: "page", index: "i", query: "q", filter: "all", embedMs: 1, rankMs: 1, pool: 1, via: "v", top: [])
        XCTAssertEqual(CompanionServer.finite(fine).id, fine.id)
    }
}

// MARK: - what Settings → Companion looks like

/// `RENDER_COMPANION=<dir> swift test --filter CompanionMacRenderTests` → PNGs of the Settings → Companion card: off, listening
/// with the Mac's NetBird address, and a test token (127.0.0.1 only, "simulator only"). ImageRenderer draws AppKit switches
/// and buttons as placeholders; the text, the layout and the QR code are the real ones.
@MainActor
final class CompanionMacRenderTests: XCTestCase {
    private func framed(_ s: CompanionServer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Companion — iPhone · iPad", systemImage: "iphone").font(.headline).foregroundStyle(.mint).padding(.bottom, 8)
            CompanionCard(companion: s)
        }
        .padding(16).frame(width: 780, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(20).background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)
    }

    private func png<V: View>(_ v: V, to path: String) throws {
        let r = ImageRenderer(content: v); r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    func testRenderTheCard() async throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_COMPANION"] else { throw XCTSkip("set RENDER_COMPANION=<dir>") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let suite = "co.laris.oracle.companion.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = GHIndex(name: "render-\(UUID().uuidString)")

        func make(_ args: [String]) async throws -> (CompanionServer, UInt16) {
            let s = CompanionServer(keychain: false, defaults: defaults)
            let port = UInt16.random(in: 30_000...60_000)
            s.configure(name: "Pulse", mcpPort: 4792, index: { index }, args: args + ["-companionPort", "\(port)"])
            for _ in 0..<100 where s.enabled && !s.running { try await Task.sleep(for: .milliseconds(30)) }
            return (s, port)
        }
        let (off, _) = try await make([])
        try png(framed(off), to: "\(dir)/companion-off.png")

        let (mesh, meshPort) = try await make(["-companion", "on"])
        defer { mesh.stop() }
        for path in ["/v1/hello", "/v1/work", "/v1/inbox/file?path=../../etc/passwd", "/v1/screen?place=laris-co:w22:p1"] {   // a few calls for the log
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(meshPort)\(path)")!)
            r.setValue("Bearer \(mesh.token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession(configuration: .ephemeral).data(for: r)
        }
        try png(framed(mesh), to: "\(dir)/companion-mesh.png")

        let (sim, _) = try await make(["-companion", "on", "-companionToken", "00ff"])
        defer { sim.stop() }
        try png(framed(sim), to: "\(dir)/companion-simulator.png")
    }
}
#endif
