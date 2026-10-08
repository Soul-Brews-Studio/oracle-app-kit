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

    /// The words of a command line (it came from /proc, space-joined; no word in these commands holds a space).
    static func words(_ command: String) -> [String] { command.split(separator: " ").map(String.init) }

    /// Its flags without the program and the conversation it picked: `--resume <id>`, `-r <id>`, `--continue`, `-c`,
    /// `--fork-session` dropped. phd: "--dangerously-skip-permissions --model claude-opus-5-5 --channels plugin:discord@…".
    public var flags: [String] {
        var out: [String] = [], skip = false
        for w in Self.words(command).dropFirst() {
            if skip { skip = false; continue }
            if w == "--resume" || w == "-r" { skip = true; continue }
            if ["--continue", "-c", "--fork-session"].contains(w) || w.hasPrefix("--resume=") { continue }
            out.append(w)
        }
        return out
    }

    /// The channels it listens on, short names (Nat: "which claude code of each session use which channels (can use
    /// multi channels)"): `--channels a`, `--channels a b`, `--channels a,b`, `--channels=a`, repeated or not.
    /// "plugin:discord@claude-plugins-official" → "discord"; "server:<mcp>" → its name.
    public var channels: [String] { Self.channels(in: command) }

    static func channels(in command: String) -> [String] {
        var out: [String] = [], collecting = false
        for w in words(command).dropFirst() {
            if w.hasPrefix("--channels=") { out += w.dropFirst(11).split(separator: ",").map(String.init); collecting = false; continue }
            if w == "--channels" { collecting = true; continue }
            if collecting, !w.hasPrefix("-") { out += w.split(separator: ",").map(String.init); continue }
            collecting = false
        }
        var seen = Set<String>()
        return out.map(channelName).filter { seen.insert($0).inserted }
    }

    /// What its command says worth a glance, in order: channels, model, permission bypass, the conversation it picked
    /// (Nat: "if you know params should show params").
    public var params: [LaunchParam] {
        let w = Self.words(command)
        var out = channels.map { LaunchParam(text: $0, kind: .channel) }
        if let i = w.firstIndex(of: "--model"), i + 1 < w.count { out.append(LaunchParam(text: Self.shortModel(w[i + 1]), kind: .model)) }
        else if let m = w.first(where: { $0.hasPrefix("--model=") }) { out.append(LaunchParam(text: Self.shortModel(String(m.dropFirst(8))), kind: .model)) }
        if w.contains("--dangerously-skip-permissions") || (w.firstIndex(of: "--permission-mode").map { $0 + 1 < w.count && w[$0 + 1] == "bypassPermissions" } ?? false) {
            out.append(LaunchParam(text: "skip perms", kind: .danger))
        }
        if w.contains("--continue") || w.contains("-c") { out.append(LaunchParam(text: "continue", kind: .conversation)) }
        else if let id = Self.resumedId(command) { out.append(LaunchParam(text: "resume " + id.prefix(4) + "…", kind: .conversation)) }
        return out
    }

    static func shortModel(_ m: String) -> String { m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m }

    static func channelName(_ s: String) -> String {
        let afterKind = s.split(separator: ":", maxSplits: 1).last.map(String.init) ?? s
        return afterKind.split(separator: "@").first.map(String.init) ?? afterKind
    }

    /// The conversation a running command resumes (`--resume <id>` / `--resume=<id>`), if it names one.
    static func resumedId(_ command: String) -> String? {
        let w = words(command)
        if let i = w.firstIndex(where: { $0 == "--resume" || $0 == "-r" }), i + 1 < w.count { return w[i + 1] }
        return w.first { $0.hasPrefix("--resume=") }.map { String($0.dropFirst(9)) }
    }

    /// What to run in place of a running command that lost the flags: the same program and conversation, plus them.
    func restoring(_ running: String) -> String? {
        guard let program = Self.words(running).first, let id = Self.resumedId(running) else { return nil }
        return ([program, "--resume", id] + flags).joined(separator: " ")
    }
}

