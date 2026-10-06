import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Oracles (the landing app): every herdr session, every space, every oracle — a click opens its app.
// Data: `herdr session list` (all sessions, running or stopped) + `maw herdr ls --json` (spaces and
// worktrees of every running session, ~0.4 s) + the oracle apps installed on this Mac (co.laris.oracle.<key>).

public struct HubSession: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let running: Bool
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
    public var appKey: String { name.lowercased() }
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
            (s["name"] as? String).map { HubSession(name: $0, running: s["running"] as? Bool ?? false) }
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
        let spaces: [HubSpace] = (d["workspaces"] as? [[String: Any]] ?? []).compactMap { w in
            guard let s = w["session"] as? String, let id = w["id"] as? String else { return nil }
            return HubSpace(session: s, spaceId: id, label: w["label"] as? String ?? id, number: w["number"] as? Int ?? 0,
                            status: w["status"] as? String ?? "unknown", repo: w["repo"] as? String,
                            checkout: w["checkout"] as? String, linked: w["linked"] as? Bool ?? false,
                            panes: w["panes"] as? Int ?? 0, agents: w["agents"] as? Int ?? 0)
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

@MainActor
public final class HubStore: ObservableObject {
    @Published public private(set) var sessions: [HubSession] = []
    @Published public private(set) var spaces: [HubSpace] = []
    @Published public private(set) var oracles: [HubOracle] = []
    @Published public private(set) var apps: [String: URL] = [:]
    /// Oracles in maw's registry that herdr has never seen — listed last, folded.
    @Published public private(set) var registryOnly: [HubOracle] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var problems: [String] = []
    private var timer: Timer?

    /// Starts refreshing at once: the menu-bar item must have data even when no window is open.
    public init() { start() }

    /// Safe to call again (the window calls it on appear): only the first call starts the clock.
    public func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    public func refresh() async {
        #if os(macOS)
        async let table = Shell.run("herdr", ["session", "list", "--json"])
        async let ls = Shell.run("maw", ["herdr", "ls", "--json"], timeout: 15)
        let (t, l) = await (table, ls)
        var issues: [String] = []
        if let t { sessions = HubParse.sessions(Data(t.utf8)) } else { issues.append("herdr is not answering — run: herdr session list --json") }
        if let l {
            let p = HubParse.parse(ls: Data(l.utf8))
            spaces = p.spaces; oracles = p.oracles
        } else {
            issues.append("maw herdr ls failed — run: maw herdr ls --json")
        }
        apps = HubParse.installedApps()
        let reg = (try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.maw/oracles.json"))).map(HubParse.registry) ?? []
        let known = Set(oracles.map { $0.repo.lowercased() })
        registryOnly = reg.filter { !known.contains($0.repo.lowercased()) }
            .map { HubOracle(repo: $0.repo, spaces: [], running: 0, open: 0, resumable: 0, cold: 0, checkout: $0.path, resume: nil) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        problems = issues
        lastRefresh = Date()
        #endif
    }

    /// Oracles that have an app, in name order — shown first, live or not.
    public var appOracles: [HubOracle] {
        apps.keys.sorted().map { key in
            oracles.first { $0.appKey == key }
                ?? HubOracle(repo: key, spaces: [], running: 0, open: 0, resumable: 0, cold: 0, checkout: nil, resume: nil)
        }
    }

    #if os(macOS)
    public func openApp(_ key: String) {
        guard let url = apps[key] else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Focus the space in herdr, then bring forward the WezTerm pane whose herdr client shows that session
    /// (a new WezTerm window attached to it when none does).
    public func showInHerdr(_ s: HubSpace) {
        Task.detached {
            _ = await Shell.run("herdr", ["--session", s.session, "workspace", "focus", s.spaceId])
            await WezTerm.show(session: s.session, label: s.label)
        }
    }

    /// A whole session: its WezTerm client, or a new one — which also starts a stopped session.
    public func openSession(_ name: String) {
        Task.detached { await WezTerm.show(session: name) }
    }
    #endif
}

#if os(macOS)
/// WezTerm hosts the herdr clients. Its CLI finds the pane that runs `herdr [--session S]` and brings it forward.
public enum WezTerm {
    public static let bundleId = "com.github.wez.wezterm"

    /// Go to the session the way Window Arranger's ⏎ does: herdr retitles its client "<host>: <space>" after the
    /// focus, and yabai focuses that WezTerm window — switching Space and display. Without a match (no yabai, the
    /// title not updated yet), the WezTerm CLI path: activate the session's client pane, or open one.
    public static func show(session: String, label: String? = nil) async {
        if let label, Shell.which("yabai") != nil {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let id = await yabaiWindow(titled: label) {
                _ = await Shell.run("yabai", ["-m", "window", String(id), "--focus"])
                return
            }
        }
        if let pane = await panes(running: session).first {
            _ = await Shell.run("wezterm", ["cli", "activate-pane", "--pane-id", String(pane)])
        } else {
            var args = ["cli", "spawn", "--new-window", "--", Shell.which("herdr") ?? "herdr"]
            if session != "default" { args += ["--session", session] }
            _ = await Shell.run("wezterm", args)
        }
        await MainActor.run { _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate() }
    }

    /// The yabai id of a WezTerm window whose title is herdr's "<host>: <label>" (or the bare label).
    static func yabaiWindow(titled label: String) async -> Int? {
        guard let json = await Shell.run("yabai", ["-m", "query", "--windows"]),
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return nil }
        return list.first { w in
            guard (w["app"] as? String) == "WezTerm", let t = w["title"] as? String else { return false }
            return t == label || t.hasSuffix(": " + label)
        }?["id"] as? Int
    }

    /// WezTerm pane ids whose terminal runs a local herdr client attached to `session`.
    public static func panes(running session: String) async -> [Int] {
        guard let json = await Shell.run("wezterm", ["cli", "list", "--format", "json"]),
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        var out: [Int] = []
        for p in list {
            guard let id = p["pane_id"] as? Int, let tty = (p["tty_name"] as? String)?.replacingOccurrences(of: "/dev/", with: "") else { continue }
            let ps = await Shell.run("ps", ["-o", "args=", "-t", tty]) ?? ""
            if ps.split(separator: "\n").contains(where: { herdrSession(of: String($0)) == session }) { out.append(id) }
        }
        return out
    }

    /// "herdr --session ccdc" → "ccdc", a bare "herdr" → "default"; remote clients and one-shot CLI calls → nil.
    public static func herdrSession(of args: String) -> String? {
        let f = args.split(separator: " ").map(String.init)
        guard let first = f.first, (first as NSString).lastPathComponent == "herdr", !f.contains("--remote") else { return nil }
        if let i = f.firstIndex(of: "--session"), i + 1 < f.count { return f.count == i + 2 ? f[i + 1] : nil }
        return f.count == 1 ? "default" : nil
    }
}
#endif
