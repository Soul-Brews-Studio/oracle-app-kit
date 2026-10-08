#if os(macOS)
import XCTest
@testable import OracleKit

// MARK: - the server itself, over loopback

/// A real CompanionServer on a free port, with a temporary checkout for its inbox, asked through URLSession and raw sockets.
@MainActor
final class CompanionMacServerTests: XCTestCase {
    var server: CompanionServer!
    var store: OracleStore!
    var index: GHIndex!
    var defaults: UserDefaults!
    private var suite = ""
    private var tmp: URL!
    var port: UInt16 = 0
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
    func start(_ extra: [String] = []) async throws {
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

    struct Answer {
        let status: Int, data: Data, headers: [AnyHashable: Any]
        func json<T: Decodable>(_ t: T.Type) throws -> T { try CompanionAPI.decoder.decode(T.self, from: data) }
        var problem: CompanionAPI.Problem? { try? CompanionAPI.decoder.decode(CompanionAPI.Problem.self, from: data) }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    enum Who { case server, nobody, token(String) }

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
    func expect(_ status: Int, _ path: String, as who: Who = .server, method: String = "GET", body: Data? = nil, host: String = "127.0.0.1",
                        _ why: String = "", file: StaticString = #filePath, line: UInt = #line) async throws -> Answer {
        let token: String? = switch who { case .server: server.token; case .nobody: nil; case .token(let t): t }
        let a = try await call(path, token: token, method: method, body: body, host: host)
        XCTAssertEqual(a.status, status, "\(method) \(path) \(why)", file: file, line: line)
        return a
    }

    /// Raw bytes to the port; everything that comes back until the server closes. Off the main actor: the server runs on it.
    /// `then`: more bytes, each piece `pause` µs after the one before (a slow link). `halfClose`: say "that is all" after the last one.
    func raw(_ bytes: String, host: String = "127.0.0.1", from: String? = nil, port override: UInt16? = nil,
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

    func httpCode(_ raw: String) -> String { String(raw.split(separator: " ", maxSplits: 2).dropFirst().first ?? "none") }

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
}
#endif
