import Foundation
import Security

/// The phone's side of the companion API: one paired Mac app, reached over HTTP with its bearer token.
/// Pairing (host, port, token, name) lives in the Keychain; `pair(_:)` checks it with /v1/hello before keeping it.
/// Compiles on every platform (the Mac's tests use it against its own server).
@MainActor
public final class CompanionClient: ObservableObject {
    public static let shared = CompanionClient()

    @Published public private(set) var pairing: CompanionAPI.Pairing?
    @Published public private(set) var hello: CompanionAPI.Hello?
    /// The last answer worked (nil before the first call).
    @Published public private(set) var reachable: Bool?
    /// The Mac answered but refused this phone's token (401/403): Rotate on the Mac, or another Mac on its address.
    @Published public private(set) var refused = false
    /// What went wrong last, with the fix — shown on the phone as it is.
    @Published public private(set) var problem: String?

    public init() { pairing = PairingStore.read() }

    public var isPaired: Bool { pairing != nil }

    /// Keep a pairing only when the Mac answers /v1/hello with it, with this API version. The hello goes out with the
    /// candidate; nothing changes until it answers, so `pairing` (and `isPaired`) is always a Mac that answered — the pages
    /// and a pairing sheet never act on one nobody has checked. On a refusal `problem` says why.
    @discardableResult
    public func pair(_ p: CompanionAPI.Pairing) async -> Bool {
        guard let h: CompanionAPI.Hello = await get(CompanionAPI.Path.hello, via: p) else { return false }
        guard h.api == CompanionAPI.version else {
            problem = "The Mac speaks companion API v\(h.api), this app v\(CompanionAPI.version) — update the \(h.api > CompanionAPI.version ? "phone" : "Mac") app"
            return false
        }
        if let why = PairingStore.write(p) { problem = why; return false }
        pairing = p; hello = h; reachable = true; refused = false; problem = nil
        return true
    }

    public func unpair() {
        pairing = nil; hello = nil; reachable = nil; refused = false; problem = nil
        PairingStore.clear()
    }

    // MARK: calls (nil on failure; `problem` says why)

    public func refreshHello() async { if let h: CompanionAPI.Hello = await get(CompanionAPI.Path.hello) { hello = h } }
    public func work() async -> CompanionAPI.Work? { await get(CompanionAPI.Path.work) }
    public func screen(place: String) async -> CompanionAPI.Screen? { await get(CompanionAPI.Path.screen, ["place": place]) }
    public func inbox() async -> CompanionAPI.Inbox? { await get(CompanionAPI.Path.inbox) }
    public func inboxFile(path: String) async -> CompanionAPI.InboxFile? { await get(CompanionAPI.Path.inboxFile, ["path": path]) }
    public func github() async -> CompanionAPI.GitHub? { await get(CompanionAPI.Path.github) }
    /// The question goes in the URL, and the Mac takes 4 KB of request head: a Thai character is 9 bytes there, so a
    /// question is clipped to 300 characters (the Mac reads no more than that closely anyway).
    public func search(_ q: String, kind: String = "all", limit: Int = 25) async -> CompanionAPI.Search? {
        await get(CompanionAPI.Path.search, ["q": String(q.prefix(300)), "kind": kind, "limit": String(limit)], timeout: 60)
    }
    public func status() async -> CompanionAPI.MemoryStatus? { await get(CompanionAPI.Path.status) }
    public func map() async -> CompanionAPI.MapData? { await get(CompanionAPI.Path.map, timeout: 60) }
    public func trace(limit: Int = 200) async -> CompanionAPI.Trace? { await get(CompanionAPI.Path.trace, ["limit": String(limit)]) }
    public func hey(place: String, text: String) async -> Bool {
        let s: CompanionAPI.Sent? = await send(CompanionAPI.Path.hey, body: CompanionAPI.Hey(place: place, text: text))
        return s?.ok == true
    }

    // MARK: transport

    /// The device that asks, for the Mac's trace ("iPad · companion"): set by the iOS app at launch.
    public var device = "phone"

