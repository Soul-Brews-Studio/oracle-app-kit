#if os(macOS)
import XCTest
import Network
import Security
@testable import OracleKit

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

extension CompanionMacServerTests {
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
#endif
