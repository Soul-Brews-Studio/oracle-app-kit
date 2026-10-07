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
    /// What went wrong last, with the fix — shown on the phone as it is.
    @Published public private(set) var problem: String?

    public init() { pairing = PairingStore.read() }

    public var isPaired: Bool { pairing != nil }

    /// Keep a pairing only when the Mac answers /v1/hello with it, with this API version.
    @discardableResult
    public func pair(_ p: CompanionAPI.Pairing) async -> Bool {
        let previous = pairing
        pairing = p
        guard let h: CompanionAPI.Hello = await get(CompanionAPI.Path.hello) else { pairing = previous; return false }
        guard h.api == CompanionAPI.version else {
            problem = "The Mac speaks companion API v\(h.api), this app v\(CompanionAPI.version) — update the \(h.api > CompanionAPI.version ? "phone" : "Mac") app"
            pairing = previous; return false
        }
        hello = h
        PairingStore.write(p)
        return true
    }

    public func unpair() {
        pairing = nil; hello = nil; reachable = nil; problem = nil
        PairingStore.clear()
    }

    // MARK: calls (nil on failure; `problem` says why)

    public func refreshHello() async { if let h: CompanionAPI.Hello = await get(CompanionAPI.Path.hello) { hello = h } }
    public func work() async -> CompanionAPI.Work? { await get(CompanionAPI.Path.work) }
    public func screen(place: String) async -> CompanionAPI.Screen? { await get(CompanionAPI.Path.screen, ["place": place]) }
    public func inbox() async -> CompanionAPI.Inbox? { await get(CompanionAPI.Path.inbox) }
    public func inboxFile(path: String) async -> CompanionAPI.InboxFile? { await get(CompanionAPI.Path.inboxFile, ["path": path]) }
    public func github() async -> CompanionAPI.GitHub? { await get(CompanionAPI.Path.github) }
    public func search(_ q: String, kind: String = "all", limit: Int = 25) async -> CompanionAPI.Search? {
        await get(CompanionAPI.Path.search, ["q": q, "kind": kind, "limit": String(limit)], timeout: 60)
    }
    public func status() async -> CompanionAPI.MemoryStatus? { await get(CompanionAPI.Path.status) }
    public func map() async -> CompanionAPI.MapData? { await get(CompanionAPI.Path.map, timeout: 60) }
    public func trace(limit: Int = 200) async -> CompanionAPI.Trace? { await get(CompanionAPI.Path.trace, ["limit": String(limit)]) }
    public func hey(place: String, text: String) async -> Bool {
        let s: CompanionAPI.Sent? = await send(CompanionAPI.Path.hey, body: CompanionAPI.Hey(place: place, text: text))
        return s?.ok == true
    }

    // MARK: transport

    private func request(_ path: String, _ query: [String: String], timeout: TimeInterval) -> URLRequest? {
        guard let p = pairing, let base = p.baseURL, var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { problem = "not paired — on the Mac: Settings → Companion, then scan its code here"; return nil }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 15) async -> T? {
        guard let r = request(path, query, timeout: timeout) else { return nil }
        return await perform(r)
    }

    private func send<B: Encodable, T: Decodable>(_ path: String, body: B) async -> T? {
        guard var r = request(path, [:], timeout: 30) else { return nil }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? CompanionAPI.encoder.encode(body)
        return await perform(r)
    }

    private func perform<T: Decodable>(_ r: URLRequest) async -> T? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                reachable = true
                if let p = try? CompanionAPI.decoder.decode(CompanionAPI.Problem.self, from: data) {
                    problem = p.fix.map { "\(p.error) — \($0)" } ?? p.error
                } else {
                    problem = code == 401 ? "the Mac refused the token — pair again (Mac: Settings → Companion → Rotate, then scan)"
                                          : "the Mac answered HTTP \(code)"
                }
                return nil
            }
            reachable = true; problem = nil
            return try CompanionAPI.decoder.decode(T.self, from: data)
        } catch is DecodingError {
            problem = "the Mac's answer did not decode — update both apps to the same version"; return nil
        } catch {
            reachable = false
            let host = pairing.map { "\($0.host):\($0.port)" } ?? "?"
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
    public static func write(_ p: CompanionAPI.Pairing) {
        clear()
        guard let d = try? JSONEncoder().encode(p) else { return }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: d,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(add as CFDictionary, nil)
    }
    public static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
