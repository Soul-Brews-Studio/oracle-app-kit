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
    public var repo: String? = nil       // the space's repo, as maw names it
    public var linked: Bool? = nil       // a worktree space hanging under its repo's main space
    public var group: UUID? = nil        // closed together with its main space (`workspace close --group`)
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

    /// Run herdr and keep its JSON either way: on failure herdr prints `{"error":{"code","message"}}`, which
    /// `Shell.run` drops. ok = exit 0.
    static func herdr(_ args: [String], timeout: TimeInterval = 20) async -> (ok: Bool, json: [String: Any]?) {
        guard let path = Shell.which("herdr") else { return (false, ["error": ["message": "herdr not found on PATH"]]) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); let out = Pipe()
                p.executableURL = URL(fileURLWithPath: path); p.arguments = args
                p.standardOutput = out; p.standardError = out
                do { try p.run() } catch { cont.resume(returning: (false, nil)); return }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                cont.resume(returning: (p.terminationStatus == 0, json))
            }
        }
    }

    /// herdr's own words for a failed call.
    static func reason(_ json: [String: Any]?) -> String {
        ((json?["error"] as? [String: Any])?["message"] as? String) ?? "no answer from herdr"
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

    /// Save the space (and, for a repo's main space, every worktree space under it), then close it — with
    /// `--group` when children hang under it, since herdr refuses a plain close then. Records are written
    /// first, so a failed close leaves nothing lost. nil when closed; otherwise herdr's reason and the command.
    public func closeSpace(_ s: HubSpace, children: [HubSpace], agents: [String: [ClosedAgent]]) async -> String? {
        let group = children.isEmpty ? nil : UUID()
        var recs: [ClosedSpace] = []
        for sp in [s] + children {
            let cwd = await firstPane(session: sp.session, workspace: sp.spaceId)?.cwd ?? sp.checkout ?? NSHomeDirectory()
            recs.append(ClosedSpace(id: UUID(), session: sp.session, label: sp.label, cwd: cwd, closedAt: Date(),
                                    agents: agents[sp.id] ?? [], repo: sp.repo, linked: sp.linked, group: group))
        }
        let before = ClosedSpaces.load()
        ClosedSpaces.save(recs + before)
        var args = ["--session", s.session, "workspace", "close", s.spaceId]
        if !children.isEmpty { args.append("--group") }
        let r = await ClosedSpaces.herdr(args)
        if !r.ok { ClosedSpaces.save(before) }
        await refresh()
        return r.ok ? nil : "herdr: \(ClosedSpaces.reason(r.json)) — run:  herdr " + args.joined(separator: " ")
    }

    /// Recreate the space at its cwd, one pane per agent, each agent started resumed. The record is dropped only
    /// when every resumable agent came back. nil when done; otherwise what failed and the command to run.
    public func reopen(_ c: ClosedSpace) async -> String? {
        // A worktree space goes back under its repo's main space; anything else is a plain space at its cwd.
        var args = ["--session", c.session, "workspace", "create", "--cwd", c.cwd, "--label", c.label, "--no-focus"]
        if c.linked == true {
            guard let parent = spaces.first(where: { $0.session == c.session && !$0.linked && $0.repo != nil && $0.repo == c.repo }) else {
                return "reopen the main space of \(c.repo ?? "its repo") first — \(c.label) is a worktree under it"
            }
            args = ["--session", c.session, "worktree", "open", "--workspace", parent.spaceId, "--path", c.cwd, "--label", c.label, "--no-focus"]
        }
        let r = await ClosedSpaces.herdr(args)
        let result = r.json?["result"] as? [String: Any]
        guard r.ok, let ws = (result?["workspace"] as? [String: Any])?["workspace_id"] as? String else {
            return "herdr: \(ClosedSpaces.reason(r.json)) — run:  herdr " + args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        }
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
