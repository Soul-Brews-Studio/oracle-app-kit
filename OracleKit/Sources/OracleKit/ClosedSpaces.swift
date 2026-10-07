#if os(macOS)
import Foundation

// MARK: - Close one space, reopen it later with its agents resumed.
// `herdr workspace close` drops the space from session.json, so herdr forgets its agents (a session stop keeps
// them). Before closing, the hub saves what herdr would have kept — cwd, label, each agent's kind and session
// id — and Reopen does what herdr does on a session reopen: same cwd, each agent started resumed.

public struct ClosedAgent: Codable, Hashable, Sendable {
    public let name: String
    public let kind: String          // claude · codex · …  (herdr's agent kind)
    public let sessionId: String?    // nil: the agent never reported one, so it cannot be resumed
}

public struct ClosedSpace: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let session: String
    public let label: String
    public let cwd: String
    public let closedAt: Date
    public let agents: [ClosedAgent]
}

public enum ClosedSpaces {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("closed-spaces.json")
    }

    public static func load() -> [ClosedSpace] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ClosedSpace].self, from: d)) ?? []
    }

    static func save(_ list: [ClosedSpace]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(list).write(to: url, options: .atomic)
    }

    /// The command that resumes one agent, as herdr's agent start takes it (nil: no resume for this kind).
    static func resumeArgs(_ a: ClosedAgent) -> [String]? {
        guard let id = a.sessionId else { return nil }
        switch a.kind {
        case "claude": return ["--resume", id]
        case "codex": return ["resume", id]
        default: return nil
        }
    }
}

extension HubStore {
    /// The agents in one space, read live: `herdr --session S agent list`, kept to that workspace.
    public func agents(in s: HubSpace) async -> [ClosedAgent]? {
        guard let out = await Shell.run("herdr", ["--session", s.session, "agent", "list"]),
              let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let list = (d["result"] as? [String: Any])?["agents"] as? [[String: Any]] else { return nil }
        return list.filter { ($0["workspace_id"] as? String) == s.spaceId }.map { a in
            ClosedAgent(name: a["name"] as? String ?? a["pane_id"] as? String ?? "agent",
                        kind: a["agent"] as? String ?? "agent",
                        sessionId: (a["agent_session"] as? [String: Any])?["value"] as? String)
        }
    }

    /// Save the space, then close it. The record is written first, so a failed close leaves nothing lost.
    /// nil when closed; otherwise the error with the command to run.
    public func closeSpace(_ s: HubSpace, agents: [ClosedAgent]) async -> String? {
        let cwd = await firstPane(session: s.session, workspace: s.spaceId)?.cwd ?? s.checkout ?? NSHomeDirectory()
        var list = ClosedSpaces.load()
        let rec = ClosedSpace(id: UUID(), session: s.session, label: s.label, cwd: cwd, closedAt: Date(), agents: agents)
        list.insert(rec, at: 0)
        ClosedSpaces.save(list)
        let ok = await Shell.run("herdr", ["--session", s.session, "workspace", "close", s.spaceId]) != nil
        if !ok { ClosedSpaces.save(list.filter { $0.id != rec.id }) }
        await refresh()
        return ok ? nil : "herdr could not close \(s.label) — run:  herdr --session \(s.session) workspace close \(s.spaceId)"
    }

    /// Recreate the space at its cwd, one pane per agent, each agent started resumed. The record is dropped only
    /// when every resumable agent came back. nil when done; otherwise what failed and the command to run.
    public func reopen(_ c: ClosedSpace) async -> String? {
        guard let out = await Shell.run("herdr", ["--session", c.session, "workspace", "create", "--cwd", c.cwd, "--label", c.label, "--no-focus"]),
              let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let ws = ((d["result"] as? [String: Any])?["workspace"] as? [String: Any])?["workspace_id"] as? String
        else { return "herdr could not open \(c.cwd) in \(c.session) — is the session running?  herdr --session \(c.session) workspace create --cwd '\(c.cwd)'" }
        var pane = await firstPane(session: c.session, workspace: ws)?.id
        var failed: [String] = []
        for (i, a) in c.agents.enumerated() {
            guard let args = ClosedSpaces.resumeArgs(a) else { continue }
            if i > 0, let p = pane {
                pane = await splitPane(session: c.session, pane: p, cwd: c.cwd)
            }
            guard let p = pane else { failed.append(a.name); continue }
            let started = await Shell.run("herdr", ["--session", c.session, "agent", "start", a.name, "--kind", a.kind, "--pane", p, "--"] + args,
                                          timeout: 90) != nil
            if !started { failed.append("\(a.name): herdr --session \(c.session) agent start \(a.name) --kind \(a.kind) --pane \(p) -- \(args.joined(separator: " "))") }
        }
        if failed.isEmpty { ClosedSpaces.save(ClosedSpaces.load().filter { $0.id != c.id }) }
        await refresh()
        return failed.isEmpty ? nil : "reopened \(c.label), but these did not start — " + failed.joined(separator: " · ")
    }

    /// Forget a closed space without reopening it.
    public func forget(_ c: ClosedSpace) {
        ClosedSpaces.save(ClosedSpaces.load().filter { $0.id != c.id })
        objectWillChange.send()
    }

    private func firstPane(session: String, workspace: String) async -> (id: String, cwd: String?)? {
        guard let out = await Shell.run("herdr", ["--session", session, "pane", "list", "--workspace", workspace]),
              let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let first = ((d["result"] as? [String: Any])?["panes"] as? [[String: Any]])?.first,
              let id = first["pane_id"] as? String else { return nil }
        return (id, first["cwd"] as? String)
    }

    private func splitPane(session: String, pane: String, cwd: String) async -> String? {
        guard let out = await Shell.run("herdr", ["--session", session, "pane", "split", pane, "--direction", "right", "--cwd", cwd, "--no-focus"]),
              let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return nil }
        return ((d["result"] as? [String: Any])?["pane"] as? [String: Any])?["pane_id"] as? String
    }
}
#endif
