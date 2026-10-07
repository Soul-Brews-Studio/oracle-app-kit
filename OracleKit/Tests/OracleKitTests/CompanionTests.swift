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

// MARK: - the gate: who may connect, who may ask

final class CompanionMacGateTests: XCTestCase {
    func testOnlyLoopbackAndTheMeshMayConnect() {
        func ok(_ ip: String) -> Bool {
            CompanionServer.remoteAllowed(.hostPort(host: .ipv4(IPv4Address(ip)!), port: 1234))
        }
        for ip in ["127.0.0.1", "127.9.9.9", "100.64.0.1", "100.92.18.7", "100.127.255.254"] { XCTAssertTrue(ok(ip), ip) }
        for ip in ["0.0.0.0", "10.0.0.1", "100.63.255.255", "100.128.0.1", "100.0.0.1", "169.254.1.1", "172.16.0.1", "192.168.1.177", "8.8.8.8", "255.255.255.255"] { XCTAssertFalse(ok(ip), ip) }
    }

    func testIPv6AndNames() {
        func ok(_ ip: String) -> Bool { CompanionServer.remoteAllowed(.hostPort(host: .ipv6(IPv6Address(ip)!), port: 1234)) }
        XCTAssertTrue(ok("::1")); XCTAssertTrue(ok("::ffff:127.0.0.1")); XCTAssertTrue(ok("::ffff:100.64.0.9"))
        XCTAssertFalse(ok("::ffff:192.168.1.5")); XCTAssertFalse(ok("fe80::1")); XCTAssertFalse(ok("fd7a:115c:a1e0::1")); XCTAssertFalse(ok("::"))
        XCTAssertFalse(CompanionServer.remoteAllowed(.hostPort(host: .name("localhost", nil), port: 1)), "a host name is never trusted")
        XCTAssertFalse(CompanionServer.remoteAllowed(.service(name: "x", type: "_http._tcp", domain: "local", interface: nil)))
        XCTAssertFalse(CompanionServer.allowed(ipv4: [127, 0, 0]))
    }

    func testListensOnLoopbackAndTheMeshOnly() {
        XCTAssertEqual(CompanionServer.wantedAddresses(loopbackOnly: true), ["127.0.0.1"])
        let all = CompanionServer.wantedAddresses(loopbackOnly: false)
        XCTAssertEqual(all.first, "127.0.0.1")
        XCTAssertFalse(all.contains("0.0.0.0"))
        for a in all.dropFirst() { XCTAssertTrue(CompanionServer.allowed(ipv4: a.split(separator: ".").compactMap { UInt8($0) }) && !CompanionServer.isLoopback(a), a) }
    }

