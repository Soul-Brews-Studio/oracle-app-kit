#if os(macOS)
import Foundation
import Network
import Security
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Mac side of the companion API (issue #46): this app answers CompanionAPI for the same oracle's app on an iPhone or
/// iPad, from OracleStore (work, inbox, PRs, issues), GHIndex (search, status), MapLayout + MapClusters (the Map) and TraceLog.
///
/// Where it listens: one NWListener per allowed IPv4 address — 127.0.0.1 always (the iOS Simulator), plus every local
/// address in 100.64.0.0/10 (the NetBird mesh, a real phone). Never 0.0.0.0. Defense in depth: a connection whose remote
/// address is neither loopback nor inside 100.64.0.0/10 is closed before a byte is read. The interfaces are watched, so a
/// NetBird that connects after launch gets its listener then.
///
/// Who may ask: every request carries `Authorization: Bearer <token>` — 32 random bytes, hex, in the Keychain, compared in
/// constant time, checked before the path is even looked at. The one write, POST /v1/hey, needs a second switch
/// ("companion.allowMessages") that is off until Settings → Companion turns it on.
///
/// Off until switched on: UserDefaults "companion.enabled" (Settings → Companion) or the launch argument `-companion on`.
/// Tests: `-companionPort <n>` moves the port; `-companionToken <hex>` sets a test token — and a test token listens on
/// 127.0.0.1 only, so a short token is never offered to the mesh.
@MainActor
public final class CompanionServer: ObservableObject {
    public static let shared = CompanionServer()

    public struct Call: Identifiable, Sendable {
        public let id = UUID()
        public let at: Date
        public let method: String
        public let target: String      // path and query, as asked
        public let status: Int
        public let ms: Double
        public let remote: String      // the caller's address, no port
    }

    /// One way to reach this Mac: the pairing link the phone opens, and whether only the simulator can use it.
    public struct PairLink: Identifiable, Equatable, Sendable {
        public var id: String { host }
        public let host: String
        public let url: URL
        public let simulatorOnly: Bool
    }

    /// `serve` has run: this app has a companion server (the Hub has none, so its Settings shows no card).
    @Published public private(set) var configured = false
    /// The switch: on, the server listens.
    @Published public private(set) var enabled = false
    /// At least one address is listening.
    @Published public private(set) var running = false
    /// The addresses that are listening, the NetBird ones first.
    @Published public private(set) var addresses: [String] = []
    @Published public private(set) var port: UInt16 = 0
    @Published public private(set) var name = ""
    /// The bearer token (in memory while the server is on; the Keychain keeps it between launches).
    @Published public private(set) var token = ""
    /// The last 100 calls, oldest first.
    @Published public private(set) var calls: [Call] = []
    @Published private var problems: [String: String] = [:]    // address (or "token") → why it is not working
    @Published private var tokenNote: String?

    /// Why it is not listening, or what to know about the token — with the command that helps.
    public var problem: String? {
        let all = problems.sorted { $0.key < $1.key }.map(\.value) + [tokenNote].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: "\n")
    }

    nonisolated static let enabledKey = "companion.enabled"
    nonisolated static let messagesKey = "companion.allowMessages"
    nonisolated static let keychainService = "co.laris.oracle.companion.server"
    nonisolated static let maxConnections = 32
    nonisolated static let maxPerPeer = 12
    nonisolated static let maxHeader = 4 << 10       // an iOS URLSession request is well under 1 KB; this is the room for a long search
    nonisolated static let maxBody = 64 << 10
    nonisolated static let maxMessage = 8_000        // characters of one message to an agent
    nonisolated static let maxFile = 512 * 1024      // bytes of one inbox file
    /// A connection that has not sent a whole request in this long is closed; one that is still open after `lifetime` is too.
    nonisolated(unsafe) static var idleSeconds: TimeInterval = 15
    /// A peer whose token is refused this many times within `refusalWindow` is turned away at connect for `shutOutSeconds`:
    /// a token is 256 bits, so guessing gets nowhere, but a flood of refused requests would still keep the main thread busy
    /// and fill the log. The verify scripts' "is it up yet" probes (one a second) stay far below it.
    nonisolated static let maxRefusals = 20
    nonisolated static let refusalWindow: TimeInterval = 10
    nonisolated static let shutOutSeconds: TimeInterval = 30
    /// Tests only: answer a store that has never refreshed (theirs never does) instead of "still reading".
    nonisolated(unsafe) static var servesUnrefreshed = false
    nonisolated(unsafe) static var lifetimeSeconds: TimeInterval = 180

    private var launch: (name: String, mcpPort: UInt16, index: () -> GHIndex)?
    private weak var store: OracleStore?
    private var listeners: [String: NWListener] = [:]
    private var ready: Set<String> = []
    private var monitor: NWPathMonitor?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var retries: [String: Int] = [:]    // address → tries since its listener last failed
    private var tokenOverride: String?
    private let useKeychain: Bool
    private let defaults: UserDefaults

    init(keychain: Bool = true, defaults: UserDefaults = .standard) {
        useKeychain = keychain; self.defaults = defaults
    }

    // MARK: switching it on

    /// Remembers what this app serves and starts the server when Companion is on (Settings → Companion, or `-companion on`).
    public static func serve(name: String, mcpPort: UInt16, index: @escaping () -> GHIndex) {
        shared.configure(name: name, mcpPort: mcpPort, index: index)
    }

    func configure(name: String, mcpPort: UInt16, index: @escaping () -> GHIndex, args: [String] = CommandLine.arguments) {
        guard mcpPort > 0, mcpPort <= 65_525 else { return }
        launch = (name, mcpPort, index)
        self.name = name
        tokenOverride = nil
        port = Self.option("companionPort", in: args).flatMap { UInt16($0) }.flatMap { $0 > 0 ? $0 : nil } ?? CompanionAPI.port(mcp: mcpPort)
        if let t = Self.option("companionToken", in: args) {
            if Self.validToken(t) { tokenOverride = t }
            else { HubLog.shared.add(.error, "Companion: -companionToken ignored — a token is 1 to 128 printable characters without spaces, e.g.  -companionToken 00ff") }
        }
        configured = true
        enabled = defaults.bool(forKey: Self.enabledKey) || ["on", "yes", "true", "1"].contains(Self.option("companion", in: args)?.lowercased() ?? "")
        if enabled { start() }
    }

    /// The Settings switch: remembered, and the listeners follow it.
    public func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        enabled = on
        if on { start() } else { stop() }
    }

    /// The oracle's store, for work, inbox, PRs, issues and messages — the root view hands it over once it shows.
    public func attach(store: OracleStore) { self.store = store }

    /// Makes a new token: every paired phone is refused from the next request on and must pair again.
    public func rotate() {
        guard let t = Self.makeToken() else { return }
        if tokenOverride != nil { tokenOverride = t }
        else if useKeychain, Self.keychainWrite(t, account: name) != errSecSuccess {
            // the old token stays, here and in the Keychain: a new one only in memory would be back to the old at the next launch
            tokenNote = "the new token could not be saved in the Keychain, so the old one stays (nothing changed); fix, then Rotate again:  security unlock-keychain ~/Library/Keychains/login.keychain-db"
            HubLog.shared.add(.error, "Companion: " + (tokenNote ?? ""))
            return
        }
        if tokenOverride == nil { tokenNote = nil }          // an earlier failure's note no longer says what happened
        if enabled { token = t }
        HubLog.shared.add(.info, "Companion: token rotated — every paired phone must pair again")
    }

    func start() {
        stopListeners()
        guard launch != nil, enabled else { return }
        guard loadToken() else { return }
        reconcile()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } }
        m.start(queue: .main)
        monitor = m
    }

    public func stop() {
        enabled = false
        stopListeners()
        HubLog.shared.add(.info, "Companion: off")
    }

    private func stopListeners() {
        monitor?.cancel(); monitor = nil
        for l in listeners.values { l.cancel() }
        listeners = [:]; ready = []
        for c in connections.values { c.cancel() }
        connections = [:]
        problems = [:]; tokenNote = nil; token = ""
        retries = [:]
        publish()
    }

    private func loadToken() -> Bool {
        tokenNote = nil
        if let t = tokenOverride {
            token = t
            tokenNote = "a test token from -companionToken: this server listens on 127.0.0.1 only"
            return true
        }
        if useKeychain, let t = Self.keychainRead(account: name), t.count >= 32 { token = t; return true }
        guard let t = Self.makeToken() else {
            problems["token"] = "Companion could not make a token (SecRandomCopyBytes failed) — switch Companion off and on again"
            return false
        }
        token = t
        if useKeychain {
            let status = Self.keychainWrite(t, account: name)
            if status != errSecSuccess {
                tokenNote = "could not keep the token in the Keychain (OSStatus \(status)) — phones must pair again after every launch; fix:  security unlock-keychain ~/Library/Keychains/login.keychain-db"
                HubLog.shared.add(.error, "Companion: \(tokenNote ?? "")")
            }
        }
        return true
    }

    // MARK: listeners

    /// Brings the listeners in line with the addresses this Mac has now: 127.0.0.1, and the NetBird mesh address(es).
    private func reconcile() {
        guard enabled, launch != nil, !token.isEmpty else { return }
        let want = Set(Self.wantedAddresses(loopbackOnly: tokenOverride != nil))
        for (addr, l) in listeners where !want.contains(addr) {
            l.cancel(); listeners[addr] = nil; ready.remove(addr); problems[addr] = nil
            HubLog.shared.add(.info, "Companion: \(addr) is gone — stopped listening on it")
        }
        for addr in problems.keys where addr != "token" && !want.contains(addr) { problems[addr] = nil }   // a failed address that left
        for addr in want.sorted() where listeners[addr] == nil { listen(on: addr) }
        publish()
    }

    private func listen(on addr: String) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let why = { (e: Any) in "Companion could not listen on \(addr):\(p.rawValue) (\(e)) — see what holds it:  lsof -nP -iTCP:\(p.rawValue) -sTCP:LISTEN" }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(addr), port: p)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated { self?.accept(c) }   // the listener runs on the main queue
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let current = self.listeners[addr] === l   // not a listener that was replaced or stopped meanwhile
                    switch state {
                    case .ready where current:
                        self.ready.insert(addr); self.problems[addr] = nil; self.retries[addr] = nil; self.publish()
                        HubLog.shared.add(.info, "Companion: listening on \(addr):\(p.rawValue)")
                    case .failed(let e) where current:
                        l?.cancel()
                        self.listeners[addr] = nil
                        self.ready.remove(addr); self.problems[addr] = why(e); self.publish()
                        HubLog.shared.add(.error, why(e))
                        // a port the last listener has not let go of yet is free in a moment: try again, three times
                        if self.enabled, self.retries[addr, default: 0] < 3 {
                            self.retries[addr, default: 0] += 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.reconcile() } }
                        }
                    case .cancelled where current || self.listeners[addr] == nil:
                        self.ready.remove(addr); self.publish()
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listeners[addr] = l
        } catch {
            problems[addr] = why(error)
            HubLog.shared.add(.error, why(error))
        }
    }

    private func publish() {
        let sorted = ready.sorted { (Self.isLoopback($0) ? 1 : 0, $0) < (Self.isLoopback($1) ? 1 : 0, $1) }
        if addresses != sorted { addresses = sorted }
        if running != !ready.isEmpty { running = !ready.isEmpty }
    }

    /// The pairing links of the addresses that are listening: the NetBird ones first, 127.0.0.1 last (simulator only).
    public var pairLinks: [PairLink] {
        guard running, !token.isEmpty else { return [] }
        return addresses.compactMap { host in
            CompanionAPI.Pairing(host: host, port: port, token: token, name: name)
                .link(scheme: "oracle-" + name.lowercased())
                .map { PairLink(host: host, url: $0, simulatorOnly: Self.isLoopback(host)) }
        }
    }

    /// One line for Settings: what is listening, or why nothing is.
    public var statusText: String {
        if !enabled { return "off" }
        if running { return "listening on " + addresses.map { "\($0):\(port)" }.joined(separator: " · ") }
        return problems.isEmpty ? "starting…" : "not listening"
    }

    // MARK: who may connect

    /// 127.0.0.1 always; the NetBird mesh address(es) too, unless a test token is set.
    nonisolated static func wantedAddresses(loopbackOnly: Bool) -> [String] {
        ["127.0.0.1"] + (loopbackOnly ? [] : meshAddresses())
    }

    nonisolated static func isLoopback(_ host: String) -> Bool { host.hasPrefix("127.") }
    /// 100.64.0.0/10 — the carrier-grade NAT range NetBird (and Tailscale) hand out.
    nonisolated static func isMesh(_ ip: UInt32) -> Bool { ip & 0xFFC0_0000 == 0x6440_0000 }
    nonisolated static func isLoopback(_ ip: UInt32) -> Bool { ip >> 24 == 127 }

    /// A remote address that may talk to us: loopback or the mesh (an IPv4-mapped IPv6 address counts as its IPv4).
    nonisolated static func allowed(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let ip = b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return isLoopback(ip) || isMesh(ip)
    }

    nonisolated static func remoteAllowed(_ e: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return allowed(ipv4: Array(a.rawValue))
        case .ipv6(let a):
            if a.isLoopback { return true }
            if let v4 = a.asIPv4 { return allowed(ipv4: Array(v4.rawValue)) }
            return false
        default: return false   // a host name, or anything newer: never
        }
    }

    /// The peer is this Mac (127.0.0.0/8 or ::1).
    nonisolated static func isLoopbackEndpoint(_ e: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.rawValue.first == 127
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.rawValue.first == 127)
        default: return false
        }
    }

    nonisolated static func describe(_ e: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = e else { return "?" }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return "?"
        }
    }

    /// A path in single quotes for a copy-pasted command (a quote inside becomes '\'').
    nonisolated static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Every up point-to-point interface's IPv4 address inside 100.64.0.0/10, e.g. "100.92.18.7": a mesh VPN's tunnel
    /// (NetBird; Tailscale uses the same range). A Wi-Fi or Ethernet address in that range — some ISPs and hotels hand out
    /// carrier-grade NAT addresses — is not a mesh, and is not listened on.
    nonisolated static func meshAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: Set<String> = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_UP) != 0,
                  i.ifa_flags & UInt32(IFF_POINTOPOINT) != 0 else { continue }
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard isMesh(UInt32(bigEndian: a.s_addr)) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil { found.insert(String(cString: buf)) }
        }
        return found.sorted()
    }

    // MARK: token

    nonisolated static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func validToken(_ t: String) -> Bool {
        (1...128).contains(t.count) && t.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    /// Equal in time that depends on the length of the longer one, never on where they first differ.
    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0) }
        return diff == 0
    }

    nonisolated static func keychainRead(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    nonisolated static func keychainWrite(_ token: String, account: String) -> OSStatus {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: account]
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = match; add[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(add as CFDictionary, nil)
    }

    nonisolated static func keychainDelete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    /// `-name value` from the launch arguments.
    nonisolated static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: "-" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: one connection

    private struct Refusals { var since: Date; var count = 0; var shutOutUntil: Date? }
    private var refusals: [String: Refusals] = [:]

    private final class Conn: @unchecked Sendable {   // touched on the main queue only
        let c: NWConnection
        var buffer = Data()
        var need: Int?                    // bytes the whole request needs (headers + body), known once its headers are read
        var idle: DispatchWorkItem?       // no complete request yet
        var lifetime: DispatchWorkItem?   // however slow the answer or the reader
        init(_ c: NWConnection) { self.c = c }
    }

    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private func accept(_ c: NWConnection) {
        let peer = Self.describe(c.endpoint)
        if let until = refusals[peer]?.shutOutUntil, until > Date() { c.cancel(); return }   // logged once, when it began
        guard Self.remoteAllowed(c.endpoint) else {
            HubLog.shared.add(.error, "Companion: closed a connection from \(Self.describe(c.endpoint)) — only loopback and the NetBird mesh (100.64.0.0/10) may connect")
            c.cancel(); return
        }
        guard connections.count < Self.maxConnections else {
            HubLog.shared.add(.error, "Companion: closed a connection — \(Self.maxConnections) are open already")
            c.cancel(); return
        }
        // one mesh peer can't hold every slot with idle sockets. A phone needs about six at a time (a refresh asks work, GitHub
        // and inbox at once while a page loads the map or polls a pane). Loopback is this Mac — and every simulator — so it has
        // no limit of its own
        guard Self.isLoopbackEndpoint(c.endpoint) || connections.values.filter({ Self.describe($0.endpoint) == peer }).count < Self.maxPerPeer else {
            HubLog.shared.add(.error, "Companion: closed a connection from \(peer) — \(Self.maxPerPeer) of its own are open already")
            c.cancel(); return
        }
        let key = ObjectIdentifier(c)
        connections[key] = c
        let k = Conn(c)
        c.stateUpdateHandler = { [weak self, weak k] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed: c.cancel()
                case .cancelled: self?.connections[key] = nil; k?.idle?.cancel(); k?.lifetime?.cancel()
                default: break
                }
            }
        }
        c.start(queue: .main)
        // weak: a cancelled DispatchWorkItem keeps its block until its deadline, and a strong `c` in it would keep every
        // closed connection (and its buffers) alive for up to `lifetimeSeconds`
        k.idle = Self.after(Self.idleSeconds) { [weak c] in c?.cancel() }
        k.lifetime = Self.after(Self.lifetimeSeconds) { [weak c] in c?.cancel() }
        receive(k)
    }

    private static func after(_ seconds: TimeInterval, _ f: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: f)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    private func receive(_ k: Conn) {
        // Headers read, body still coming: ask for exactly the bytes that are missing. A peer that drips its body one byte at
        // a time then wakes nothing per byte, and the headers are not read again until the request is whole.
        let missing = k.need.map { max($0 - k.buffer.count, 1) } ?? 1
        k.c.receive(minimumIncompleteLength: missing, maximumLength: max(missing, 64 << 10)) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { k.buffer.append(data) }
                let over = done || error != nil
                if let need = k.need, k.buffer.count < need {
                    if over { k.c.cancel() } else { self.receive(k) }
                    return
                }
                switch Self.frame(k.buffer) {
                case .request(let r): self.handle(r, k)
                case .bad(let status, let why): self.refuse(k, status, why)
                case .more(let need):
                    k.need = need
                    if over { k.c.cancel() } else { self.receive(k) }
                }
            }
        }
    }

    /// `.more(need:)` — what the headers said, once they are all here: the bytes the whole request needs (nil before that).
    enum Framing { case more(need: Int?), bad(Int, String), request(MCPServer.Request) }

    /// What has arrived, as one request (MCPServer's parser) — after the checks that parser does not make: bounded
    /// headers and body, and a Content-Length that is a number ≥ 0 (a negative one would trap its slice).
    nonisolated static func frame(_ d: Data) -> Framing {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else {
            return d.count > maxHeader ? .bad(431, "the request headers are larger than \(maxHeader / 1024) KB") : .more(need: nil)
        }
        if end.lowerBound > maxHeader { return .bad(431, "the request headers are larger than \(maxHeader / 1024) KB") }
        var length = 0
        for line in String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
            guard let i = line.firstIndex(of: ":"), line[..<i].lowercased() == "content-length" else { continue }
            guard let n = Int(line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)), n >= 0 else {
                return .bad(400, "Content-Length is not a number of bytes")
            }
            length = n
        }
        if length > maxBody { return .bad(413, "the request body is larger than \(maxBody / 1024) KB") }
        let need = end.upperBound + length
        if d.count < need { return .more(need: need) }
        // MCPServer.parse (#50) answers a request it can't read with `bad` set, not nil
        guard let r = MCPServer.parse(d), r.bad == nil else { return .bad(400, "the request line is not  METHOD /path HTTP/1.1") }
        return .request(r)
    }

    private func refuse(_ k: Conn, _ status: Int, _ why: String) {
        k.idle?.cancel()
        let res = fail(status, why, fix: "send a whole request such as  GET /v1/hello  — the phone app does; if it keeps failing, update the Mac app and the phone app to the same version")
        send(res, on: k)
        record(Call(at: Date(), method: "?", target: "(unparsed)", status: status, ms: 0, remote: Self.describe(k.c.endpoint)))
    }

    private func handle(_ r: MCPServer.Request, _ k: Conn) {
        k.idle?.cancel()
        let t0 = Date()
        let remote = Self.describe(k.c.endpoint)
        Task { @MainActor in
            let res = await route(r)
            send(res, on: k)
            if res.status == 401, !refused(by: remote) { return }   // past the first few of a burst: counted, not listed
            record(Call(at: t0, method: Self.clip(Self.printable(r.method), 12), target: Self.clip(Self.printable(r.path), 160), status: res.status,
                        ms: Date().timeIntervalSince(t0) * 1000, remote: remote))
        }
    }

    private func send(_ res: Response, on k: Conn) {
        var head = "HTTP/1.1 \(res.status) \(Self.reason(res.status))\r\nContent-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(res.body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (name, value) in res.headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        k.c.send(content: Data(head.utf8) + res.body, completion: .contentProcessed { [k] _ in
            k.idle?.cancel(); k.lifetime?.cancel(); k.c.cancel()
        })
    }

    /// Counts a refused token from `peer`; true while the burst is still small enough to list each call. Past
    /// `maxRefusals` in `refusalWindow`, the peer is turned away at connect for `shutOutSeconds`, and that is logged once.
    private func refused(by peer: String) -> Bool {
        let now = Date()
        var r = refusals[peer] ?? Refusals(since: now)
        if now.timeIntervalSince(r.since) > Self.refusalWindow { r = Refusals(since: now) }
        r.count += 1
        if r.count == Self.maxRefusals {
            r.shutOutUntil = now.addingTimeInterval(Self.shutOutSeconds)
            HubLog.shared.add(.error, "Companion: \(peer) was refused \(Self.maxRefusals) times in \(Int(Self.refusalWindow)) s — its connections are closed for \(Int(Self.shutOutSeconds)) s. A phone with an old code pairs again: Settings → Companion")
        }
        refusals[peer] = r
        if refusals.count > 256 { refusals = refusals.filter { now.timeIntervalSince($0.value.since) <= Self.refusalWindow || ($0.value.shutOutUntil ?? .distantPast) > now } }
        return r.count <= 3
    }

    private func record(_ c: Call) {
        calls.append(c)
        if calls.count > 100 { calls.removeFirst(calls.count - 100) }
        HubLog.shared.add(c.status < 400 ? .info : .error,
                          String(format: "Companion %@ %@ → %d · %.0f ms · %@", c.method, c.target, c.status, c.ms, c.remote))
    }

    nonisolated static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
    /// The text with every control character shown as "?" — a request line is the caller's, and goes to the log and the card.
    nonisolated static func printable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { $0.properties.generalCategory == .control ? "?" : $0 }))
    }

    nonisolated static func reason(_ status: Int) -> String {
        [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
         413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large",
         500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "Error"
    }

    // MARK: answers

    private func reply<T: Encodable>(_ v: T) -> Response {
        do { return Response(status: 200, body: try CompanionAPI.encoder.encode(v)) }
        catch { return fail(500, "the Mac could not encode its answer (\(error))", fix: "update the Mac app and the phone app to the same version") }
    }

    private func fail(_ status: Int, _ error: String, fix: String? = nil, headers: [String: String] = [:]) -> Response {
        let body = (try? CompanionAPI.encoder.encode(CompanionAPI.Problem(error: error, fix: fix))) ?? Data(#"{"error":"internal error"}"#.utf8)
        return Response(status: status, body: body, headers: headers)
    }

    /// A real place from the Work data for a hint that can be pasted (a stand-in only while no pane is listed).
    private func examplePlace() -> String { store?.activity.first?.place ?? "laris-co:w22:p1" }
    /// A real inbox path for a hint (a stand-in while the inbox is empty).
    private func exampleInboxPath() -> String {
        guard let s = store else { return "handoff/2026-10-05_note.md" }
        return Self.inbox(items: s.inbox, unread: [], root: s.config.inboxPath).items.first?.path ?? "handoff/2026-10-05_note.md"
    }

    /// The attached store once it has read its panes, inbox and GitHub at least once. Before that its lists are empty,
    /// not "nothing there", so the phone is told to wait and keeps the pages it has.
    private func readStore() -> OracleStore? {
        guard let s = store, s.lastRefresh != nil || Self.servesUnrefreshed else { return nil }
        return s
    }

    private func stillReading() -> Response {
        guard store != nil else { return starting() }
        return fail(503, "the \(name) app is still reading its panes, inbox and GitHub (it just started)",
                    fix: "try again in a few seconds")
    }

    private func starting() -> Response {
        fail(503, "the \(name) app is still starting — its window has not attached its store yet",
             fix: "try again in a few seconds; if it stays, open the \(name) window on the Mac")
    }

    static let endpoints = [CompanionAPI.Path.hello, CompanionAPI.Path.work, CompanionAPI.Path.screen, CompanionAPI.Path.inbox,
                            CompanionAPI.Path.inboxFile, CompanionAPI.Path.github, CompanionAPI.Path.search, CompanionAPI.Path.status,
                            CompanionAPI.Path.map, CompanionAPI.Path.trace, CompanionAPI.Path.hey]

    private var allowsMessages: Bool { defaults.bool(forKey: Self.messagesKey) }
    /// The identity: the attached store's, else the one the scene published (once it is this app's).
    private var config: OracleConfig? { store?.config ?? (OracleConfig.current.name == name ? OracleConfig.current : nil) }

    /// The bearer token of a request, compared in constant time.
    private func authorized(_ r: MCPServer.Request) -> Bool {
        guard !token.isEmpty, let h = r.headers["authorization"] else { return false }
        let parts = h.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return Self.constantTimeEquals(String(parts[1]).trimmingCharacters(in: .whitespaces), token)
    }

    private func route(_ r: MCPServer.Request) async -> Response {
        guard authorized(r) else {
            return fail(401, "unauthorized — the Authorization: Bearer token is missing or wrong",
                        fix: "on the Mac: Settings → Companion, then scan its code again", headers: ["WWW-Authenticate": "Bearer"])
        }
        guard let comps = URLComponents(string: r.path, encodingInvalidCharacters: true), comps.path.hasPrefix("/") else {
            return fail(400, "the request target is not a path: \(Self.clip(r.path, 80))", fix: "GET /v1/hello")
        }
        let path = comps.path
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        func only(_ method: String, _ run: () async -> Response) async -> Response {
            r.method == method ? await run()
                : fail(405, "\(r.method) is not allowed on \(path)", fix: "use  \(method) \(path)", headers: ["Allow": method])
        }
        switch path {
        case CompanionAPI.Path.hello: return await only("GET") { helloAnswer() }
        case CompanionAPI.Path.work: return await only("GET") { workAnswer() }
        case CompanionAPI.Path.screen: return await only("GET") { await screenAnswer(q) }
        case CompanionAPI.Path.inbox: return await only("GET") { inboxAnswer() }
        case CompanionAPI.Path.inboxFile: return await only("GET") { await inboxFileAnswer(q) }
        case CompanionAPI.Path.github: return await only("GET") { githubAnswer() }
        case CompanionAPI.Path.search: return await only("GET") { await searchAnswer(q, r) }
        case CompanionAPI.Path.status: return await only("GET") { await statusAnswer() }
        case CompanionAPI.Path.map: return await only("GET") { await mapAnswer() }
        case CompanionAPI.Path.trace: return await only("GET") { await traceAnswer(q) }
        case CompanionAPI.Path.hey: return await only("POST") { await heyAnswer(r) }
        default:
            return fail(404, "no such endpoint: \(Self.clip(path, 80))", fix: "the endpoints are  " + Self.endpoints.joined(separator: "  "))
        }
    }

    // hello

    private func helloAnswer() -> Response {
        guard let c = config else { return starting() }
        return reply(CompanionAPI.Hello(name: c.name, repoSlug: c.repoSlug, colorHex: c.colorHex, symbol: c.symbol, appVersion: AppVersion.calver,
                                        api: CompanionAPI.version, host: Self.hostName, allowsMessages: allowsMessages))
    }

    /// The Mac's name — gethostname, not ProcessInfo.hostName, which can wait on a reverse DNS lookup.
    nonisolated static var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "Mac" }
        let h = String(cString: buf)
        return h.hasSuffix(".local") ? String(h.dropLast(6)) : h
    }

    // work

    private func workAnswer() -> Response {
        guard let s = readStore() else { return stillReading() }
        return reply(Self.work(items: s.work, activity: s.activity, problems: s.problems, refreshed: s.lastRefresh, spaces: s.spaces))
    }

    nonisolated static func work(items: [WorkItem], activity: [OracleSnapshot.Activity], problems: [String], refreshed: Date?,
                                 spaces: [HerdrSpace] = []) -> CompanionAPI.Work {
        CompanionAPI.Work(items: items.map { workItem($0, shells: shells(of: $0, spaces: spaces)) }, activity: panes(activity),
                          problems: problems, refreshed: refreshed)
    }

    /// The plain shells in a worktree's herdr space, or with their folder in it: the Mac's Work page lists them after its
    /// agents (panesOf). The phone may read their screen; it never types into one — that would run commands on the Mac.
    nonisolated static func shells(of w: WorkItem, spaces: [HerdrSpace]) -> [CompanionAPI.Pane] {
        let agents = Set(w.panes.map(\.place))
        return spaces.filter { $0.checkout == w.path || $0.panes.contains { $0.cwd == w.path || $0.cwd.hasPrefix(w.path + "/") } }
            .flatMap(\.panes).filter { $0.agent == nil && !agents.contains($0.place) }
            .map { CompanionAPI.Pane(place: $0.place, title: CompanionAPI.shellTitle, status: "idle", since: nil, cwd: $0.cwd) }
    }

    /// Every pane, most urgent first: blocked, done, working, idle.
    nonisolated static func panes(_ activity: [OracleSnapshot.Activity]) -> [CompanionAPI.Pane] {
        activity.sorted { (WorkFormat.rank($0.status), $0.place) < (WorkFormat.rank($1.status), $1.place) }
            .map { CompanionAPI.Pane(place: $0.place, title: $0.title, status: $0.status, since: $0.since, cwd: $0.cwd) }
    }

    nonisolated static func workItem(_ w: WorkItem, shells: [CompanionAPI.Pane] = []) -> CompanionAPI.WorkItem {
        CompanionAPI.WorkItem(path: w.path, folder: w.folder, branch: w.branch, isMain: w.isMain, issue: w.issue,
                              prNumber: w.pr?.number, prTitle: w.pr?.title, state: w.state.label, panes: panes(w.panes) + shells,
                              resumeCommand: w.resumeCommand, slug: w.slug, born: w.born)
    }

    /// A pane the phone may read: an agent pane the Work data lists, or a plain shell the Work page shows.
    nonisolated static func readable(_ place: String, activity: [OracleSnapshot.Activity], work: [WorkItem], spaces: [HerdrSpace]) -> Bool {
        listed(place, activity: activity, work: work) || work.contains { shells(of: $0, spaces: spaces).contains { $0.place == place } }
    }

    /// An agent pane the Work data lists — in the activity, or one a work item holds. Only these are messaged.
    nonisolated static func listed(_ place: String, activity: [OracleSnapshot.Activity], work: [WorkItem]) -> Bool {
        activity.contains { $0.place == place } || work.contains { $0.panes.contains { $0.place == place } }
    }

    // screen

    /// `herdr --session S pane read P --source recent --lines 400` — the rows as the terminal draws them, like PaneScreen.
    nonisolated static func readArgs(place: String) -> [String]? {
        let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-") else { return nil }
        return ["--session", parts[0], "pane", "read", parts[1], "--source", "recent", "--lines", "400"]
    }

    /// The text without its trailing blank rows and spaces (PaneScreen's `\s+$`).
    nonisolated static func trimmed(_ s: String) -> String {
        guard let last = s.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(s[...last])
    }

    private func screenAnswer(_ q: [String: String]) async -> Response {
        guard let s = readStore() else { return stillReading() }
        guard let place = q["place"], !place.isEmpty else {
            return fail(400, "place is missing", fix: "GET /v1/screen?place=\(examplePlace())   — the places are in GET /v1/work")
        }
        guard Self.readable(place, activity: s.activity, work: s.work, spaces: s.spaces), let args = Self.readArgs(place: place) else {
            return fail(404, "\(Self.clip(place, 80)) is not a pane the Work page lists", fix: "GET /v1/work lists the places; on the Mac:  maw herdr ls --agents")
        }
        guard let out = await Shell.run("herdr", args, timeout: 4) else {
            return fail(502, "the Mac can't read \(place) — is herdr running?", fix: "herdr session list    then    herdr --session \(args[1]) pane list")
        }
        return reply(CompanionAPI.Screen(place: place, text: Self.trimmed(out), read: Date()))
    }

    // inbox

    private func inboxAnswer() -> Response {
        guard let s = readStore() else { return stillReading() }
        return reply(Self.inbox(items: s.inbox, unread: s.unread, root: s.config.inboxPath))
    }

    nonisolated static func inbox(items: [InboxItem], unread: Set<String>, root: String) -> CompanionAPI.Inbox {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return CompanionAPI.Inbox(items: items.compactMap { i in
            guard i.path.hasPrefix(prefix) else { return nil }
            return CompanionAPI.InboxEntry(path: String(i.path.dropFirst(prefix.count)), name: i.name, folder: i.folder,
                                           modified: i.modified, unread: unread.contains(i.path))
        }.sorted { $0.modified > $1.modified })
    }

    /// A relative path that cannot leave the folder by its spelling: no "." or ".." part, no hidden part, not absolute,
    /// no control characters.
    nonisolated static func safe(relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        return !relative.split(separator: "/", omittingEmptySubsequences: false).contains { $0.hasPrefix(".") }
    }

    /// The file `relative` names under `root`, with every symlink resolved — or nil when it is spelled to escape
    /// (absolute, "..", hidden), does not exist, or resolves outside `root + "/"` (a symlink out).
    nonisolated static func confine(relative: String, root: String) -> URL? {
        guard safe(relative: relative), !root.isEmpty, let realRoot = realPath(root), let real = realPath(realRoot + "/" + relative) else { return nil }
        let inside = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard real.hasPrefix(inside), real.count > inside.count else { return nil }
        return URL(fileURLWithPath: real)
    }

    nonisolated static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    enum FileRead: Equatable {
        case text(String, Date)
        case missing, notRegular, tooLarge, notText
        case unreadable(Int32)
    }

    /// A regular text file of at most `limit` bytes. Opened without following a last symlink, never blocking on a pipe;
    /// the size and type are the open file's own.
    nonisolated static func readText(_ url: URL, limit: Int) -> FileRead {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return [ENOENT, ENOTDIR].contains(errno) ? .missing : errno == ELOOP ? .notRegular : .unreadable(errno)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        if st.st_size > off_t(limit) { return .tooLarge }
        let data: Data
        do { data = try handle.read(upToCount: limit + 1) ?? Data() } catch { return .unreadable(EIO) }   // nil is the end of an empty file
        if data.count > limit { return .tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .notText }
        return .text(text, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
    }

    private func inboxFileAnswer(_ q: [String: String]) async -> Response {
        guard let c = config, !c.inboxPath.isEmpty else {
            return fail(404, "this app has no ψ/inbox on the Mac", fix: "set the oracle's checkout in its OracleConfig (localPath) and rebuild the app")
        }
        guard let rel = q["path"], !rel.isEmpty else {
            return fail(400, "path is missing", fix: "GET /v1/inbox/file?path=\(exampleInboxPath())   — the paths are in GET /v1/inbox")
        }
        let hint = "GET /v1/inbox lists the files; a path is relative to ψ/inbox, e.g.  GET /v1/inbox/file?path=\(exampleInboxPath())"
        guard Self.safe(relative: rel) else {
            return fail(403, "that path leaves ψ/inbox (no .., no absolute path, no hidden file)", fix: hint)
        }
        guard let url = Self.confine(relative: rel, root: c.inboxPath) else {
            return fail(404, "no such file in ψ/inbox: \(Self.clip(rel, 80))", fix: hint)
        }
        let result = await Task.detached(priority: .userInitiated) { Self.readText(url, limit: Self.maxFile) }.value
        switch result {
        case .text(let text, let modified): return reply(CompanionAPI.InboxFile(path: rel, text: text, modified: modified))
        case .missing: return fail(404, "no such file in ψ/inbox: \(Self.clip(rel, 80))", fix: hint)
        case .notRegular: return fail(415, "\(Self.clip(rel, 80)) is not a regular file", fix: hint)
        case .tooLarge: return fail(413, "\(Self.clip(rel, 80)) is larger than \(Self.maxFile / 1024) KB", fix: "open it on the Mac:  open \(Self.shellQuoted(url.path))")
        case .notText: return fail(415, "\(Self.clip(rel, 80)) is not UTF-8 text", fix: "open it on the Mac:  open \(Self.shellQuoted(url.path))")
        case .unreadable(let e): return fail(500, "the Mac could not read \(Self.clip(rel, 80)) (errno \(e))", fix: "ls -l \(Self.shellQuoted(url.path))")
        }
    }

    // github

    private func githubAnswer() -> Response {
        guard let s = readStore() else { return stillReading() }
        return reply(CompanionAPI.GitHub(prs: s.prs.map(Self.entry), issues: s.issues.map(Self.entry)))
    }

    nonisolated static func entry(_ g: GHItem) -> CompanionAPI.GHEntry {
        CompanionAPI.GHEntry(number: g.number, title: g.title, author: g.author, updatedAt: g.updatedAt, url: g.url, isDraft: g.isDraft, branch: g.branch,
                             closes: g.closes.isEmpty ? nil : g.closes)
    }

    // search

    /// The same kind → (kind, who) mapping as MCPServer's memory_search.
    nonisolated static func filter(kind: String) -> (kind: String?, state: String?) {
        switch kind {
        case "sessions": ("history", nil)
        case "you": ("history", "user")
        case "oracle": ("history", "assistant")
        case "notes": ("note", nil)
        case "issues": ("issue", nil)
        case "prs": ("pr", nil)
        default: (nil, nil)
        }
    }

    nonisolated static func hit(_ h: IndexHit) -> CompanionAPI.SearchHit {
        let d = h.doc
        return CompanionAPI.SearchHit(id: d.id, kind: d.kind, title: d.title, snippet: d.snippet, state: d.state, url: d.url, updated: d.updated,
                                      repo: d.repo, number: d.number, score: h.score.isFinite ? h.score : 0)
    }

    /// MCP's kinds, and "gh": issues and PRs together, as the Mac's Memory page filters them.
    nonisolated static let searchKinds = MCPServer.kinds + ["gh"]

    /// Who asked, as the phone names itself ("iPad"): letters, digits and spaces only, at most 24 — it goes into the trace.
    nonisolated static func device(_ headers: [String: String]) -> String {
        let raw = headers[CompanionAPI.deviceHeader.lowercased()] ?? ""
        let kept = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(Character.init)).prefix(24)
        let name = kept.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "phone" : name
    }

    private func searchAnswer(_ q: [String: String], _ r: MCPServer.Request) async -> Response {
        let text = String((q["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        guard !text.isEmpty else {
            return fail(400, "q is empty", fix: "GET /v1/search?q=heartrate&kind=all&limit=25")
        }
        let kind = q["kind"] ?? "all"
        guard Self.searchKinds.contains(kind) else {
            return fail(400, "unknown kind \"\(Self.clip(kind, 30))\"", fix: "kind is one of  " + Self.searchKinds.joined(separator: "  "))
        }
        guard let index = launch?.index() else { return starting() }
        let limit = min(50, max(1, Int(q["limit"] ?? "") ?? 25))
        let f = Self.filter(kind: kind)
        let t0 = Date()
        let kinds: Set<String>? = kind == "gh" ? ["issue", "pr"] : nil   // the Mac's "Issues & PRs": one query, one trace line
        guard let hits = await index.query(text, kind: f.kind, kinds: kinds, state: f.state, limit: limit, source: "companion",
                                           caller: "\(Self.device(r.headers)) · companion") else {
            return fail(503, index.problem ?? "no embedder answered",
                        fix: "on the Mac: Settings → Engine → Retry loading or Check engine  (curl -s 127.0.0.1:11435/health)")
        }
        // the trace line this query just wrote holds its timings
        let t = TraceLog.shared.entries.last { $0.source == "companion" && $0.query == text && $0.at >= t0 }
        func ms(_ x: Double?) -> Double { x.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        return reply(CompanionAPI.Search(query: text, hits: hits.map(Self.hit), embedMs: ms(t?.embedMs), rankMs: ms(t?.rankMs), pool: t?.pool ?? hits.count))
    }

    // status

    private func statusAnswer() async -> Response {
        guard let index = launch?.index() else { return starting() }
        if index.engine == nil { await index.checkEngine() }
        let docs = index.docs, hasMap = !index.layout.xyz.isEmpty
        let engine = index.engine.map { $0.ok ? $0.kind : "not answering" }, built = index.built
        let counts = await Task.detached(priority: .userInitiated) { Self.counts(docs) }.value
        return reply(CompanionAPI.MemoryStatus(items: docs.count, byKind: counts.byKind, sessions: counts.sessions, engine: engine, built: built, hasMap: hasMap))
    }

    /// Items per kind and the number of distinct sessions — MCPServer's memory_status.
    nonisolated static func counts(_ docs: [IndexDoc]) -> (byKind: [String: Int], sessions: Int) {
        var byKind: [String: Int] = [:]
        var sessions: Set<String> = []
        for d in docs { byKind[d.kind, default: 0] += 1; if d.kind == "history" { sessions.insert(d.url) } }
        return (byKind, sessions.count)
    }

    // map

    private func mapAnswer() async -> Response {
        guard let index = launch?.index() else { return starting() }
        let layout = index.layout
        guard !layout.xyz.isEmpty, layout.xyz.count == layout.ids.count else {
            return fail(404, "this memory has no map layout yet", fix: "on the Mac: Settings → Vector search → Rebuild map layout")
        }
        let clusters = index.clusters
        // the memory grew since the Mac's Map page last grouped it: group it now (off the main actor, as the page does),
        // or the phone gets a map with no groups at all
        if clusters.labels.count != layout.ids.count { await clusters.refresh(layout: layout, docs: index.docs) }
        let (ids, xyz, knn, k, docs, labels, groups) = (layout.ids, layout.xyz, layout.knn, layout.k, index.docs, clusters.labels, clusters.groups)
        // a big layout is megabytes of JSON: build and encode it off the main actor
        let body = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? CompanionAPI.encoder.encode(Self.mapData(ids: ids, xyz: xyz, knn: knn, k: k, docs: docs, labels: labels, groups: groups))
        }.value
        guard let body else { return fail(500, "the Mac could not encode the map", fix: "update the Mac app and the phone app to the same version") }
        return Response(status: 200, body: body)
    }

    /// The layout as the phone gets it. Row i of every array is the same doc; a doc the index no longer has keeps its id as title.
    nonisolated static func mapData(ids: [String], xyz: [SIMD3<Float>], knn: [Int32], k: Int, docs: [IndexDoc],
                                    labels: [Int], groups: [MapClusters.Group]) -> CompanionAPI.MapData {
        let at = Dictionary(docs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kinds: [String] = [], titles: [String] = []
        kinds.reserveCapacity(ids.count); titles.reserveCapacity(ids.count)
        for id in ids {
            if let i = at[id] { kinds.append(docs[i].kind); titles.append(title(of: docs[i])) }
            else { kinds.append(""); titles.append(String(id.prefix(120))) }
        }
        let n = ids.count
        let hasKNN = k > 0 && knn.count == n * k
        let grouped = labels.count == n && !groups.isEmpty
        return CompanionAPI.MapData(ids: ids, kinds: kinds, titles: titles, xyz: MapLayout.pack(xyz),
                                    knn: hasKNN ? knn.withUnsafeBufferPointer { Data(buffer: $0) } : Data(), k: hasKNN ? k : 0,
                                    labels: grouped ? labels : [],
                                    groups: grouped ? groups.map { CompanionAPI.MapGroup(id: $0.id, count: $0.count, keywords: $0.keywords, title: $0.title) } : [])
    }

    /// What the Map page names a point: what was said for a session piece, else the title — at most 120 characters.
    nonisolated static func title(of d: IndexDoc) -> String {
        let t = d.kind == "history" && !d.snippet.isEmpty ? d.snippet : d.title
        return String(t.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }

    // trace

    private func traceAnswer(_ q: [String: String]) async -> Response {
        let limit = min(1_000, max(1, Int(q["limit"] ?? "") ?? 200))
        await TraceLog.shared.loadPast()
        let all = TraceLog.shared.past + TraceLog.shared.entries
        return reply(CompanionAPI.Trace(entries: all.suffix(limit).map(Self.finite)))
    }

    /// The same entry with numbers JSON can carry (a NaN would fail the whole answer).
    nonisolated static func finite(_ e: TraceLog.Entry) -> TraceLog.Entry {
        guard !e.embedMs.isFinite || !e.rankMs.isFinite || e.top.contains(where: { !$0.score.isFinite }) else { return e }
        return TraceLog.Entry(id: e.id, at: e.at, source: e.source, index: e.index, query: e.query, filter: e.filter,
                              embedMs: e.embedMs.isFinite ? e.embedMs : 0, rankMs: e.rankMs.isFinite ? e.rankMs : 0, pool: e.pool, via: e.via,
                              top: e.top.map { .init(id: $0.id, title: $0.title, score: $0.score.isFinite ? $0.score : 0) }, caller: e.caller)
    }

    // hey — the one write

    /// What reaches the agent pane. Control characters other than newline and tab are dropped (a NUL in a Process argument
    /// raises an Objective-C exception that kills the app; an ESC or a Ctrl-C is a keystroke, not text), and a message that
    /// starts with "-" gets a space in front, because `maw herdr hey` reads such an argument as an option — `--help` printed
    /// its usage and counted as sent.
    nonisolated static func safeMessage(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control }
        let s = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("-") ? " " + s : s
    }

    private func heyAnswer(_ r: MCPServer.Request) async -> Response {
        guard allowsMessages else {
            return fail(403, "messages from the phone are off on this Mac", fix: "on the Mac: turn on Allow messages in Settings → Companion")
        }
        // a test token can be one character, and loopback is every local process: with one, the server does not type into panes
        if let t = tokenOverride, t.count < 32 {
            return fail(403, "messages are off while the server runs on a short test token (-companionToken)",
                        fix: "relaunch without -companionToken, or with one of at least 32 characters:  openssl rand -hex 32")
        }
        guard let s = readStore() else { return stillReading() }
        guard let hey = try? CompanionAPI.decoder.decode(CompanionAPI.Hey.self, from: r.body) else {
            return fail(400, "the body is not {\"place\", \"text\"} JSON",
                        fix: #"send  {"place":"\#(examplePlace())","text":"hello"}  with  Content-Type: application/json"#)
        }
        let text = Self.safeMessage(hey.text)
        guard !text.isEmpty else { return fail(400, "text is empty", fix: #"send  {"place":"\#(Self.clip(hey.place, 60))","text":"hello"}  — text must not be empty"#) }
        guard text.count <= Self.maxMessage else {
            return fail(413, "the message is \(text.count) characters; the limit is \(Self.maxMessage)", fix: "send it in parts of at most \(Self.maxMessage) characters")
        }
        guard Self.listed(hey.place, activity: s.activity, work: s.work) else {
            return fail(404, "\(Self.clip(hey.place, 80)) is not a pane the Work page lists", fix: "GET /v1/work lists the places; on the Mac:  maw herdr ls --agents")
        }
        guard await s.hey(place: hey.place, message: text) else {
            return fail(502, "maw herdr hey could not deliver the message to \(hey.place)", fix: "on the Mac:  maw herdr ls --agents   (is the pane still there?) — then send again")
        }
        return reply(CompanionAPI.Sent(ok: true))
    }
}

/// The pairing link as a QR code a phone camera reads: black modules on white with a 4-module quiet zone, scaled by a whole
/// number so every module is the same size and never smoothed.
enum CompanionQR {
    private static let context = CIContext()

    static func image(_ text: String, minPixels: Int = 360) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let code = f.outputImage, code.extent.width >= 1 else { return nil }
        let quiet = 4, side = Int(code.extent.width) + 2 * quiet
        let scale = max(1, (minPixels + side - 1) / side)   // at least minPixels wide, every module a whole number of pixels
        let white = CIImage(color: .white).cropped(to: CGRect(x: -quiet, y: -quiet, width: side, height: side))
        let big = code.composited(over: white).samplingNearest().transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return context.createCGImage(big, from: big.extent)
    }
}
#endif
