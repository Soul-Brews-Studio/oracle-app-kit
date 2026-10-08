import Foundation

public struct HubSession: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let running: Bool
    /// herdr's default session: its folder is herdr's own config folder (~/.config/herdr), never deleted here
    public var isDefault = false
    /// the session's folder (`session_dir`): session.json (its saved spaces), logs, config
    public var dir: String?
}

public struct HubSpace: Identifiable, Hashable, Sendable {
    public var id: String { session + ":" + spaceId }
    public let session: String
    public let spaceId: String
    public let label: String
    public let number: Int
    public let status: String       // working · done · blocked · idle · unknown
    public let repo: String?
    public let checkout: String?
    public let linked: Bool
    public let panes: Int
    public let agents: Int
    public var branch: String? = nil    // the checkout's git branch, as herdr's sidebar shows under the name
}

/// One repo herdr knows about: its live spaces, its worktrees by state, the way back in.
public struct HubOracle: Identifiable, Hashable, Sendable {
    public var id: String { repo }
    public let repo: String
    public let spaces: [HubSpace]
    public let running: Int, open: Int, resumable: Int, cold: Int
    public let checkout: String?
    public let resume: String?
    public var name: String { HubParse.displayName(repo) }
    public var appKey: String { HubParse.appKey(forRepo: repo) }
    public var isLive: Bool { !spaces.isEmpty }
    /// The most urgent state across its spaces; with no space open, how it rests.
    public var status: String {
        if let s = spaces.map(\.status).min(by: { HubParse.rank($0) < HubParse.rank($1) }) { return s }
        return resumable > 0 ? "resumable" : "cold"
    }
}

public enum HubParse {
    public static func rank(_ s: String) -> Int { ["blocked": 0, "done": 1, "working": 2, "idle": 3][s] ?? 4 }

    public static func word(_ s: String) -> String {
        ["blocked": "blocked", "done": "needs you", "working": "working", "idle": "idle",
         "resumable": "resumable", "cold": "cold"][s] ?? "open"
    }

    /// The key an oracle's app carries in its bundle id, co.laris.oracle.<key>: the display name lower-cased, with "_"
    /// and "." made "-" because a bundle id has no "_" ("boon_v2-oracle" → "boon-v2"). scripts/new-oracle-app.sh and
    /// skills/oracle-app/check.sh apply the same rule; change all three together.
    public static func appKey(forRepo repo: String) -> String {
        String(displayName(repo).lowercased().map { $0 == "_" || $0 == "." ? "-" : $0 })
    }

    /// "neo-oracle" → "Neo", "DustBoy-Phd-Oracle" → "DustBoy-Phd", "pulse" → "Pulse"
    public static func displayName(_ repo: String) -> String {
        var s = repo
        if s.lowercased().hasSuffix("-oracle") { s.removeLast(7) }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// `herdr session list --json` → every session and whether its server is running.
    public static func sessions(_ data: Data) -> [HubSession] {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (d["sessions"] as? [[String: Any]] ?? []).compactMap { s in
            (s["name"] as? String).map { HubSession(name: $0, running: s["running"] as? Bool ?? false,
                                                    isDefault: s["default"] as? Bool ?? false, dir: s["session_dir"] as? String) }
        }
    }

    /// maw's oracle registry (`~/.maw/oracles.json`, what `maw locate` reads): one row per oracle repo,
    /// minus junk rows (a name that starts with "-") and repeats of the same repo.
    public static func registry(_ data: Data) -> [(repo: String, path: String?)] {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var seen = Set<String>(), out: [(repo: String, path: String?)] = []
        for o in d["oracles"] as? [[String: Any]] ?? [] {
            guard let name = o["name"] as? String, !name.hasPrefix("-") else { continue }
            let repo = o["repo"] as? String ?? name
            if seen.insert(repo.lowercased()).inserted { out.append((repo, o["local_path"] as? String)) }
        }
        return out
    }

    /// `maw herdr ls --json` → every space, and one oracle per repo with its spaces and worktree counts.
    public static func parse(ls: Data) -> (spaces: [HubSpace], oracles: [HubOracle]) {
        guard let d = try? JSONSerialization.jsonObject(with: ls) as? [String: Any] else { return ([], []) }
        var branchOf: [String: String] = [:]   // checkout path -> branch, from the worktree rows
        for t in d["worktrees"] as? [[String: Any]] ?? [] {
            if let p = t["path"] as? String, let b = t["branch"] as? String { branchOf[p] = b }
        }
        let spaces: [HubSpace] = (d["workspaces"] as? [[String: Any]] ?? []).compactMap { w in
            guard let s = w["session"] as? String, let id = w["id"] as? String else { return nil }
            return HubSpace(session: s, spaceId: id, label: w["label"] as? String ?? id, number: w["number"] as? Int ?? 0,
                            status: w["status"] as? String ?? "unknown", repo: w["repo"] as? String,
                            checkout: w["checkout"] as? String, linked: w["linked"] as? Bool ?? false,
                            panes: w["panes"] as? Int ?? 0, agents: w["agents"] as? Int ?? 0,
                            branch: (w["checkout"] as? String).flatMap { branchOf[$0] })
        }
        var byRepo: [String: [[String: Any]]] = [:]
        for t in d["worktrees"] as? [[String: Any]] ?? [] {
            if let r = t["repo"] as? String { byRepo[r, default: []].append(t) }
        }
        for s in spaces { if let r = s.repo, byRepo[r] == nil { byRepo[r] = [] } }
        let oracles: [HubOracle] = byRepo.map { repo, wts in
            func count(_ state: String) -> Int { wts.filter { ($0["state"] as? String) == state }.count }
            let main = wts.first { ($0["linked"] as? Bool) == false } ?? wts.first
            var resume: String?
            if let r = main?["resume"] as? [String: Any], let id = r["id"] as? String, let path = main?["path"] as? String {
                resume = "cd '\(path)' && " + ((r["provider"] as? String) == "codex" ? "codex resume \(id)" : "claude --resume \(id)")
            }
            return HubOracle(repo: repo, spaces: spaces.filter { $0.repo == repo },
                             running: count("running"), open: count("open"), resumable: count("resumable"), cold: count("cold"),
                             checkout: main?["repoRoot"] as? String ?? main?["path"] as? String, resume: resume)
        }
        return (spaces, oracles.sorted(by: order))
    }

    /// Urgent first (blocked, needs you, working, idle), then the resting ones; by name inside.
    static func order(_ a: HubOracle, _ b: HubOracle) -> Bool {
        let ra = rank(a.status), rb = rank(b.status)
        if ra != rb { return ra < rb }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    #if os(macOS)
    /// Oracle apps on this Mac by the key in their bundle id, co.laris.oracle.<key> (this app excluded).
    public static func installedApps() -> [String: URL] {
        var out: [String: URL] = [:]
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix("co.laris.oracle.") else { continue }
                let key = String(id.dropFirst("co.laris.oracle.".count))
                if key != "hub", !key.contains(".") { out[key] = url }
            }
        }
        return out
    }
    #endif
}
