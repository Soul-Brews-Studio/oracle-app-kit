import Foundation

// MARK: - Where an oracle lives in herdr, running or stopped (#116)
//
// After a reboot only herdr's `default` session comes back; every other session stays stopped, and `maw herdr ls`
// (running sessions only) then shows nothing for an oracle whose spaces lived there. A stopped session still keeps
// its spaces in `<session_dir>/session.json`: each workspace's `identity_cwd`, every pane's `cwd`, and the
// `agent_session` herdr 0.9.1 resumes when the server starts again. Reading that file says where the oracle lives,
// when the session stopped (the file's mtime), and which saved agents are already live in another pane: starting
// such a session as-is would open one conversation twice (two writers on one transcript).

/// An agent herdr saved in a stopped session and would resume when it starts.
public struct SavedAgent: Equatable, Hashable, Sendable {
    public let name: String        // herdr agent_name ("neo-recap"), "" when unnamed
    public let agent: String       // "claude" / "codex"
    public let sessionId: String   // agent_session.value — the conversation id
    public let space: String       // the space it was saved in
    public var cwd: String = ""    // its pane's folder: where a per-oracle Resume opens it again
}

/// One space a stopped session saved: its name, folder, panes and the agents herdr would resume.
public struct SavedSpace: Identifiable, Equatable, Sendable {
    public var id: String { label + "|" + cwd }
    public let label: String
    public let cwd: String
    public let panes: Int
    public let agents: [SavedAgent]
}

/// One herdr session that holds spaces in the oracle's repo.
public struct SessionPlace: Identifiable, Equatable, Sendable {
    public var id: String { session }
    public let session: String
    public let running: Bool
    /// session.json's mtime: for a stopped session, when it stopped
    public let savedAt: Date?
    public let spaces: [String]
    public let agents: [SavedAgent]
    /// saved agents whose conversation is live right now in another pane (stopped sessions only)
    public var alreadyLive: [SavedAgent] = []
    /// the session's folder (session.json lives there): what a whole-session Start rewrites before starting
    public var dir: String? = nil
}

public enum HerdrPlaces {
    /// A folder belongs when it is one of `roots` or under one. `roots == nil` takes every folder.
    public static func belongs(_ cwd: String?, roots: [String]?) -> Bool {
        guard let c = cwd, !c.isEmpty else { return false }
        guard let roots else { return true }
        return roots.contains { c == $0 || c.hasPrefix($0 + "/") }
    }

