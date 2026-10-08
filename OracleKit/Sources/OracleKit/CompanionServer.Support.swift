#if os(macOS)
import Foundation
import Network
import Security

extension CompanionServer {
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
}
#endif
