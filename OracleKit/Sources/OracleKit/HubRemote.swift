import Foundation

/// A herdr session on another machine, reached the way Nat reaches it: `herdr --remote <target> --session <name>`
/// (Nat, 2026-10-08: "can we list the remote? if not machine, like this?").
///
/// The hub lists every session of every machine it watches (#137): a watched machine is an ssh target the hub was
/// given (`+`), the target of a saved herdr machine (`herdr machine list`, read from every local session socket, since
/// each holds its own catalog) or of a `herdr --remote` window open on this Mac. Its sessions come from a read-only
/// `ssh <target> herdr session list --json`. A saved machine keeps its profile id, which `herdr --machine <id>` takes.
public struct RemoteSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String { target + "|" + session }
    /// the ssh target as typed: "nat@white.follow-rankine.ts.net", "gb300"
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
    /// "white" from "nat@white.follow-rankine.ts.net": the machine, as the sidebar groups it
    public var host: String { (target.split(separator: "@").last.map(String.init) ?? target).split(separator: ".").first.map(String.init) ?? target }
    /// "nat" from "nat@white…"; nil when the target names no user
    public var user: String? { target.contains("@") ? String(target.split(separator: "@")[0]) : nil }
    /// "nat@white" from "nat@white.follow-rankine.ts.net"
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

