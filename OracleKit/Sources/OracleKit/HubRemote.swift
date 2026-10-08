import Foundation

/// A herdr session on another machine, reached the way Nat reaches it: `herdr --remote <target> --session <name>`
/// (Nat, 2026-10-08: "can we list the remote? if not machine, like this?").
///
/// The hub lists only herdr's saved machines (`herdr machine list`): one profile per remote session, with an id
/// that `herdr --machine <id>` takes. A `herdr --remote` window open on this Mac is matched to them by target and
/// session (the link icon, Detach).
public struct RemoteSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String { target + "|" + session }
    /// the ssh target as typed: "phd-oracle@black.follow-rankine.ts.net", "white"
    public let target: String
    /// "default" when the command had no --session
    public let session: String
    /// a saved herdr machine's label
    public var label: String?
    /// a saved herdr machine's profile id: what `herdr --machine` and `herdr machine remove` take
    public var profileId: String?

    public init(target: String, session: String, label: String? = nil, profileId: String? = nil) {
        self.target = target; self.session = session.isEmpty ? "default" : session; self.label = label; self.profileId = profileId
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
    /// its workspaces, as herdr's own sidebar lists them under the machine
    public var workspaces: [RemoteWorkspace] = []
    /// read over plain ssh: the machine's herdr predates the `--machine` API bridge (0.9.0)
    public var viaSSH = false
    /// where each agent runs: its workspace, pane and folder (from `herdr agent list`)
    public var agentList: [RemoteAgent] = []

    public init(running: Bool, agents: Int = 0, working: Int = 0, needsYou: Int = 0, version: String? = nil,
                problem: String? = nil, checked: Date = Date()) {
        self.running = running; self.agents = agents; self.working = working; self.needsYou = needsYou
        self.version = version; self.problem = problem; self.checked = checked
    }
}

/// One agent of a remote session, as `herdr agent list` places it.
public struct RemoteAgent: Sendable, Equatable {
    public let workspace: String
    public let pane: String
    public let cwd: String
    public let kind: String     // claude, codex, …
}

/// One workspace of a remote session (`herdr workspace list`).
public struct RemoteWorkspace: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// herdr's agent_status: working, blocked, done, idle, unknown
    public let status: String
    public let panes: Int
}

public enum RemoteParse {
    /// `herdr workspace list` → its workspaces in herdr's order.
    public static func workspaces(_ json: String) -> [RemoteWorkspace] {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let list = (d["result"] as? [String: Any])?["workspaces"] as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let id = w["workspace_id"] as? String else { return nil }
            return RemoteWorkspace(id: id, label: w["label"] as? String ?? id, status: w["agent_status"] as? String ?? "unknown",
                                   panes: w["pane_count"] as? Int ?? 0)
        }
    }

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
            return RemoteSession(target: t, session: r["session"] as? String ?? "default", label: r["label"] as? String,
                                 profileId: r["id"] as? String)
        }
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
        var st = RemoteState(running: true, agents: agents.count, working: status.filter { $0 == "working" }.count,
                             needsYou: status.filter { $0 == "blocked" || $0 == "done" }.count, version: version, checked: at)
        st.agentList = agents.compactMap { a in
            guard let pane = a["pane_id"] as? String else { return nil }
            return RemoteAgent(workspace: a["workspace_id"] as? String ?? "", pane: pane, cwd: a["cwd"] as? String ?? "",
                               kind: a["agent"] as? String ?? "agent")
        }
        return st
    }

    /// One shell word, single-quoted, for a command line that crosses ssh or `sh -c`.
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A login's running agents as its process table says — "<pid>\t<folder>\t<command line>" per line (Linux /proc).
    static let launchesCommand = "for p in $(pgrep -u \"$(id -u)\" -x claude; pgrep -u \"$(id -u)\" -x codex); do "
        + "printf '%s\\t%s\\t' \"$p\" \"$(readlink /proc/$p/cwd)\"; tr '\\0' ' ' < /proc/$p/cmdline; echo; done"

    /// What `launchesCommand` printed → each running agent: its pid, folder and command line.
    public static func liveAgents(_ out: String) -> [(pid: Int, cwd: String, command: String)] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let pid = Int(parts[0]), parts[1].hasPrefix("/") else { return nil }
            let command = parts[2].trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : (pid, parts[1], command)
        }
    }

    /// The same, as launches to remember: one per folder (the last line wins).
    public static func launches(_ out: String, at: Date = Date()) -> [AgentLaunch] {
        var byCwd: [String: AgentLaunch] = [:]
        for a in liveAgents(out) { byCwd[a.cwd] = AgentLaunch(cwd: a.cwd, command: a.command, seen: at) }
        return byCwd.values.sorted { $0.cwd < $1.cwd }
    }

    /// One `key: value` line of `herdr status server` ("status: running", "version: 0.9.1").
    public static func statusField(_ key: String, in out: String) -> String? {
        out.split(separator: "\n").first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces) }
    }

    /// One `herdr agent list` answer → agents herdr resumes on reopen (count per kind: they hold an `agent_session`)
    /// and the ones that come back as a plain shell; nil when it is not an agent list.
    public static func resume(agentList json: String) -> (resumes: [String: Int], lost: [String])? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let agents = (d["result"] as? [String: Any])?["agents"] as? [[String: Any]] else { return nil }
        var resumes: [String: Int] = [:], lost: [String] = []
        for a in agents {
            let kind = a["agent"] as? String ?? "agent"
            if (a["agent_session"] as? [String: Any])?["value"] is String { resumes[kind, default: 0] += 1 }
            else { lost.append("\(a["name"] as? String ?? a["pane_id"] as? String ?? "?") (\(kind))") }
        }
        return (resumes, lost)
    }

    /// Machines for the sidebar: every remote session known, grouped by host, the hosts and their sessions in name
    /// order; running sessions first within a host.
    /// One group per login on a machine — the machine AND the user (Nat: "it should show machine name and user not
    /// only machine"): nat@white and nm@white (xiaoer) are two groups. Machines in name order, then users.
    public static func groups(_ remotes: [RemoteSession], running: (RemoteSession) -> Bool)
        -> [(key: String, host: String, user: String?, sessions: [RemoteSession])] {
        let byLogin = Dictionary(grouping: remotes) { $0.shortTarget }
        var out: [(key: String, host: String, user: String?, sessions: [RemoteSession])] = []
        for (key, list) in byLogin {
            let sorted = list.sorted { a, b in
                let ra = running(a) ? 0 : 1, rb = running(b) ? 0 : 1
                if ra != rb { return ra < rb }
                if a.session != b.session { return a.session < b.session }
                return a.target < b.target
            }
            out.append((key: key, host: sorted[0].host, user: sorted[0].user, sessions: sorted))
        }
        return out.sorted { ($0.host, $0.user ?? "") < ($1.host, $1.user ?? "") }
    }
}