    func testFixHintsQuoteAPath() {
        XCTAssertEqual(CompanionServer.shellQuoted("/a b/c.md"), "'/a b/c.md'")
        XCTAssertEqual(CompanionServer.shellQuoted("/x/it's.md"), "'/x/it'\\''s.md'")   // a quote can't end the argument
        XCTAssertEqual(CompanionServer.maxPerPeer, 12)
        XCTAssertTrue(CompanionServer.isLoopbackEndpoint(.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: 1)))   // this Mac: no per-peer cap
        XCTAssertFalse(CompanionServer.isLoopbackEndpoint(.hostPort(host: .ipv4(IPv4Address("100.92.18.7")!), port: 1)))
    }

    func testConstantTimeCompare() {
        let t = String(repeating: "ab", count: 32)
        XCTAssertTrue(CompanionServer.constantTimeEquals(t, t))
        XCTAssertFalse(CompanionServer.constantTimeEquals(t, String(t.dropLast()) + "c"))     // last character
        XCTAssertFalse(CompanionServer.constantTimeEquals(t, "c" + t.dropFirst()))             // first character
        XCTAssertFalse(CompanionServer.constantTimeEquals(t, String(t.dropLast())))            // a prefix
        XCTAssertFalse(CompanionServer.constantTimeEquals(t, t + "0"))
        XCTAssertFalse(CompanionServer.constantTimeEquals(t, ""))
        XCTAssertFalse(CompanionServer.constantTimeEquals("", t))
        XCTAssertTrue(CompanionServer.constantTimeEquals("", ""))
    }

    func testTokens() throws {
        let a = try XCTUnwrap(CompanionServer.makeToken()), b = try XCTUnwrap(CompanionServer.makeToken())
        XCTAssertEqual(a.count, 64); XCTAssertTrue(a.allSatisfy(\.isHexDigit)); XCTAssertNotEqual(a, b)
        XCTAssertTrue(CompanionServer.validToken("00ff")); XCTAssertTrue(CompanionServer.validToken(a))
        XCTAssertFalse(CompanionServer.validToken("")); XCTAssertFalse(CompanionServer.validToken("a b")); XCTAssertFalse(CompanionServer.validToken("ψ"))
        XCTAssertFalse(CompanionServer.validToken(String(repeating: "a", count: 129)))
    }

    /// A real Keychain item under a throwaway account; skipped where the Keychain is not open.
    func testKeychainKeepsTheToken() throws {
        let account = "test-\(UUID().uuidString)"
        defer { CompanionServer.keychainDelete(account: account) }
        let a = try XCTUnwrap(CompanionServer.makeToken()), b = try XCTUnwrap(CompanionServer.makeToken())
        let status = CompanionServer.keychainWrite(a, account: account)
        try XCTSkipIf(status != errSecSuccess, "the Keychain is not available here (OSStatus \(status))")
        XCTAssertEqual(CompanionServer.keychainRead(account: account), a)
        XCTAssertEqual(CompanionServer.keychainWrite(b, account: account), errSecSuccess)   // the update path
        XCTAssertEqual(CompanionServer.keychainRead(account: account), b)
        CompanionServer.keychainDelete(account: account)
        XCTAssertNil(CompanionServer.keychainRead(account: account))
    }

    func testLaunchOptions() {
        let args = ["/x/Pulse", "-companion", "on", "-companionPort", "4899", "-companionToken", "00ff", "-other"]
        XCTAssertEqual(CompanionServer.option("companion", in: args), "on")
        XCTAssertEqual(CompanionServer.option("companionPort", in: args), "4899")
        XCTAssertEqual(CompanionServer.option("companionToken", in: args), "00ff")
        XCTAssertNil(CompanionServer.option("other", in: args), "a flag with no value")
        XCTAssertNil(CompanionServer.option("missing", in: args))
    }

    // the HTTP gate in front of MCPServer's parser

    private func frame(_ s: String) -> String {
        switch CompanionServer.frame(Data(s.utf8)) {
        case .more(let need): need.map { "more, needs \($0)" } ?? "more"
        case .bad(let status, _): "bad \(status)"
        case .request(let r): "request \(r.method) \(r.path) \(r.body.count)"
        }
    }

    func testFraming() {
        XCTAssertEqual(frame("GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer x\r\n\r\n"), "request GET /v1/hello 0")
        XCTAssertEqual(frame("GET /v1/hello HTTP/1.1\r\nAuthor"), "more", "the headers are not all here: nothing is known yet")
        let head = "POST /v1/hey HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        XCTAssertEqual(frame(head), "more, needs \(head.utf8.count + 5)", "the headers are read: the body is what is missing")
        XCTAssertEqual(frame(head + "hel"), "more, needs \(head.utf8.count + 5)")
        XCTAssertEqual(frame("POST /v1/hey HTTP/1.1\r\ncontent-length: 5\r\n\r\nhello"), "request POST /v1/hey 5")
        XCTAssertEqual(frame("GET /v1/work?x=1 HTTP/1.1\r\n\r\n"), "request GET /v1/work?x=1 0")
    }

    /// The reader asks the socket for `need - buffered` bytes and does not parse again before they are there, so what the
    /// headers said has to be the same at every cut of the request.
    func testEveryCutOfARequestSaysWhatItNeeds() {
        let head = "POST /v1/hey HTTP/1.1\r\nHost: x\r\ncontent-length: 12\r\n\r\n", body = "hello, world"
        let bytes = Array((head + body).utf8), total = bytes.count
        for n in 0...total {
            let got = frame(String(decoding: bytes[..<n], as: UTF8.self))
            if n < head.utf8.count { XCTAssertEqual(got, "more", "\(n) bytes: no blank line yet") }
            else if n < total { XCTAssertEqual(got, "more, needs \(total)", "\(n) bytes: headers read, body not whole") }
            else { XCTAssertEqual(got, "request POST /v1/hey 12", "\(n) bytes: all of it") }
        }
    }

    /// 4 KB of headers is a lot for a phone: a URLSession request is a few hundred bytes. A search typed in Thai (9 bytes per
    /// character once percent-encoded) still fits; a header block the size of a page does not.
    func testHeaderRoomIsGenerousForAPhoneAndTightForAnAttacker() {
        let q = String(repeating: "ทำไม", count: 50).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let phone = "GET /v1/search?kind=all&limit=25&q=\(q) HTTP/1.1\r\nHost: 100.92.18.7:4801\r\nAuthorization: Bearer \(String(repeating: "f", count: 64))\r\n"
            + "Accept: */*\r\nUser-Agent: ARRA%20Pulse/0.1 CFNetwork/3860.100.1 Darwin/25.0.0\r\nAccept-Language: en-GB,en;q=0.9\r\nAccept-Encoding: gzip, deflate\r\n\r\n"
        XCTAssertGreaterThan(phone.utf8.count, 1_500, "a long Thai search")
        XCTAssertLessThan(phone.utf8.count, CompanionServer.maxHeader)
        XCTAssertEqual(frame(phone), "request GET /v1/search?kind=all&limit=25&q=\(q) 0")
        let pad = { (n: Int) in "GET /v1/hello HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: n) + "\r\n\r\n" }
        XCTAssertEqual(frame(pad(CompanionServer.maxHeader - 64)), "request GET /v1/hello 0")
        XCTAssertEqual(frame(pad(CompanionServer.maxHeader + 64)), "bad 431")
        XCTAssertLessThanOrEqual(CompanionServer.maxHeader, 4 << 10, "the headers of every request are parsed on the main thread, and the buffer is scanned for each chunk of a slow one: more room is more work for any caller")
    }

    func testFramingRefusesWhatWouldTrapTheParser() {
        XCTAssertEqual(frame("POST /v1/hey HTTP/1.1\r\nContent-Length: -1\r\n\r\n"), "bad 400", "a negative length traps MCPServer.parse's slice")
        XCTAssertEqual(frame("POST /v1/hey HTTP/1.1\r\nContent-Length: abc\r\n\r\n"), "bad 400")
        XCTAssertEqual(frame("POST /v1/hey HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n"), "bad 400")
        XCTAssertEqual(frame("POST /v1/hey HTTP/1.1\r\nContent-Length: \(CompanionServer.maxBody + 1)\r\n\r\n"), "bad 413")
        XCTAssertEqual(frame("GET\r\n\r\n"), "bad 400")
        XCTAssertEqual(frame("\r\n\r\n"), "bad 400")
        XCTAssertEqual(frame("GET /" + String(repeating: "a", count: CompanionServer.maxHeader + 10)), "bad 431", "no end of headers in sight")
        XCTAssertEqual(frame("GET /v1/hello HTTP/1.1\r\nX: " + String(repeating: "a", count: CompanionServer.maxHeader + 10) + "\r\n\r\n"), "bad 431")
    }
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

// MARK: - the server itself, over loopback

/// A real CompanionServer on a free port, with a temporary checkout for its inbox, asked through URLSession and raw sockets.
@MainActor
final class CompanionMacServerTests: XCTestCase {
    private var server: CompanionServer!
    private var store: OracleStore!
    private var index: GHIndex!
    private var defaults: UserDefaults!
    private var suite = ""
    private var tmp: URL!
    private var port: UInt16 = 0
    private var session: URLSession!

    override func setUp() async throws {
        let fm = FileManager.default
        tmp = fm.temporaryDirectory.appendingPathComponent("companion-server-\(UUID().uuidString)")
        let inbox = tmp.appendingPathComponent("checkout/ψ/inbox"), outside = tmp.appendingPathComponent("outside")
        try fm.createDirectory(at: inbox.appendingPathComponent("handoff"), withIntermediateDirectories: true)
        try fm.createDirectory(at: inbox.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "hello ψ — สวัสดี\n".write(to: inbox.appendingPathComponent("handoff/note.md"), atomically: true, encoding: .utf8)
        try "x".write(to: inbox.appendingPathComponent(".hidden/x.md"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x61, count: 600 * 1024).write(to: inbox.appendingPathComponent("big.txt"))
        try Data([0x41, 0x00, 0x42]).write(to: inbox.appendingPathComponent("bin.dat"))
        try fm.createSymbolicLink(at: inbox.appendingPathComponent("linkdir"), withDestinationURL: outside)

        suite = "co.laris.oracle.companion.tests"   // one suite for every test: a random name leaves a plist behind per run
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = OracleStore(config: OracleConfig(name: "Test", tagline: "a test", repoSlug: "laris-co/test-oracle",
                                                 localPath: tmp.appendingPathComponent("checkout").path, colorHex: "#64b5f6", symbol: "circle"))
        index = GHIndex(name: "test-companion-\(UUID().uuidString)")
        CompanionServer.servesUnrefreshed = true   // this store never refreshes (that would run maw, gh and herdr)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        CompanionServer.servesUnrefreshed = false
        server?.stop()
        defaults?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Starts a server (a few tries: the port is random) and waits for its listeners.
    private func start(_ extra: [String] = []) async throws {
        for _ in 0..<6 {
            port = UInt16.random(in: 30_000...60_000)
            let s = CompanionServer(keychain: false, defaults: defaults)
            s.attach(store: store)
            s.configure(name: "Test", mcpPort: 4791, index: { [index] in index! }, args: ["-companion", "on", "-companionPort", "\(port)"] + extra)
            server = s
            for _ in 0..<100 where !s.running { try await Task.sleep(for: .milliseconds(30)) }
            if s.running { return }
            s.stop()
        }
        XCTFail("the server did not start: \(server?.problem ?? "no reason")")
    }

    private struct Answer {
        let status: Int, data: Data, headers: [AnyHashable: Any]
        func json<T: Decodable>(_ t: T.Type) throws -> T { try CompanionAPI.decoder.decode(T.self, from: data) }
        var problem: CompanionAPI.Problem? { try? CompanionAPI.decoder.decode(CompanionAPI.Problem.self, from: data) }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    private enum Who { case server, nobody, token(String) }

    private func call(_ path: String, token: String?, method: String = "GET", body: Data? = nil, host: String = "127.0.0.1") async throws -> Answer {
        var r = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await session.data(for: r)
        let h = try XCTUnwrap(resp as? HTTPURLResponse)
        return Answer(status: h.statusCode, data: d, headers: h.allHeaderFields)
    }

    /// One request, its status asserted; the answer comes back for more checks. (An `await` cannot sit inside XCTAssert's autoclosure.)
    @discardableResult
    private func expect(_ status: Int, _ path: String, as who: Who = .server, method: String = "GET", body: Data? = nil, host: String = "127.0.0.1",
                        _ why: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> Answer {
        let token: String? = switch who { case .server: server.token; case .nobody: nil; case .token(let t): t }
        let a = try await call(path, token: token, method: method, body: body, host: host)
        XCTAssertEqual(a.status, status, "\(method) \(path) \(why)", file: file, line: line)
        return a
    }

    /// Raw bytes to the port; everything that comes back until the server closes. Off the main actor: the server runs on it.
    /// `then`: more bytes, each piece `pause` µs after the one before (a slow link). `halfClose`: say "that is all" after the last one.
    private func raw(_ bytes: String, host: String = "127.0.0.1", from: String? = nil, port override: UInt16? = nil,
                     then pieces: [String] = [], pause: UInt32 = 0, halfClose: Bool = false) async -> String {
        let port = override ?? self.port
        return await Task.detached { () -> String in
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return "socket failed" }
            defer { Darwin.close(fd) }
            var one: Int32 = 1, tv = timeval(tv_sec: 5, tv_usec: 0), connectSeconds: Int32 = 3
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))   // a server that hung up first must not kill the test
            setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &connectSeconds, socklen_t(MemoryLayout<Int32>.size))   // not the 75 s of a dropped SYN
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr(ip)
                return a
            }
            if let from {   // choose the source address: what the server sees as the remote
                var src = address(from, 0)
                let bound = withUnsafePointer(to: &src) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                guard bound == 0 else { return "bind failed: \(errno)" }
            }
            var dst = address(host, port)
            let connected = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { return "connect failed: \(errno)" }
            _ = bytes.withCString { Darwin.send(fd, $0, strlen($0), 0) }
            for piece in pieces {
                usleep(pause)
                _ = piece.withCString { Darwin.send(fd, $0, strlen($0), 0) }
            }
            if halfClose { Darwin.shutdown(fd, SHUT_WR) }
            var out = Data(), buf = [UInt8](repeating: 0, count: 8192)
            while true { let n = Darwin.recv(fd, &buf, buf.count, 0); if n <= 0 { break }; out.append(buf, count: n) }
            return String(decoding: out, as: UTF8.self)
        }.value
    }

    /// `s` in pieces of `n` bytes — a cut may fall inside a CRLF.
    private func cut(_ s: String, by n: Int) -> [String] {
        let b = Array(s.utf8)
        return stride(from: 0, to: b.count, by: n).map { String(decoding: b[$0..<min($0 + n, b.count)], as: UTF8.self) }
    }

    /// A caller that sends `head`, then one byte every 150 µs for `seconds`: a body that never finishes.
    private nonisolated static func drip(port: UInt16, head: String, seconds: Double) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))   // every byte its own segment
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return }
        _ = head.withCString { Darwin.send(fd, $0, strlen($0), 0) }
        var byte: UInt8 = 0x78
        let stop = Date().addingTimeInterval(seconds)
        while Date() < stop, Darwin.send(fd, &byte, 1, 0) == 1 { usleep(150) }
    }

    /// CPU seconds (user + system) the calling thread has used so far: on the main actor, the main thread's.
    private nonisolated static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1_000_000 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    private func httpCode(_ raw: String) -> String { String(raw.split(separator: " ", maxSplits: 2).dropFirst().first ?? "none") }

    private func expectRaw(_ code: String, _ bytes: String, _ why: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let answer = await raw(bytes)
        XCTAssertEqual(httpCode(answer), code, "\(bytes.prefix(60).debugDescription) \(why)", file: file, line: line)
    }

    // MARK: auth

    func testNoTokenNoAnswer() async throws {
        try await start()
        for path in [CompanionAPI.Path.hello, CompanionAPI.Path.work, CompanionAPI.Path.inbox, "/v1/nothing", "/"] {
            let a = try await expect(401, path, as: .nobody)
            XCTAssertEqual(a.problem?.fix, "on the Mac: Settings → Companion, then scan its code again", path)
            XCTAssertNotNil(a.problem?.error, path)
        }
        // a wrong token, a prefix of the right one, the right one with more, nothing at all: refused before routing
        for t in ["wrong", String(server.token.dropLast()), server.token + "0", ""] { try await expect(401, CompanionAPI.Path.work, as: .token(t), "token \(t.prefix(8))") }
        try await expect(401, CompanionAPI.Path.hey, as: .nobody, method: "POST", body: Data(#"{"place":"a:b","text":"x"}"#.utf8), "the write is behind the token too")
        var basic = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/hello")!)
        basic.setValue("Basic \(server.token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await session.data(for: basic)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 401, "another scheme is not a bearer token")
        await expectRaw("200", "GET /v1/hello HTTP/1.1\r\nAuthorization: bearer \(server.token)\r\n\r\n", "the scheme is case-insensitive")
        await expectRaw("401", "GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer\r\n\r\n")
    }

    func testHelloWithTheToken() async throws {
        try await start()
        let a = try await expect(200, CompanionAPI.Path.hello)
        XCTAssertEqual((a.headers["Content-Type"] as? String)?.hasPrefix("application/json"), true)
        let h = try a.json(CompanionAPI.Hello.self)
        XCTAssertEqual(h.name, "Test"); XCTAssertEqual(h.repoSlug, "laris-co/test-oracle"); XCTAssertEqual(h.colorHex, "#64b5f6"); XCTAssertEqual(h.symbol, "circle")
        XCTAssertEqual(h.api, CompanionAPI.version); XCTAssertFalse(h.allowsMessages); XCTAssertFalse(h.host.isEmpty)
        defaults.set(true, forKey: "companion.allowMessages")
        let again = try await expect(200, CompanionAPI.Path.hello)
        XCTAssertTrue(try again.json(CompanionAPI.Hello.self).allowsMessages, "the switch is read per request")
    }

    func testRotateDropsEveryPairedPhone() async throws {
        try await start()
        let old = server.token
        try await expect(200, CompanionAPI.Path.hello, as: .token(old))
        server.rotate()
        XCTAssertNotEqual(server.token, old); XCTAssertEqual(server.token.count, 64)
        try await expect(401, CompanionAPI.Path.hello, as: .token(old), "the old token is refused at once")
        try await expect(200, CompanionAPI.Path.hello, as: .token(server.token))
    }

    // MARK: routing

    func testUnknownPathAndWrongMethod() async throws {
        try await start()
        let nope = try await expect(404, "/v1/nothing")
        XCTAssertTrue(nope.problem?.fix?.contains("/v1/hello") == true)
        try await expect(404, "/v1/work/", "no trailing slash")
        let post = try await expect(405, CompanionAPI.Path.work, method: "POST", body: Data("{}".utf8))
        XCTAssertEqual(post.headers["Allow"] as? String, "GET")
        let getHey = try await expect(405, CompanionAPI.Path.hey)
        XCTAssertEqual(getHey.headers["Allow"] as? String, "POST")
        try await expect(405, CompanionAPI.Path.hello, method: "DELETE")
        try await expect(405, CompanionAPI.Path.hello, method: "PUT", body: Data("{}".utf8))
    }

    func testReadEndpointsAnswerWithTheirPayloads() async throws {
        try await start()
        let work = try await expect(200, CompanionAPI.Path.work)
        XCTAssertNil(try work.json(CompanionAPI.Work.self).refreshed, "nothing read yet")
        let inbox = try await expect(200, CompanionAPI.Path.inbox)
        XCTAssertEqual(try inbox.json(CompanionAPI.Inbox.self).items.count, 0)
        let gh = try await expect(200, CompanionAPI.Path.github)
        XCTAssertEqual(try gh.json(CompanionAPI.GitHub.self).prs.count, 0)
        let status = try await expect(200, CompanionAPI.Path.status)
        let s = try status.json(CompanionAPI.MemoryStatus.self)
        XCTAssertEqual(s.items, 0); XCTAssertFalse(s.hasMap)
        let map = try await expect(404, CompanionAPI.Path.map, "no layout yet")
        XCTAssertTrue(map.problem?.fix?.contains("Rebuild map layout") == true)
        let trace = try await expect(200, CompanionAPI.Path.trace + "?limit=3")
        XCTAssertLessThanOrEqual(try trace.json(CompanionAPI.Trace.self).entries.count, 3)
    }

    func testSearchChecksItsQuestionBeforeEmbedding() async throws {
        try await start()
        let empty = try await expect(400, CompanionAPI.Path.search + "?q=%20%20")
        XCTAssertNotNil(empty.problem?.fix)
        try await expect(400, CompanionAPI.Path.search)
        let odd = try await expect(400, CompanionAPI.Path.search + "?q=x&kind=everything")
        XCTAssertTrue(odd.problem?.fix?.contains("sessions") == true)
    }

    // MARK: the inbox

    func testInboxFile() async throws {
        try await start()
        let ok = try await expect(200, CompanionAPI.Path.inboxFile + "?path=handoff/note.md")
        let f = try ok.json(CompanionAPI.InboxFile.self)
        XCTAssertEqual(f.path, "handoff/note.md"); XCTAssertEqual(f.text, "hello ψ — สวัสดี\n"); XCTAssertLessThan(abs(f.modified.timeIntervalSinceNow), 120)
        try await expect(200, CompanionAPI.Path.inboxFile + "?path=handoff%2Fnote.md", "an encoded slash is the same path")
    }

    func testInboxFileStaysInsideTheInbox() async throws {
        try await start()
        for bad in ["../../etc/passwd", "..%2F..%2Fetc%2Fpasswd", "%2e%2e/%2e%2e/etc/passwd", "/etc/passwd", "%2Fetc%2Fpasswd", ".hidden/x.md",
                    "handoff/../../outside/secret.txt", "."] {
            let a = try await expect(403, CompanionAPI.Path.inboxFile + "?path=" + bad)
            XCTAssertNotNil(a.problem?.fix, bad)
            XCTAssertFalse(a.text.contains("root:"), bad)
        }
        let out = try await expect(404, CompanionAPI.Path.inboxFile + "?path=linkdir/secret.txt", "a link out reads as missing")
        XCTAssertFalse(out.text.contains("secret.txt\"") && out.text.contains("secret\\n"))
        try await expect(404, CompanionAPI.Path.inboxFile + "?path=handoff/nope.md")
        try await expect(413, CompanionAPI.Path.inboxFile + "?path=big.txt")
        try await expect(415, CompanionAPI.Path.inboxFile + "?path=bin.dat")
        try await expect(415, CompanionAPI.Path.inboxFile + "?path=handoff", "a folder is not a file")
        try await expect(400, CompanionAPI.Path.inboxFile)
        try await expect(400, CompanionAPI.Path.inboxFile + "?path=")
    }

    // MARK: the panes and the one write

    func testAPaneThatIsNotListedIsNotRead() async throws {
        try await start()
        try await expect(400, CompanionAPI.Path.screen)
        let a = try await expect(404, CompanionAPI.Path.screen + "?place=laris-co:w22:p1")
        XCTAssertTrue(a.problem?.fix?.contains("maw herdr ls --agents") == true)
        for place in ["-x:w1:p1", "laris-co", "laris-co:--help", "../../x"] { try await expect(404, CompanionAPI.Path.screen + "?place=" + place, place) }
    }

    /// A store that has not finished its first refresh has empty lists that mean "not read", not "none": the phone is
    /// told to wait, and keeps the pages it has.
    func testAStoreThatHasNotReadYetSaysSo() async throws {
        CompanionServer.servesUnrefreshed = false
        try await start()
        for path in [CompanionAPI.Path.work, CompanionAPI.Path.inbox, CompanionAPI.Path.github] {
            let a = try await expect(503, path)
            XCTAssertTrue(a.problem?.error.contains("still reading") == true, a.problem?.error ?? "")
            XCTAssertEqual(a.problem?.fix, "try again in a few seconds")
        }
        try await expect(200, CompanionAPI.Path.hello, "hello does not wait: pairing works at once")
    }

    /// A -companionToken can be one character, and loopback is every local process: with one, nothing is typed into a pane.
    func testAShortTestTokenNeverTypesIntoPanes() async throws {
        try await start(["-companionToken", "00ff"])
        defaults.set(true, forKey: "companion.allowMessages")
        let body = Data(#"{"place":"laris-co:w22:p1","text":"hello"}"#.utf8)
        let a = try await expect(403, CompanionAPI.Path.hey, as: .token("00ff"), method: "POST", body: body)
        XCTAssertTrue(a.problem?.fix?.contains("openssl rand -hex 32") == true, a.problem?.fix ?? "")
    }

    /// A burst of refused tokens shuts the peer out for a while, and only its first few calls are listed.
    func testABurstOfRefusedTokensIsShutOut() async throws {
        try await start()
        for _ in 0..<CompanionServer.maxRefusals { try await expect(401, CompanionAPI.Path.hello, as: .token("wrong")) }
        let after = await raw("GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\n\r\n")
        XCTAssertFalse(after.contains("200"), "shut out, even with the right token, for \(CompanionServer.shutOutSeconds) s: \(after.prefix(80))")
        XCTAssertEqual(server.calls.filter { $0.status == 401 }.count, 3, "the rest of the burst is counted, not listed")
    }

    func testTheDeviceNamesTheCaller() {
        XCTAssertEqual(CompanionServer.device(["x-companion-device": "iPad"]), "iPad")
        XCTAssertEqual(CompanionServer.device([:]), "phone")
        XCTAssertEqual(CompanionServer.device(["x-companion-device": "\u{1B}[31mevil\n· mcp"]), "31mevil mcp")   // no escape, no newline, no "·"
        XCTAssertEqual(CompanionServer.device(["x-companion-device": String(repeating: "a", count: 99)]).count, 24)
    }

    func testMessagesNeedTheirSwitch() async throws {
        try await start()
        let body = Data(#"{"place":"laris-co:w22:p1","text":"hello"}"#.utf8)
        let off = try await expect(403, CompanionAPI.Path.hey, method: "POST", body: body)
        XCTAssertTrue(off.problem?.fix?.contains("Allow messages in Settings → Companion") == true, off.problem?.fix ?? "")

        defaults.set(true, forKey: "companion.allowMessages")
        try await expect(404, CompanionAPI.Path.hey, method: "POST", body: body, "on, but the pane is not one the Work page lists: nothing is sent")
        try await expect(400, CompanionAPI.Path.hey, method: "POST", body: Data("not json".utf8))
        try await expect(400, CompanionAPI.Path.hey, method: "POST", body: Data(#"{"place":"a:b","text":"  \n "}"#.utf8))
        let long = try JSONEncoder().encode(CompanionAPI.Hey(place: "a:b", text: String(repeating: "x", count: CompanionServer.maxMessage + 1)))
        try await expect(413, CompanionAPI.Path.hey, method: "POST", body: long)

        defaults.set(false, forKey: "companion.allowMessages")
        try await expect(403, CompanionAPI.Path.hey, method: "POST", body: body, "off again, at once")
    }

    // MARK: hostile bytes

    func testMalformedRequestsAreAnsweredAndNothingCrashes() async throws {
        try await start()
        await expectRaw("400", "POST /v1/hey HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "a negative length would trap MCPServer.parse")
        await expectRaw("400", "POST /v1/hey HTTP/1.1\r\nContent-Length: nope\r\n\r\n")
        await expectRaw("413", "POST /v1/hey HTTP/1.1\r\nContent-Length: 9999999\r\n\r\n")
        await expectRaw("400", "GET\r\n\r\n")
        await expectRaw("431", "GET /" + String(repeating: "a", count: 20_000) + "\r\n\r\n")
        await expectRaw("431", "GET /v1/hello HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: CompanionServer.maxHeader) + "\r\n\r\n", "a block of headers just over the room")
        await expectRaw("401", "GET http://evil/v1/hello HTTP/1.1\r\n\r\n", "no token: refused before anything else")
        await expectRaw("200", "GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\n\r\n", "and the server is still there")
        await expectRaw("400", "GET v1/hello HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\n\r\n", "a target that is not a path")
        try await expect(200, CompanionAPI.Path.hello)
    }

    // MARK: slow callers

    /// A caller on a slow link sends a few bytes at a time: nothing is answered before the request is whole, and then once.
    func testARequestThatArrivesInPiecesIsAnsweredOnce() async throws {
        try await start()
        // the headers, a byte at a time: every cut, inside each CRLF and inside the blank line too
        let hello = cut("GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\n\r\n", by: 1)
        let a = await raw(hello[0], then: Array(hello.dropFirst()), pause: 500)
        XCTAssertEqual(httpCode(a), "200", "headers in pieces: \(a.prefix(100))")
        // the body, 7 bytes at a time after the headers: read when it is whole — a short one would be a 400
        defaults.set(true, forKey: "companion.allowMessages")
        let body = #"{"place":"laris-co:w22:p1","text":"a message that was cut into pieces on its way"}"#
        let head = "POST /v1/hey HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let b = await raw(head, then: cut(body, by: 7), pause: 4_000)
        XCTAssertEqual(httpCode(b), "404", "the whole body arrived; its place is not one the Work page lists: \(b.prefix(200))")
        XCTAssertTrue(b.contains("laris-co:w22:p1 is not a pane the Work page lists"), b)
        // and the same request in one piece
        let c = await raw(head + body)
        XCTAssertEqual(httpCode(c), "404", c)
    }

    /// A caller that hangs up in the middle of its body is let go at once — its slot is not held until the idle timer.
    func testAHangUpInTheMiddleOfTheBodyIsLetGo() async throws {
        try await start()
        var t = Date()
        let answer = await raw("POST /v1/hey HTTP/1.1\r\nContent-Length: 100\r\n\r\nten bytes!", halfClose: true)
        XCTAssertEqual(answer, "", "half a request is not answered")
        XCTAssertLessThan(Date().timeIntervalSince(t), 3, "closed by the server when the caller finished sending, not by the 5 s read timeout")
        t = Date()
        let early = await raw("GET /v1/hello HTTP/1.1\r\nAuthor", halfClose: true)
        XCTAssertEqual(early, "", "half the headers, then the end")
        XCTAssertLessThan(Date().timeIntervalSince(t), 3)
        try await expect(200, CompanionAPI.Path.hello)
    }

    /// The headers are read once per request, not once per received chunk: a caller that sends them and then drips the body a
    /// byte at a time, from a few connections, leaves the main thread idle. Measured on the main thread's own CPU clock: ~95 %
    /// busy when every chunk read the headers again (one such caller was enough), ~0 % now.
    func testADrippedBodyDoesNotKeepTheMainThreadBusy() async throws {
        try await start()
        var head = "POST /v1/hey HTTP/1.1\r\nContent-Length: \(CompanionServer.maxBody)\r\n"
        while head.utf8.count < CompanionServer.maxHeader - 100 { head += "a:b\r\n" }   // short lines: the most work per read
        head += "\r\n"
        let port = self.port, seconds = 1.5, headers = head
        let cpu0 = await MainActor.run { Self.threadCPU() }, began = Date()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<3 { g.addTask { Self.drip(port: port, head: headers, seconds: seconds) } }
        }
        let busy = (await MainActor.run { Self.threadCPU() } - cpu0) / Date().timeIntervalSince(began)
        XCTAssertLessThan(busy, 0.3, "the main thread was \(Int(busy * 100)) % busy with callers that send one byte at a time")
        try await expect(200, CompanionAPI.Path.hello)
    }

    func testCallsAreLogged() async throws {
        try await start()
        try await expect(401, "/v1/work", as: .nobody)
        try await expect(200, "/v1/work")
        try await expect(403, "/v1/inbox/file?path=../x")
        let last = Array(server.calls.suffix(3))
        XCTAssertEqual(last.map(\.status), [401, 200, 403]); XCTAssertEqual(last.map(\.method), ["GET", "GET", "GET"])
        XCTAssertEqual(last[2].target, "/v1/inbox/file?path=../x"); XCTAssertEqual(last[0].remote, "127.0.0.1")
        XCTAssertTrue(last.allSatisfy { $0.ms >= 0 })
        XCTAssertTrue(HubLog.shared.lines.contains { $0.text.contains("Companion GET /v1/work → 401") })
        for _ in 0..<105 { try await expect(200, "/v1/hello") }   // answered calls: a burst of refused ones is shut out (testABurstOfRefusedTokensIsShutOut)
        XCTAssertEqual(server.calls.count, 100, "the last 100")
    }

    // MARK: where it listens

    /// What the process has listening on `port`, as lsof names it: "127.0.0.1:41234", "100.92.18.7:41234", "*:41234".
    private func listening(on port: UInt16) async -> [String]? {
        let pid = ProcessInfo.processInfo.processIdentifier
        return await Task.detached { () -> [String]? in
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
            p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        }.value
    }

    func testListensOnLoopbackAndTheMeshAndNowhereElse() async throws {
        try await start()
        let mesh = CompanionServer.meshAddresses()
        let want = Set(["127.0.0.1"] + mesh)
        for _ in 0..<100 where Set(server.addresses) != want { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(Set(server.addresses), want, "loopback and every 100.64.0.0/10 address, nothing else")
        XCTAssertEqual(server.pairLinks.last?.host, "127.0.0.1"); XCTAssertEqual(server.pairLinks.last?.simulatorOnly, true)
        XCTAssertTrue(server.pairLinks.dropLast().allSatisfy { !$0.simulatorOnly })
        for link in server.pairLinks {
            let p = try XCTUnwrap(CompanionAPI.Pairing.parse(link.url))
            XCTAssertEqual(p.port, port); XCTAssertEqual(p.token, server.token); XCTAssertEqual(p.name, "Test"); XCTAssertEqual(link.url.scheme, "oracle-test")
        }
        // the sockets themselves, from the kernel: one per allowed address and no wildcard. (A Mac cannot connect to its own
        // utun address — the route sends it out the tunnel — so a connect would prove nothing here; the phone arrives from outside.)
        let found = await listening(on: port)
        let bound = try XCTUnwrap(found, "lsof is not available here")
        XCTAssertEqual(Set(bound), Set(want.map { "\($0):\(port)" }), "bound: \(bound)")
        XCTAssertFalse(bound.contains { $0.hasPrefix("*") || $0.hasPrefix("0.0.0.0") || $0.hasPrefix("[::") }, "never a wildcard: \(bound)")
        // every other address of this Mac refuses: nothing listens there
        for ip in Self.upAddresses() where !want.contains(ip) {
            let answer = await raw("GET /v1/hello HTTP/1.1\r\n\r\n", host: ip)
            XCTAssertTrue(answer.hasPrefix("connect failed"), "\(ip) must refuse, got: \(answer.prefix(60))")
        }
    }

    /// The defense in depth: a caller that is neither loopback nor mesh gets the connection closed unread. The socket is bound
    /// to this Mac's LAN address, so the server sees that address as the remote, and aims at the 127.0.0.1 listener.
    func testAConnectionFromElsewhereIsClosedUnread() async throws {
        try await start()
        let lan = try XCTUnwrap(Self.upAddresses().first { $0 != "127.0.0.1" && !CompanionServer.meshAddresses().contains($0) }, "no LAN address on this Mac")
        let answer = await raw("GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\n\r\n", host: "127.0.0.1", from: lan)
        try XCTSkipIf(answer.hasPrefix("bind failed") || answer.hasPrefix("connect failed"), "this Mac will not send \(lan) → 127.0.0.1: \(answer)")
        XCTAssertEqual(answer, "", "closed without a word — even with the right token")
        XCTAssertTrue(HubLog.shared.lines.contains { $0.text.contains("closed a connection from \(lan)") }, "and it says so in the log")
        // while the same request from loopback itself is answered
        let fine = await raw("GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer \(server.token)\r\n\r\n")
        XCTAssertEqual(httpCode(fine), "200")
    }

    /// A caller that never finishes its request (or never starts one) is hung up on; the server stays answerable.
    func testASlowCallerIsHungUpOn() async throws {
        let (idle, life) = (CompanionServer.idleSeconds, CompanionServer.lifetimeSeconds)
        CompanionServer.idleSeconds = 1; CompanionServer.lifetimeSeconds = 30
        defer { CompanionServer.idleSeconds = idle; CompanionServer.lifetimeSeconds = life }
        try await start()
        let t = Date()
        async let silent = raw("")                                       // connects, says nothing
        async let partial = raw("GET /v1/hello HTTP/1.1\r\nAuthor")      // starts a request, never ends it
        let (a, b) = await (silent, partial)
        XCTAssertEqual(a, ""); XCTAssertEqual(b, "")
        XCTAssertLessThan(Date().timeIntervalSince(t), 4, "closed by the server after about a second, not by the client's 5 s timeout")
        try await expect(200, CompanionAPI.Path.hello)
    }

    func testATestTokenListensOnLoopbackOnly() async throws {
        try await start(["-companionToken", "00ff"])
        XCTAssertEqual(server.token, "00ff"); XCTAssertEqual(server.addresses, ["127.0.0.1"])
        XCTAssertNotNil(server.problem, "it says why the mesh is not offered")
        try await expect(200, CompanionAPI.Path.hello, as: .token("00ff"))
        try await expect(401, CompanionAPI.Path.hello, as: .token("00fe"))
        for m in CompanionServer.meshAddresses() {
            let answer = await raw("GET /v1/hello HTTP/1.1\r\nAuthorization: Bearer 00ff\r\n\r\n", host: m)
            XCTAssertTrue(answer.hasPrefix("connect failed"), "a test token is not offered on \(m)")
        }
        server.rotate()
        XCTAssertNotEqual(server.token, "00ff"); XCTAssertEqual(server.token.count, 64)
    }

    func testOffUntilSwitchedOnAndOffAgain() async throws {
        let s = CompanionServer(keychain: false, defaults: defaults)
        server = s
        s.configure(name: "Test", mcpPort: 4791, index: { [index] in index! }, args: [])
        XCTAssertTrue(s.configured); XCTAssertFalse(s.enabled); XCTAssertFalse(s.running, "off until switched on")
        XCTAssertEqual(s.statusText, "off"); XCTAssertTrue(s.pairLinks.isEmpty)
        XCTAssertEqual(s.port, 4801, "its MCP port + 10")
        port = UInt16.random(in: 30_000...60_000)
        s.configure(name: "Test", mcpPort: 4791, index: { [index] in index! }, args: ["-companionPort", "\(port)"])
        s.attach(store: store)
        s.setEnabled(true)
        for _ in 0..<100 where !s.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(s.running); XCTAssertTrue(defaults.bool(forKey: "companion.enabled"), "the switch is remembered")
        try await expect(200, CompanionAPI.Path.hello)
        s.setEnabled(false)
        XCTAssertFalse(s.running); XCTAssertEqual(s.statusText, "off"); XCTAssertFalse(defaults.bool(forKey: "companion.enabled"))
        try await Task.sleep(for: .milliseconds(300))
        let answer = await raw("GET /v1/hello HTTP/1.1\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("connect failed"), "nothing listens once it is off: \(answer.prefix(60))")
    }

    func testAPortThatIsTakenSaysWhatHoldsIt() async throws {
        // something else holds 127.0.0.1:<port> first
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var held: UInt16 = 0
        for _ in 0..<20 {
            held = UInt16.random(in: 30_000...60_000); addr.sin_port = held.bigEndian
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if bound == 0 { break }
        }
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        let s = CompanionServer(keychain: false, defaults: defaults)
        server = s; port = held
        s.attach(store: store)
        s.configure(name: "Test", mcpPort: 4791, index: { [index] in index! }, args: ["-companion", "on", "-companionPort", "\(held)", "-companionToken", "00ff"])
        for _ in 0..<100 where !(s.problem ?? "").contains("lsof") { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(s.running)
        XCTAssertTrue(s.problem?.contains("lsof -nP -iTCP:\(held) -sTCP:LISTEN") == true, s.problem ?? "no problem reported")
        XCTAssertEqual(s.statusText, "not listening")
    }

    /// Every IPv4 address of an up interface.
    private static func upAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil { out.append(String(cString: buf)) }
        }
        return out
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
