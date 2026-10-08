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

    var launch: (name: String, mcpPort: UInt16, index: () -> GHIndex)?
    weak var store: OracleStore?
    private var listeners: [String: NWListener] = [:]
    private var ready: Set<String> = []
    private var monitor: NWPathMonitor?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var retries: [String: Int] = [:]    // address → tries since its listener last failed
    var tokenOverride: String?
    private let useKeychain: Bool
    let defaults: UserDefaults

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
