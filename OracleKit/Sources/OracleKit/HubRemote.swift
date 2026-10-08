import Foundation

/// A herdr session on another machine, reached the way Nat reaches it: `herdr --remote <target> --session <name>`
/// (Nat, 2026-10-08: "can we list the remote? if not machine, like this?").
///
/// herdr keeps no record of these; only saved machines (`herdr machine list`) are remembered. Its `--remote`
/// (src/remote/attach.rs `run_remote`) bridges ssh to a local socket and runs a LOCAL client of the session, so
/// what stays behind on this Mac is ~/.config/herdr/sessions/<name>/herdr-client.log, a folder that `herdr session
/// list` shows as a stopped local session. The hub therefore remembers every remote it sees attached here, and
/// reads those traces back to their targets (`RemoteParse.socketHash`).
public struct RemoteSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String { target + "|" + session }
    /// the ssh target as typed: "phd-oracle@black.follow-rankine.ts.net", "white"
    public let target: String
    /// "default" when the command had no --session
    public let session: String
    /// a saved herdr machine's label
    public var label: String?

    public init(target: String, session: String, label: String? = nil) {
        self.target = target; self.session = session.isEmpty ? "default" : session; self.label = label
    }

    /// herdr's arguments for this session: `--remote <target> [--session <name>]`
    public var arguments: [String] { ["--remote", target] + (session == "default" ? [] : ["--session", session]) }
    public var command: String { "herdr " + arguments.joined(separator: " ") }
    /// "black" from "phd-oracle@black.follow-rankine.ts.net": the machine, as the sidebar groups it
    public var host: String { (target.split(separator: "@").last.map(String.init) ?? target).split(separator: ".").first.map(String.init) ?? target }
    /// "phd-oracle" from "phd-oracle@black…"; nil when the target names no user
    public var user: String? { target.contains("@") ? String(target.split(separator: "@")[0]) : nil }
    /// "phd-oracle@black" from "phd-oracle@black.follow-rankine.ts.net"
    public var shortTarget: String {
        guard let at = target.lastIndex(of: "@") else { return target.split(separator: ".").first.map(String.init) ?? target }
        let host = target[target.index(after: at)...].split(separator: ".").first.map(String.init) ?? ""
        return String(target[..<at]) + "@" + host
    }
    /// Only what an ssh target and a session name can hold, so neither ever reaches a shell as anything else.
    public var isSafe: Bool {
        let t = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:/[]")
        let s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !target.isEmpty && !target.hasPrefix("-") && target.unicodeScalars.allSatisfy(t.contains)
            && !session.isEmpty && !session.hasPrefix("-") && session.unicodeScalars.allSatisfy(s.contains)
    }
}

/// What a machine answered (`RemoteParse.listCommand` over ssh): its herdr and every session on it, or why not.
public struct RemoteMachineState: Sendable, Equatable {
    public var version: String?
    /// session name → running
    public var sessions: [String: Bool] = [:]
    /// why it could not be read, ending with the command that helps
    public var problem: String?
    public var checked = Date()
    public init(version: String? = nil, sessions: [String: Bool] = [:], problem: String? = nil, checked: Date = Date()) {
        self.version = version; self.sessions = sessions; self.problem = problem; self.checked = checked
    }
}

/// What a probe of a remote session found: `ssh <target> herdr --session <s> agent list`.
public struct RemoteState: Sendable, Equatable {
    public var running: Bool
    public var agents: Int = 0
    public var working: Int = 0
    public var needsYou: Int = 0
    public var version: String?
    /// why it could not be read, ending with the command that helps
    public var problem: String?
    public var checked = Date()

    public init(running: Bool, agents: Int = 0, working: Int = 0, needsYou: Int = 0, version: String? = nil,
                problem: String? = nil, checked: Date = Date()) {
        self.running = running; self.agents = agents; self.working = working; self.needsYou = needsYou
        self.version = version; self.problem = problem; self.checked = checked
    }
}

public enum RemoteParse {
    /// `herdr --remote <target> [--session <name>]`, herdr by any path → the session it attaches. The bridge herdr
    /// starts on the far side (`herdr --session <s> remote-client-bridge`) and every other command line → nil.
    public static func remote(of args: String) -> RemoteSession? {
        let f = args.split(separator: " ").map(String.init)
        guard let first = f.first, (first as NSString).lastPathComponent == "herdr",
              let i = f.firstIndex(of: "--remote"), i + 1 < f.count, !f[i + 1].hasPrefix("-") else { return nil }
        var session = "default"
        if let j = f.firstIndex(of: "--session"), j + 1 < f.count { session = f[j + 1] }
        return RemoteSession(target: f[i + 1], session: session)
    }