/// What a machine answered (`RemoteParse.sessionList` over ssh): its herdr and every session on it, or why not.
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
    /// only machine"): two logins on one host are two groups. Machines in name order, then users.
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

    /// Where a session of one name runs: this Mac, or a saved remote session.
    public enum Place: Hashable, Sendable {
        case local(HubSession)
        case remote(RemoteSession)
        public var name: String { switch self { case .local(let s): return s.name; case .remote(let r): return r.session } }
        /// sorts this Mac first, then hosts and logins in name order
        var order: (Int, String, String) {
            switch self { case .local: return (0, "", ""); case .remote(let r): return (1, r.host, r.user ?? "") }
        }
    }

    /// The sidebar, session first (Nat: "session name / machine A B C", then "laris-co both m5 and white and black
    /// it should show? how?" → one laris-co with a row per machine). One entry per session name, its places this Mac
    /// first, then hosts. Names running anywhere first, then by name. Same name ≠ same session: each machine's herdr
    /// server is its own; the grouping only shows where a name runs.
    public static func byName(local: [HubSession], remotes: [RemoteSession], running: (Place) -> Bool)
        -> [(name: String, places: [Place])] {
        let all = local.map(Place.local) + remotes.map(Place.remote)
        let byName = Dictionary(grouping: all, by: \.name)
        let out = byName.map { (name: $0.key, places: $0.value.sorted { $0.order < $1.order }) }
        return out.sorted { a, b in
            let ra = a.places.contains(where: running) ? 0 : 1, rb = b.places.contains(where: running) ? 0 : 1
            return ra != rb ? ra < rb : a.name < b.name
        }
    }

    /// The sidebar's other view (Nat, 2026-10-09: "we should have 2 views"): each machine with its sessions under it,
    /// this Mac first, then hosts by label; sessions by name inside each.
    public static func byMachine(local: [HubSession], remotes: [RemoteSession], localName: String)
        -> [(machine: String, places: [Place])] {
        var out: [(machine: String, places: [Place])] = []
        if !local.isEmpty { out.append((localName, local.sorted { $0.name < $1.name }.map(Place.local))) }
        let hosts = Dictionary(grouping: remotes) { machineLabel($0, among: remotes) }
        for h in hosts.keys.sorted() { out.append((h, hosts[h]!.sorted { $0.session < $1.session }.map(Place.remote))) }
        return out
    }

    /// "white", or "white · nat" when white has more than one login among `remotes`.
    public static func machineLabel(_ r: RemoteSession, among remotes: [RemoteSession]) -> String {
        let logins = Set(remotes.filter { $0.host == r.host }.map(\.shortTarget))
        guard logins.count > 1, let u = r.user else { return r.host }
        return r.host + " · " + u
    }

    // MARK: watched machines (#137)

    /// Machines and logins the fleet retired: hidden unless the Network page asks for them. black left for tailscale
    /// (Nat, 2026-09-17); white has one login, nat@white (fleet CLAUDE.md, 2026-10-09).
    public static let retiredHosts: Set<String> = ["black"]
    public static let retiredLogins: Set<String> = ["nm@white", "god@white"]

    /// A target on a retired machine or with a deprecated login.
    public static func isRetired(_ target: String) -> Bool {
        let r = RemoteSession(target: target, session: "default")
        return retiredHosts.contains(r.host.lowercased()) || retiredLogins.contains(r.shortTarget.lowercased())
    }

    /// The machines to ask: the hub's own list, then saved machines' and attached windows' targets, each once, in that
    /// order; retired ones only when asked for, and never anything that could reach a shell as more than a target.
    public static func watchTargets(hub: [String], saved: [RemoteSession], attached: [RemoteSession], showRetired: Bool) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in hub.map({ $0.trimmingCharacters(in: .whitespaces) }) + saved.map(\.target) + attached.map(\.target) {
            guard !t.isEmpty, RemoteSession(target: t, session: "default").isSafe, showRetired || !isRetired(t),
                  seen.insert(t).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// `herdr session list --json` → each session's name and whether its server runs, in herdr's order; nil when the
    /// answer is no session list.
    public static func sessionList(_ out: String) -> [(name: String, running: Bool)]? {
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
              let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let list = d["sessions"] as? [[String: Any]] else { return nil }
        return list.compactMap { s in (s["name"] as? String).map { ($0, s["running"] as? Bool ?? false) } }
    }

    static let remotePath = "export PATH=$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; "

    /// What one ssh to a machine runs: its herdr version, then its session list.
    public static let listCommand = remotePath + "herdr --version; herdr session list --json"

    /// What a second ssh runs for the running sessions: `agent list` and `workspace list` of each, after a marker line
    /// ("@@agents <s>", "@@spaces <s>"). Read-only. Only names that are safe shell words get in.
    public static func detailCommand(_ sessions: [String]) -> String {
        let safe = sessions.filter { RemoteSession(target: "h", session: $0).isSafe }
        return remotePath + safe.map { s in
            "echo '@@agents \(s)'; herdr --session \(s) agent list 2>&1; echo; echo '@@spaces \(s)'; herdr --session \(s) workspace list 2>&1; echo"
        }.joined(separator: "; ")
    }

    /// What `detailCommand` printed → each session's state: its agents (and who needs you) and its workspaces.
    public static func details(_ out: String, version: String?, at: Date = Date()) -> [String: RemoteState] {
        var chunks: [String: (agents: String, spaces: String)] = [:]
        var current: (kind: String, session: String)?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@agents ") || line.hasPrefix("@@spaces ") {
                let parts = line.split(separator: " ", maxSplits: 1)
                current = (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
                continue
            }
            guard let c = current else { continue }
            var e = chunks[c.session] ?? ("", "")
            if c.kind == "@@agents" { e.agents += line + "\n" } else { e.spaces += line + "\n" }
            chunks[c.session] = e
        }
        var states: [String: RemoteState] = [:]
        for (session, c) in chunks {
            var st = probe((version.map { "herdr " + $0 + "\n" } ?? "") + c.agents, at: at)
            st.workspaces = workspaces(c.spaces.split(separator: "\n").first { $0.hasPrefix("{") }.map(String.init) ?? "")
            states[session] = st
        }
        return states
    }

    /// Every remote session once: what the watched machines list (in their order), then saved machines and attached
    /// windows that no machine listed (a machine that did not answer). A saved machine's label and profile id carry over
    /// to the listed session with the same target and name.
    public static func merge(listed: [RemoteSession], saved: [RemoteSession], attached: [RemoteSession]) -> [RemoteSession] {
        var byId: [String: RemoteSession] = [:], order: [String] = []
        for r in listed + saved + attached {
            if var have = byId[r.id] {
                if have.profileId == nil, r.profileId != nil { have.profileId = r.profileId; have.label = r.label }
                byId[r.id] = have
            } else {
                byId[r.id] = r; order.append(r.id)
            }
        }
        return order.compactMap { byId[$0] }
    }
}