    /// One session.json → the spaces that belong (their custom name, else the folder's name) and the agents saved in them.
    public static func parse(sessionJSON data: Data, roots: [String]?) -> (spaces: [String], agents: [SavedAgent]) {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        var spaces: [String] = [], agents: [SavedAgent] = []
        for w in d["workspaces"] as? [[String: Any]] ?? [] {
            let panes = (w["tabs"] as? [[String: Any]] ?? [])
                .flatMap { ($0["panes"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.compactMap { $0.value as? [String: Any] } }
            let cwds = [w["identity_cwd"] as? String] + panes.map { $0["cwd"] as? String }
            guard cwds.contains(where: { belongs($0, roots: roots) }) else { continue }
            let custom = (w["custom_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = custom ?? ((w["identity_cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?")
            spaces.append(label)
            for p in panes {
                guard let s = p["agent_session"] as? [String: Any], let id = s["value"] as? String, !id.isEmpty else { continue }
                agents.append(SavedAgent(name: p["agent_name"] as? String ?? "", agent: s["agent"] as? String ?? "",
                                         sessionId: id, space: label, cwd: p["cwd"] as? String ?? ""))
            }
        }
        return (spaces, agents)
    }

    /// Every space a session.json saved, with its folder, pane count and the agents it would resume — what a stopped
    /// session holds, for the hub's page of that session.
    public static func savedSpaces(sessionJSON data: Data) -> [SavedSpace] {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (d["workspaces"] as? [[String: Any]] ?? []).map { w in
            let panes = (w["tabs"] as? [[String: Any]] ?? [])
                .flatMap { ($0["panes"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.compactMap { $0.value as? [String: Any] } }
            let cwd = w["identity_cwd"] as? String ?? (panes.first?["cwd"] as? String ?? "")
            let custom = (w["custom_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = custom ?? (cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent)
            let agents = panes.compactMap { p -> SavedAgent? in
                guard let s = p["agent_session"] as? [String: Any], let id = s["value"] as? String, !id.isEmpty else { return nil }
                return SavedAgent(name: p["agent_name"] as? String ?? "", agent: s["agent"] as? String ?? "", sessionId: id, space: label,
                                  cwd: p["cwd"] as? String ?? "")
            }
            return SavedSpace(label: label, cwd: cwd, panes: panes.count, agents: agents)
        }
    }

    /// The conversation ids live now in one `herdr --session S agent list` answer.
    public static func liveIds(agentList data: Data) -> Set<String> {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = d["result"] as? [String: Any] else { return [] }
        return Set((r["agents"] as? [[String: Any]] ?? []).compactMap { ($0["agent_session"] as? [String: Any])?["value"] as? String })
    }

    /// The saved agents whose conversation is already live elsewhere.
    public static func duplicates(_ saved: [SavedAgent], live: Set<String>) -> [SavedAgent] {
        saved.filter { live.contains($0.sessionId) }
    }

    /// What an oracle's Resume brings back from a stopped session: its saved agents that are not live anywhere.
    /// Empty once every one of them runs again (the button hides: "if started, hide").
    public static func toResume(_ p: SessionPlace) -> [SavedAgent] {
        guard !p.running else { return [] }
        let live = Set(p.alreadyLive.map(\.sessionId))
        return p.agents.filter { !live.contains($0.sessionId) }
    }

    /// Where Resume opens them: the running session that already holds this repo's spaces, else herdr's `default`.
    public static func resumeTarget(_ places: [SessionPlace]) -> String {
        places.first(where: \.running)?.session ?? "default"
    }

    /// session.json with these conversations' records cleared (`agent_session`, `agent_name`): their panes come back as
    /// plain shells when the server starts, so a conversation already live elsewhere is never resumed a second time.
    /// Everything else is kept. nil when the data is not a session.json.
    public static func clearingAgents(sessionJSON data: Data, ids: Set<String>) -> Data? {
        guard var d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var ws = d["workspaces"] as? [[String: Any]] else { return nil }
        for wi in ws.indices {
            var tabs = ws[wi]["tabs"] as? [[String: Any]] ?? []
            for ti in tabs.indices {
                var panes = tabs[ti]["panes"] as? [String: Any] ?? [:]
                for (key, value) in panes {
                    guard var p = value as? [String: Any], let s = p["agent_session"] as? [String: Any],
                          let id = s["value"] as? String, ids.contains(id) else { continue }
                    p.removeValue(forKey: "agent_session"); p.removeValue(forKey: "agent_name")
                    panes[key] = p
                }
                tabs[ti]["panes"] = panes
            }
            ws[wi]["tabs"] = tabs
        }
        d["workspaces"] = ws
        return try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
    }

    /// The stopped sessions that were running when the Mac went down: herdr writes session.json as its server exits,
    /// so their file is dated in the `window` before boot (a minute of slack after it). One stopped days ago stays stopped.
    public static func runningAtShutdown(stopped savedAt: [String: Date], boot: Date, window: TimeInterval = 15 * 60) -> [String] {
        savedAt.filter { $0.value >= boot.addingTimeInterval(-window) && $0.value <= boot.addingTimeInterval(60) }.keys.sorted()
    }

    /// "stopped since 07:25" (today) or "stopped since Oct 7".
    public static func stoppedSince(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "stopped" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "MMM d"
        return "stopped since " + f.string(from: d)
    }

    #if os(macOS)
    /// Every session holding the oracle's spaces: running ones first, then stopped ones with their saved agents and
    /// the ones of those already live. One `herdr session list` + one `agent list` per running session + the files.
    public static func load(roots: [String]) async -> [SessionPlace] {
        guard let t = await Shell.run("herdr", ["session", "list", "--json"]) else { return [] }
        let sessions = HubParse.sessions(Data(t.utf8))
        let live = await liveNow(sessions)
        var out: [SessionPlace] = []
        for s in sessions {
            guard let dir = s.dir, let data = FileManager.default.contents(atPath: dir + "/session.json") else { continue }
            let p = parse(sessionJSON: data, roots: roots)
            guard !p.spaces.isEmpty else { continue }
            var place = SessionPlace(session: s.name, running: s.running, savedAt: modified(dir + "/session.json"),
                                     spaces: p.spaces, agents: p.agents)
            place.dir = dir
            if !s.running { place.alreadyLive = duplicates(p.agents, live: live) }
            out.append(place)
        }
        return out.sorted { ($0.running ? 0 : 1, $0.session) < ($1.running ? 0 : 1, $1.session) }
    }

    /// Conversation ids live in every running session (herdr runs one server per session).
    static func liveNow(_ sessions: [HubSession]) async -> Set<String> {
        var live = Set<String>()
        for s in sessions where s.running {
            if let a = await Shell.run("herdr", ["--session", s.name, "agent", "list"]) { live.formUnion(liveIds(agentList: Data(a.utf8))) }
        }
        return live
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// When this Mac booted (`sysctl kern.boottime`).
    public static func bootTime() -> Date? {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// Start a stopped session in the background: a detached `herdr --session S server` (herdr has no `session start`);
    /// herdr relaunches each recorded agent resumed. nil once the server answers (≤10 s), else the command to run.
    public static func start(_ name: String) async -> String? {
        let cmd = "herdr --session \(name) server"
        guard let herdr = Shell.which("herdr") else { return "herdr not found — run:  \(cmd)" }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        _ = await Shell.run("sh", ["-c", "nohup \(q(herdr)) --session \(q(name)) server >/dev/null 2>&1 &"])
        for _ in 0..<20 {
            if await Shell.run("herdr", ["--session", name, "pane", "list"]) != nil { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "\(name) did not answer within 10 s — run:  \(cmd)"
    }

    /// Start a stopped session without resuming any conversation that is already live in another pane: copy its
    /// session.json to session.json.bak-<time>, clear those panes' records (they come back as plain shells), then start.
    /// Everything else herdr saved resumes. (Before: the whole session was held back, and 15 agents with it.)
    public static func startSkippingLive(name: String, dir: String?) async -> (error: String?, skipped: [SavedAgent], backup: String?) {
        guard let dir, let data = FileManager.default.contents(atPath: dir + "/session.json") else { return (await start(name), [], nil) }
        let sessions = HubParse.sessions(Data((await Shell.run("herdr", ["session", "list", "--json"]) ?? "").utf8))
        guard sessions.first(where: { $0.name == name })?.running != true else { return (nil, [], nil) }   // already up
        let skipped = duplicates(parse(sessionJSON: data, roots: nil).agents, live: await liveNow(sessions))
        var backup: String?
        if !skipped.isEmpty {
            let file = dir + "/session.json"
            guard let cleared = clearingAgents(sessionJSON: data, ids: Set(skipped.map(\.sessionId))) else {
                return ("could not read \(file) as a herdr session — run:  herdr --session \(name) server", skipped, nil)
            }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let bak = file + ".bak-" + f.string(from: Date())
            do {
                try data.write(to: URL(fileURLWithPath: bak))
                try cleared.write(to: URL(fileURLWithPath: file), options: .atomic)
            } catch {
                return ("could not back up and rewrite \(file) (\(error.localizedDescription)) — run:  herdr --session \(name) server", skipped, nil)
            }
            backup = bak
        }
        return (await start(name), skipped, backup)
    }

    /// One line for what a skipping start did: "laris-co started; skipped 2 already live: maeon-craft-oracle, neo-recap".
    public static func skippedNote(_ name: String, _ skipped: [SavedAgent], backup: String?) -> String? {
        guard !skipped.isEmpty else { return nil }
        let who = skipped.map { $0.name.isEmpty ? $0.space : $0.name }.joined(separator: ", ")
        return "\(name) started; skipped \(skipped.count) already live elsewhere: \(who)"
            + (backup.map { " (to undo: cp '\($0)' '\(($0 as NSString).deletingPathExtension)')" } ?? "")
    }
    #endif
}