    private func request(_ path: String, _ query: [String: String], timeout: TimeInterval, via candidate: CompanionAPI.Pairing? = nil) -> URLRequest? {
        guard let p = candidate ?? pairing, let base = p.baseURL, var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { problem = "not paired — on the Mac: Settings → Companion, then scan its code here"; return nil }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(device, forHTTPHeaderField: CompanionAPI.deviceHeader)
        return r
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 15,
                                   via candidate: CompanionAPI.Pairing? = nil) async -> T? {
        guard let r = request(path, query, timeout: timeout, via: candidate) else { return nil }
        return await perform(r, candidate: candidate != nil)
    }

    private func send<B: Encodable, T: Decodable>(_ path: String, body: B) async -> T? {
        guard var r = request(path, [:], timeout: 30) else { return nil }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? CompanionAPI.encoder.encode(body)
        return await perform(r)
    }

    /// `candidate`: a pairing still being checked. Its answer says nothing about the kept pairing, so `reachable` is left alone.
    private func perform<T: Decodable>(_ r: URLRequest, candidate: Bool = false) async -> T? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // the Mac answered; a 401/403 means it no longer takes this phone's token (Rotate): not "live"
                if !candidate { reachable = true; refused = code == 401 || code == 403 }
                if let p = try? CompanionAPI.decoder.decode(CompanionAPI.Problem.self, from: data) {
                    problem = p.fix.map { "\(p.error) — \($0)" } ?? p.error
                } else {
                    problem = code == 401 ? "the Mac refused the token — pair again (Mac: Settings → Companion → Rotate, then scan)"
                                          : "the Mac answered HTTP \(code)"
                }
                return nil
            }
            if !candidate { reachable = true; refused = false }
            problem = nil
            return try CompanionAPI.decoder.decode(T.self, from: data)
        } catch is DecodingError {
            problem = "the Mac's answer did not decode — update both apps to the same version"; return nil
        } catch {
            if !candidate { reachable = false }
            let host = r.url.flatMap { u in u.host.map { "\($0):\(u.port ?? 80)" } } ?? "?"
            problem = "can't reach the Mac at \(host) (\(error.localizedDescription)) — is the app open, Companion on, and NetBird connected on both?"
            return nil
        }
    }
}

/// The pairing in the Keychain (the token is a credential).
public enum PairingStore {
    static let service = "co.laris.oracle.companion", account = "pairing"
    public static func read() -> CompanionAPI.Pairing? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(CompanionAPI.Pairing.self, from: d)
    }
    /// nil when kept; otherwise why not, with the fix. The token stays on this device: not in a backup, not on a new phone.
    /// The old pairing is replaced in place, so a failed write leaves it as it was.
    @discardableResult
    public static func write(_ p: CompanionAPI.Pairing) -> String? {
        guard let d = try? JSONEncoder().encode(p) else { return "the pairing could not be encoded — pair again" }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: d, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil) }
        return status == errSecSuccess ? nil : "the Keychain did not keep the pairing (OSStatus \(status)) — restart the phone, then pair again"
    }
    public static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// How the phone frames the Mac's map: centred on the points it draws (the median on each axis), and scaled so 80 % of them lie within `radius`.
/// The body of the cloud then fills the view however far its strays reach (the Mac's map frames the same 80 %, #35).
/// Compiles on every platform so the Mac's tests check it.
enum MapFrame {
    static func fit(_ p: [SIMD3<Float>], drawn: [Bool], radius: Float = 0.45) -> (centre: SIMD3<Float>, scale: Float) {
        let rows = p.indices.filter { $0 < drawn.count && drawn[$0] && p[$0].x.isFinite && p[$0].y.isFinite && p[$0].z.isFinite }
        guard !rows.isEmpty else { return (.zero, 1) }
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }   // a few far strays cannot drag it, as they would a mean
        let centre = SIMD3<Float>(median(rows.map { p[$0].x }), median(rows.map { p[$0].y }), median(rows.map { p[$0].z }))
        let d = rows.map { i -> Float in let v = p[i] - centre; return (v * v).sum().squareRoot() }.sorted()
        let r80 = d[min(d.count - 1, Int(Float(d.count) * 0.8))]
        return (centre, r80 > 1e-4 ? radius / r80 : 1)
    }
}