    /// `herdr machine list --json` → saved machines; each targets one remote session.
    public static func machines(_ data: Data) -> [RemoteSession] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard (r["enabled"] as? Bool) != false, let t = r["target"] as? String else { return nil }
            return RemoteSession(target: t, session: r["session"] as? String ?? "default", label: r["label"] as? String)
        }
    }

    /// The socket a remote client last connected to, from a session folder's client log:
    /// "connecting to server path=…/herdr-r-16741-phd-orac-2636df18a3e9f21e.sock" → ("phd-orac", "2636df18a3e9f21e").
    public static func trace(clientLog: String) -> (prefix: String, hash: String)? {
        guard let r = clientLog.range(of: #"herdr-r-[0-9]+-([A-Za-z0-9._-]*)-([0-9a-f]{16})\.sock"#, options: [.regularExpression, .backwards])
        else { return nil }
        let name = String(clientLog[r].dropLast(5))                  // no ".sock"
        let hash = String(name.suffix(16))
        let rest = name.dropLast(17)                                   // "herdr-r-<pid>-<prefix>"
        guard let pidEnd = rest.dropFirst(8).firstIndex(of: "-") else { return nil }
        return (String(rest[rest.index(after: pidEnd)...]), hash)
    }

    /// herdr's sanitize_path_component: what a target looks like in that socket name.
    public static func sanitized(_ s: String) -> String {
        let mapped = String(s.map { c in c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "-" })
        return String(mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32))
    }

    /// herdr's short_socket_hash: Rust's DefaultHasher (SipHash-1-3, keys 0) over `target.hash(); 0u8.hash();
    /// session.hash()`, a str hashing as its bytes then 0xFF. Checked against both traces on m5.
    public static func socketHash(target: String, session: String) -> String {
        let bytes = Array(target.utf8) + [0xFF, 0x00] + Array(session.utf8) + [0xFF]
        let h = SipHash13.hash(bytes)
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Does this remote leave exactly this trace?
    public static func left(_ trace: (prefix: String, hash: String), _ r: RemoteSession) -> Bool {
        String(sanitized(r.target).prefix(8)) == trace.prefix && socketHash(target: r.target, session: r.session) == trace.hash
    }

    /// Targets to try for a trace nothing remembered: every host in ~/.ssh/config (its aliases and HostName), with
    /// and without its User, and each short name in every domain a known target uses (black.follow-rankine.ts.net
    /// teaches follow-rankine.ts.net, which finds nat@white.follow-rankine.ts.net).
    public static func candidates(sshConfig: String, knownTargets: [String]) -> [String] {
        var hosts: [(names: [String], user: String?)] = []
        for raw in sshConfig.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count >= 2 else { continue }
            switch parts[0].lowercased() {
            case "host": hosts.append((parts.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }, nil))
            case "hostname": if !hosts.isEmpty { hosts[hosts.count - 1].names.append(parts[1]) }
            case "user": if !hosts.isEmpty { hosts[hosts.count - 1].user = parts[1] }
            default: break
            }
        }
        let domains = Set(knownTargets.compactMap { t -> String? in
            let host = t.split(separator: "@").last.map(String.init) ?? t
            guard let dot = host.firstIndex(of: ".") else { return nil }
            return String(host[host.index(after: dot)...])
        })
        let users = Set(hosts.compactMap(\.user) + knownTargets.compactMap { t in t.contains("@") ? String(t.split(separator: "@")[0]) : nil })
        var out: [String] = []
        for h in hosts {
            var names = h.names
            for n in h.names where !n.contains(".") { names += domains.map { n + "." + $0 } }
            for n in names {
                out.append(n)
                for u in Set([h.user].compactMap { $0 } + users) { out.append(u + "@" + n) }
            }
        }
        return Array(Set(out)).sorted()
    }

    /// What a probe printed: `herdr --version`, then `herdr --session <s> agent list` (JSON), then `herdr-rc=<n>`.
    public static func probe(_ out: String, at: Date = Date()) -> RemoteState {
        let version = out.split(separator: "\n").first { $0.hasPrefix("herdr ") }.map { String($0.dropFirst(6)) }
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
              let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return RemoteState(running: false, version: version,
                               problem: version == nil ? "no herdr on the remote PATH (~/.local/bin, /opt/homebrew/bin, /usr/local/bin)" : "herdr answered nothing", checked: at)
        }
        if let e = o["error"] as? [String: Any] {
            let stopped = (e["code"] as? String) == "server_not_running"
            return RemoteState(running: false, version: version, problem: stopped ? nil : (e["message"] as? String), checked: at)
        }
        let agents = ((o["result"] as? [String: Any])?["agents"] as? [[String: Any]]) ?? []
        let status = agents.map { ($0["agent_status"] as? String) ?? ($0["status"] as? String) ?? "" }
        return RemoteState(running: true, agents: agents.count, working: status.filter { $0 == "working" }.count,
                           needsYou: status.filter { $0 == "blocked" || $0 == "done" }.count, version: version, checked: at)
    }

    static let remotePath = "export PATH=$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; "

    /// A machine's first probe: its herdr and every session it has (`herdr session list --json`).
    public static func listCommand() -> String {
        remotePath + "herdr --version 2>/dev/null | head -1; herdr session list --json 2>/dev/null; echo herdr-rc=$?"
    }

    /// The second: the agents of each running session. Only ever built from safe session names.
    public static func agentsCommand(sessions: [String]) -> String {
        remotePath + sessions.map { "echo @@session \($0); herdr --session \($0) agent list 2>/dev/null" }.joined(separator: "; ")
    }

    /// What `listCommand` printed → herdr's version and the machine's sessions (name, running); nil without herdr.
    public static func machine(_ out: String) -> (version: String?, sessions: [(name: String, running: Bool)])? {
        let version = out.split(separator: "\n").first { $0.hasPrefix("herdr ") }.map { String($0.dropFirst(6)) }
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
              let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let list = o["sessions"] as? [[String: Any]] else {
            if version == nil { return nil }
            return (version: version, sessions: [])
        }
        var sessions: [(name: String, running: Bool)] = []
        for s in list { if let n = s["name"] as? String { sessions.append((name: n, running: s["running"] as? Bool ?? false)) } }
        return (version: version, sessions: sessions)
    }

    /// What `agentsCommand` printed → each session's state.
    public static func agents(_ out: String, version: String? = nil, at: Date = Date()) -> [String: RemoteState] {
        var states: [String: RemoteState] = [:]
        var current: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("@@session ") { current = String(line.dropFirst(10)); continue }
            guard let s = current, line.hasPrefix("{") else { continue }
            var st = probe(String(line), at: at); st.version = version
            states[s] = st
            current = nil
        }
        return states
    }

    /// Machines for the sidebar: every remote session known, grouped by host, the hosts and their sessions in name
    /// order; running sessions first within a host.
    public static func groups(_ remotes: [RemoteSession], running: (RemoteSession) -> Bool) -> [(host: String, sessions: [RemoteSession])] {
        let byHost = Dictionary(grouping: remotes) { $0.host }
        var out: [(host: String, sessions: [RemoteSession])] = []
        for host in byHost.keys.sorted() {
            let sorted = (byHost[host] ?? []).sorted { a, b in
                let ra = running(a) ? 0 : 1, rb = running(b) ? 0 : 1
                if ra != rb { return ra < rb }
                if a.session != b.session { return a.session < b.session }
                return a.target < b.target
            }
            out.append((host: host, sessions: sorted))
        }
        return out
    }
}