/// One parameter of an agent's command, as a chip: what it says and how loud it should be.
public struct LaunchParam: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case channel, model, danger, conversation }
    public let text: String
    public let kind: Kind
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
    /// The parameters of a remote session's agents now (or of one workspace's), each once, in order.
    public func params(of r: RemoteSession, workspace: String? = nil) -> [LaunchParam] {
        let cwds = Set((remoteState[r.id]?.agentList ?? []).filter { workspace == nil || $0.workspace == workspace }.map(\.cwd))
        var seen = Set<LaunchParam>()
        return (launches[r.id] ?? []).filter { cwds.contains($0.cwd) }.flatMap(\.params).filter { seen.insert($0).inserted }
    }

    /// The channels a remote session's agents listen on now (their remembered commands, for the folders they run in).
    public func channels(of r: RemoteSession, workspace: String? = nil) -> [String] {
        let agents = (remoteState[r.id]?.agentList ?? []).filter { workspace == nil || $0.workspace == workspace }
        let cwds = Set(agents.map(\.cwd))
        var seen = Set<String>()
        return (launches[r.id] ?? []).filter { cwds.contains($0.cwd) }.flatMap(\.channels).filter { seen.insert($0).inserted }
    }

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

    /// After Start / Restart, for each remembered launch, in the pane herdr restored in its folder:
    /// - no agent there (no herdr integration, as on xiaoer's login): run the remembered command;
    /// - an agent herdr resumed on its own, as plain `claude --resume <id>` without the remembered flags (phd on black):
    ///   end that process and run the same program and conversation with the flags (Nat picked this over losing them);
    /// - an agent already running with every flag: leave it.
    /// nil when every one is right, else the commands to run by hand.
    func relaunch(_ r: RemoteSession) async -> String? {
        let remembered = launches[r.id] ?? []
        guard !remembered.isEmpty, r.isSafe else { return nil }
        let via = remoteState[r.id]?.viaSSH == true
        let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", r.target]
        var failed: [String] = []
        for l in remembered {
            // herdr restores the workspaces, then resumes agents that have a saved session; give both a moment
            var pane: String?, agentThere = false, live: (pid: Int, cwd: String, command: String)?
            for attempt in 0..<12 {
                if let out = await Self.remoteHerdr(r, ["pane", "list"], viaSSH: via), out.status == 0,
                   let o = try? JSONSerialization.jsonObject(with: Data(out.out.utf8)) as? [String: Any],
                   let list = (o["result"] as? [String: Any])?["panes"] as? [[String: Any]],
                   let p = list.first(where: { ($0["cwd"] as? String) == l.cwd }) {
                    pane = p["pane_id"] as? String
                    agentThere = p["agent"] is String
                }
                let procs = await Shell.run("ssh", ssh + [RemoteParse.launchesCommand + "; true"], timeout: 15).map { RemoteParse.liveAgents($0) } ?? []
                live = procs.first { $0.cwd == l.cwd }
                if live != nil || (pane != nil && attempt >= 5) { break }   // resumed, or ~6 s of a plain shell: nothing to wait for
                try? await Task.sleep(for: .seconds(1))
            }
            guard let pane, pane.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) else {
                failed.append("ssh -t \(r.target) 'cd \(l.cwd) && \(l.command)'"); continue
            }
            var run = l.command
            if let live {
                let have = Set(AgentLaunch.words(live.command))
                if l.flags.allSatisfy(have.contains) { continue }       // running with every flag: leave it
                guard let again = l.restoring(live.command) else {      // no conversation to keep: start as remembered
                    failed.append("ssh -t \(r.target) 'cd \(l.cwd) && \(l.command)'"); continue
                }
                // end the process herdr resumed without the flags, then resume the same conversation with them
                _ = await Shell.run("ssh", ssh + ["kill -TERM \(live.pid); for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 \(live.pid) 2>/dev/null || break; sleep 1; done; true"], timeout: 20)
                run = again
            } else if agentThere {
                continue   // an agent we could not read the process of: do not touch it
            }
            if await Self.remoteHerdr(r, ["pane", "run", pane, RemoteParse.shellQuote(run)], viaSSH: via)?.status != 0 {
                failed.append("herdr --session \(r.session) pane run \(pane) \(RemoteParse.shellQuote(run))")
            }
        }
        await refresh(remotes: true)
        return failed.isEmpty ? nil : "Started; run these again by hand:\n  " + failed.joined(separator: "\n  ")
    }
}
#endif
