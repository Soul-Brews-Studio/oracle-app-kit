#if os(macOS)
import Foundation

/// How a remote agent was started, as its machine's process table says: its folder and its whole command line.
/// Nat: "it start with this command, the important thing is …" — xiaoer only hears Discord when started with
/// `claude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions`, and herdr's own
/// resume runs plain `claude --resume <id>` (herdr 0.9.1 src/agent_resume.rs). So the hub keeps the command it saw and
/// runs it again after Start / Restart.
public struct AgentLaunch: Codable, Hashable, Sendable {
    public let cwd: String
    public let command: String
    public var seen: Date
}

/// RemoteSession.id → its agents' launches, kept in ~/Library/Application Support/ARRA Oracles/launches.json.
public enum LaunchMemory {
    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles/launches.json")
    }
    public static func load(from url: URL = file) -> [String: [AgentLaunch]] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [AgentLaunch]].self, from: d)) ?? [:]
    }
    public static func save(_ all: [String: [AgentLaunch]], to url: URL = file) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(all).write(to: url, options: .atomic)
    }
}

extension HubStore {
    /// Each saved login's running agents (claude, codex) with their folder and command, read over ssh as that login,
    /// kept per session for the folders its agents run in. The newest command for a folder replaces the older one.
    func recordLaunches() async {
        let targets = Array(Set(remotes.filter(\.isSafe).map(\.target)))
        let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]
        var seen: [String: [AgentLaunch]] = [:]
        await withTaskGroup(of: (String, [AgentLaunch]).self) { g in
            for t in targets {
                g.addTask { (t, await Shell.run("ssh", ssh + [t, RemoteParse.launchesCommand + "; true"], timeout: 15).map { RemoteParse.launches($0) } ?? []) }
            }
            for await (t, list) in g { seen[t] = list }
        }
        var memory = launches
        for r in remotes {
            guard let st = remoteState[r.id], st.running, let found = seen[r.target] else { continue }
            let cwds = Set(st.agentList.map(\.cwd))
            let mine = found.filter { cwds.contains($0.cwd) }
            guard !mine.isEmpty else { continue }
            memory[r.id] = ((memory[r.id] ?? []).filter { old in !mine.contains { $0.cwd == old.cwd } } + mine).sorted { $0.cwd < $1.cwd }
        }
        if memory != launches { launches = memory; LaunchMemory.save(memory) }
    }

    /// After Start / Restart: run each remembered command again, in the pane herdr restored in that folder with no agent
    /// in it. nil when every one ran, else the commands to run by hand.
    func relaunch(_ r: RemoteSession) async -> String? {
        let remembered = launches[r.id] ?? []
        guard !remembered.isEmpty else { return nil }
        let via = remoteState[r.id]?.viaSSH == true
        var panes: [[String: Any]] = []
        for _ in 0..<6 {   // herdr restores the workspaces as the server starts; give it a moment to list them
            if let out = await Self.remoteHerdr(r, ["pane", "list"], viaSSH: via), out.status == 0,
               let o = try? JSONSerialization.jsonObject(with: Data(out.out.utf8)) as? [String: Any],
               let list = (o["result"] as? [String: Any])?["panes"] as? [[String: Any]], !list.isEmpty { panes = list; break }
            try? await Task.sleep(for: .seconds(1))
        }
        var failed: [String] = []
        for l in remembered {
            let free = panes.first { ($0["cwd"] as? String) == l.cwd && ($0["agent"] as? String) == nil }
            guard let pane = free?["pane_id"] as? String, pane.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) else {
                if !panes.contains(where: { ($0["cwd"] as? String) == l.cwd && $0["agent"] is String }) {
                    failed.append("ssh -t \(r.target) 'cd \(l.cwd) && \(l.command)'")
                }
                continue   // an agent already runs there (herdr resumed it): nothing to do
            }
            if await Self.remoteHerdr(r, ["pane", "run", pane, RemoteParse.shellQuote(l.command)], viaSSH: via)?.status != 0 {
                failed.append("herdr --session \(r.session) pane run \(pane) \(RemoteParse.shellQuote(l.command))")
            }
        }
        await refresh(remotes: true)
        return failed.isEmpty ? nil : "Started; run these again by hand:\n  " + failed.joined(separator: "\n  ")
    }
}
#endif