/// SipHash-1-3 (Rust's DefaultHasher), for herdr's socket names.
enum SipHash13 {
    static func hash(_ data: [UInt8], k0: UInt64 = 0, k1: UInt64 = 0) -> UInt64 {
        var v0: UInt64 = k0 ^ 0x736f6d6570736575, v1: UInt64 = k1 ^ 0x646f72616e646f6d
        var v2: UInt64 = k0 ^ 0x6c7967656e657261, v3: UInt64 = k1 ^ 0x7465646279746573
        func rotl(_ x: UInt64, _ b: UInt64) -> UInt64 { (x << b) | (x >> (64 - b)) }
        func round() {
            v0 &+= v1; v1 = rotl(v1, 13); v1 ^= v0; v0 = rotl(v0, 32)
            v2 &+= v3; v3 = rotl(v3, 16); v3 ^= v2
            v0 &+= v3; v3 = rotl(v3, 21); v3 ^= v0
            v2 &+= v1; v1 = rotl(v1, 17); v1 ^= v2; v2 = rotl(v2, 32)
        }
        let n = data.count, end = n - n % 8
        var i = 0
        while i < end {
            var m: UInt64 = 0
            for j in 0..<8 { m |= UInt64(data[i + j]) << (8 * UInt64(j)) }
            v3 ^= m; round(); v0 ^= m
            i += 8
        }
        var b = UInt64(n & 0xff) << 56
        for (j, c) in data[end...].enumerated() { b |= UInt64(c) << (8 * UInt64(j)) }
        v3 ^= b; round(); v0 ^= b
        v2 ^= 0xff
        round(); round(); round()
        return v0 ^ v1 ^ v2 ^ v3
    }
}

/// The hub's own list of remote sessions: ~/Library/Application Support/ARRA Oracles/remotes.json.
public enum RemoteRegistry {
    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles/remotes.json")
    }
    public static func load(from url: URL = file) -> [RemoteSession] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteSession].self, from: d)) ?? []
    }
    public static func save(_ list: [RemoteSession], to url: URL = file) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(list) { try? d.write(to: url, options: .atomic) }
    }
}
