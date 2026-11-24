import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - Oracles (the landing app): every herdr session, every space, every oracle — a click opens its app.
// Data: `herdr session list` (all sessions, running or stopped) + `maw herdr ls --json` (spaces and
// worktrees of every running session, ~0.4 s) + the oracle apps installed on this Mac (co.laris.oracle.<key>).

@MainActor
public final class HubStore: ObservableObject {
    @Published public private(set) var sessions: [HubSession] = []
    /// Remote herdr sessions (HubRemote.swift): remembered by the hub, saved as herdr machines, attached from here now.
    @Published public private(set) var remotes: [RemoteSession] = []
    @Published public private(set) var remoteState: [String: RemoteState] = [:]
    /// how each remote session's agents were started, so Start / Restart can run them again (Hub.Launches.swift)
    @Published public internal(set) var launches: [String: [AgentLaunch]] = LaunchMemory.load()
    /// each machine (ssh target) the hub knows: its herdr and every session on it (Nat: "if we have many machines,
    /// group, show machine")
    @Published public private(set) var remoteMachines: [String: RemoteMachineState] = [:]
    /// remotes with a `herdr --remote` client running on this Mac now (the link icon, Detach)
    @Published public private(set) var attachedRemotes: Set<String> = []
    /// …and the ones of those that are no saved herdr machine: listed with the command that saves them
    @Published public private(set) var unsavedAttached: [RemoteSession] = []
    /// the ssh targets asked for their sessions: the hub's own list, saved machines' and attached windows' (#137)
    @Published public private(set) var watched: [String] = []
    /// herdr's saved machines, from every local session's catalog
    private var savedRemotes: [RemoteSession] = []
    /// every session the watched machines listed when last asked
    private var listed: [RemoteSession] = []
    private var lastRemoteProbe = Date.distantPast
    private var probing = false
    private var probeAgain = false   // asked for while a probe ran: it runs once more when that one ends (#98)
    @Published public private(set) var spaces: [HubSpace] = []
    @Published public private(set) var oracles: [HubOracle] = []
    @Published public private(set) var apps: [String: URL] = [:]
    /// Oracles in maw's registry that herdr has never seen — listed last, folded.
    @Published public private(set) var registryOnly: [HubOracle] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var problems: [String] = []
    /// What the after-reboot autostart held back (#116): sessions whose saved agents are already live elsewhere
    var autostartHeld: [String] = []
    private var timer: Timer?

    /// Starts refreshing at once: the menu-bar item must have data even when no window is open.
    public init() { start() }

    /// Safe to call again (the window calls it on appear): only the first call starts the clock.
    public func start() {
        guard timer == nil else { return }
        #if os(macOS)
        Task { autostartHeld = await autostartAfterReboot(); await refresh() }   // #116: once per launch, right after boot
        #else
        Task { await refresh() }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// `remotes: true` (the ↻ button, a stop) re-probes the remote machines now instead of waiting out the 45 s gate (#98).
    public func refresh(remotes force: Bool = false) async {
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
        problems = issues + autostartHeld
        lastRefresh = Date()
        if force { lastRemoteProbe = .distantPast }
        await refreshRemotes()
        #endif
    }

    /// The local sessions, without the folders that are only a remote client's trace.
    public var localSessions: [HubSession] { sessions.filter { s in s.dir.map { !Self.isRemoteTrace(dir: $0) } ?? true } }

    #if os(macOS)
    /// Remote sessions (#137): every session on every watched machine (RemoteParse.watchTargets), read over ssh, merged
    /// with herdr's saved machines and the `herdr --remote` windows open here. Saved machines are read from every running
    /// local session socket: herdr 0.9.5 keeps one catalog per session, so the default session alone may list none.
    /// Retired machines and logins (black, nm@white, god@white) are left out unless the Network page shows them. Probed in the
    /// background, at most every 45 s.
    func refreshRemotes() async {
        let running = sessions.filter(\.running).map(\.name)
        async let ps = Shell.run("ps", ["-axo", "args="])
        async let catalogs = Self.savedMachines(sessions: running)
        let (psOut, saved) = await (ps, catalogs)
        let showRetired = UserDefaults.standard.bool(forKey: Self.showRetiredKey)
        let keep = { (r: RemoteSession) in showRetired || !RemoteParse.isRetired(r.target) }
        let live = Set((psOut ?? "").split(separator: "\n").compactMap { RemoteParse.remote(of: String($0)) }).filter(keep)
        savedRemotes = saved.filter(keep)
        watched = RemoteParse.watchTargets(hub: Self.hubHosts, saved: savedRemotes, attached: Array(live), showRetired: showRetired)
        remotes = RemoteParse.merge(listed: listed.filter { watched.contains($0.target) }, saved: savedRemotes,
                                    attached: live.sorted { $0.id < $1.id })
        attachedRemotes = Set(live.map(\.id))
        let savedIds = Set(savedRemotes.map(\.id))
        unsavedAttached = live.filter { !savedIds.contains($0.id) }.sorted { $0.id < $1.id }
        // a machine not asked yet (just loaded, just added) is asked now, whatever the 45 s gate says
        let unasked = watched.contains { remoteMachines[$0] == nil }
        if unasked || Date().timeIntervalSince(lastRemoteProbe) > 45 { lastRemoteProbe = Date(); Task { await probeRemotes() } }
    }

    /// herdr's saved machines from every running local session (and the default one), one per profile id.
    nonisolated static func savedMachines(sessions: [String]) async -> [RemoteSession] {
        let names = Array(Set(sessions + ["default"])).sorted()
        var all: [RemoteSession] = [], seen = Set<String>()
        await withTaskGroup(of: [RemoteSession].self) { g in
            for s in names {
                g.addTask {
                    let args = (s == "default" ? [] : ["--session", s]) + ["machine", "list", "--json"]
                    return (await Shell.run("herdr", args)).map { RemoteParse.machines(Data($0.utf8)) } ?? []
                }
            }
            for await list in g { for r in list where seen.insert(r.profileId ?? r.id).inserted { all.append(r) } }
        }
        return all.sorted { $0.id < $1.id }
    }

    /// The machines the hub watches on its own (`+`, "Watch"): ssh targets, kept in the hub's defaults.
    nonisolated public static let hostsKey = "hubHosts"
    nonisolated public static let showRetiredKey = "hubShowRetired"
    nonisolated public static var hubHosts: [String] { UserDefaults.standard.stringArray(forKey: hostsKey) ?? [] }

    /// Watch a machine: its every herdr session lists here, read over ssh, nothing saved in herdr. nil when added.
    public func watchHost(_ target: String) async -> String? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard RemoteSession(target: t, session: "default").isSafe else { return "a target is user@host (letters, digits, . _ - @ :)" }
        if RemoteParse.isRetired(t), !UserDefaults.standard.bool(forKey: Self.showRetiredKey) {
            return "\(t) is retired (black, nm@white, god@white): turn on Network › Add a machine › Show retired machines first"
        }
        var hosts = Self.hubHosts
        if !hosts.contains(t) { hosts.append(t); UserDefaults.standard.set(hosts, forKey: Self.hostsKey) }
        await refresh(remotes: true)
        return remoteMachines[t]?.problem
    }

    /// Stop watching a machine the hub was given. Saved herdr machines on it keep listing until removed in herdr.
    public func unwatchHost(_ target: String) async {
        UserDefaults.standard.set(Self.hubHosts.filter { $0 != target }, forKey: Self.hostsKey)
        listed.removeAll { $0.target == target }
        remoteMachines[target] = nil
        await refresh(remotes: true)
    }

    /// Every watched machine at once, over ssh: its session list, then each running session's agents and workspaces.
    /// A saved machine whose host did not answer ssh is asked the old way, `herdr --machine <id>`.
    public func probeRemotes() async {
        guard !probing else { probeAgain = true; return }
        probing = true
        defer {
            probing = false
            if probeAgain { probeAgain = false; Task { await probeRemotes() } }
        }
        let hosts = watched
        if !hosts.isEmpty { lastRemoteProbe = Date() }   // asking nobody (the list not loaded yet) is no probe
        var unreachable = Set<String>()
        await withTaskGroup(of: (String, RemoteMachineState, [String: RemoteState]).self) { g in
            for t in hosts { g.addTask { await Self.probeHost(t) } }
            for await (t, m, states) in g {
                remoteMachines[t] = m
                guard m.problem == nil else { unreachable.insert(t); continue }
                listed.removeAll { $0.target == t }
                listed += m.sessions.keys.sorted().map { RemoteSession(target: t, session: $0) }
                for (name, on) in m.sessions {
                    let id = RemoteSession(target: t, session: name).id
                    var st = states[name] ?? RemoteState(running: on, version: m.version, checked: m.checked)
                    st.running = on                  // the session list decides; an unreadable agent list keeps its problem ("?")
                    if !on { st.problem = nil }
                    st.viaSSH = true
                    remoteState[id] = st
                }
            }
        }
        remotes = RemoteParse.merge(listed: listed.filter { watched.contains($0.target) }, saved: savedRemotes,
                                    attached: remotes.filter { attachedRemotes.contains($0.id) })
        // saved machines no ssh reached: their own profile, through herdr's bridge
        let fallback = savedRemotes.filter { $0.profileId != nil && unreachable.contains($0.target) }
        await withTaskGroup(of: (RemoteSession, RemoteState).self) { g in
            for r in fallback { g.addTask { (r, await Self.probe(r)) } }
            for await (r, st) in g {
                remoteState[r.id] = st
                if st.problem == nil, var m = remoteMachines[r.target] { m.problem = nil; m.sessions[r.session] = st.running; remoteMachines[r.target] = m }
            }
        }
        await recordLaunches()   // and how their agents were started, while they run
    }

    /// One machine over ssh: `herdr --version` and `session list --json`, then agents and workspaces of the running
    /// sessions in one more call. Read-only; a problem ends with the command to run.
    nonisolated static func probeHost(_ target: String, at: Date = Date()) async -> (String, RemoteMachineState, [String: RemoteState]) {
        let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", target]
        let host = RemoteSession(target: target, session: "default").host
        guard let out = await Shell.capture("ssh", ssh + [RemoteParse.listCommand], timeout: 20) else {
            return (target, RemoteMachineState(problem: "\(host): ssh did not answer — run:  ssh \(target) herdr session list", checked: at), [:])
        }
        let version = out.out.split(separator: "\n").first { $0.hasPrefix("herdr ") }.map { String($0.dropFirst(6)) }
        guard let list = RemoteParse.sessionList(out.out) else {
            let why = out.status == 255 ? "ssh refused without a prompt" : version == nil ? "no herdr on its PATH" : "herdr listed no sessions"
            return (target, RemoteMachineState(version: version, problem: "\(host): \(why) — run:  ssh \(target) herdr session list", checked: at), [:])
        }
        var m = RemoteMachineState(version: version, checked: at)
        for s in list { m.sessions[s.name] = s.running }
        let running = list.filter(\.running).map(\.name)
        guard !running.isEmpty else { return (target, m, [:]) }
        let detail = await Shell.capture("ssh", ssh + [RemoteParse.detailCommand(running)], timeout: 30)
        return (target, m, detail.map { RemoteParse.details($0.out, version: version, at: at) } ?? [:])
    }

    /// One saved machine: its server's status, then its agents. A problem ends with the command to run.
    nonisolated static func probe(_ r: RemoteSession) async -> RemoteState {
        guard let id = r.profileId else { return RemoteState(running: false) }
        var viaSSH = false
        var s = await remoteHerdr(r, ["status", "server"], viaSSH: false)
        if s.map({ $0.out.contains("does not support machine API forwarding") }) == true {
            viaSSH = true   // herdr's own window still shows it: its viewing connection needs no bridge
            s = await remoteHerdr(r, ["status", "server"], viaSSH: true)
        }
        let version = s.flatMap { RemoteParse.statusField("version", in: $0.out) }
        let running = s.map { $0.status == 0 && RemoteParse.statusField("status", in: $0.out) == "running" } ?? false
        guard running else {
            let why = s.map { RemoteParse.statusField("status", in: $0.out) ?? "no answer" } ?? "herdr is missing here"
            let ask = viaSSH ? "ssh \(r.target) 'herdr --session \(r.session) status server'" : "herdr --machine \(r.label ?? id) status server"
            var st = RemoteState(running: false, version: version,
                                 problem: why == "stopped" ? nil : "\(r.label ?? r.host): \(why) — run:  \(ask)")
            st.viaSSH = viaSSH
            return st
        }
        async let agents = remoteHerdr(r, ["agent", "list"], viaSSH: viaSSH)
        async let spaces = remoteHerdr(r, ["workspace", "list"], viaSSH: viaSSH)
        let (a, w) = await (agents, spaces)
        var st = a.map { RemoteParse.probe($0.out) } ?? RemoteState(running: true)
        st.running = true; st.version = version; st.viaSSH = viaSSH
        st.workspaces = w.map { RemoteParse.workspaces($0.out) } ?? []
        return st
    }

    /// `herdr <args>` for a saved machine's session: `herdr --machine <id> <args>` (stderr folded into the answer, so
    /// "does not support machine API forwarding" can be read), or, for a machine whose herdr predates that bridge,
    /// `ssh <target> herdr --session <s> <args>`. Only ever called with the hub's own fixed arguments.
    nonisolated static func remoteHerdr(_ r: RemoteSession, _ args: [String], viaSSH: Bool, timeout: TimeInterval = 20) async -> (status: Int32, out: String)? {
        if viaSSH {
            guard r.isSafe else { return nil }
            let cmd = "export PATH=$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr --session \(r.session) "
                + args.joined(separator: " ")
            return await Shell.capture("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", r.target, cmd], timeout: timeout)
        }
        guard let id = r.profileId, id.allSatisfy({ $0.isHexDigit }), let herdr = Shell.which("herdr") else { return nil }
        let q = "'" + herdr.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return await Shell.capture("sh", ["-c", "\(q) --machine \(id) \(args.joined(separator: " ")) 2>&1"], timeout: timeout)
    }

    /// A folder herdr lists as a session but that only a remote client wrote: a client log, no session.json or server log.
    nonisolated static func isRemoteTrace(dir: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir + "/herdr-client.log") && !fm.fileExists(atPath: dir + "/session.json")
            && !fm.fileExists(atPath: dir + "/herdr-server.log")
    }

    nonisolated static func tail(_ path: String, bytes: Int = 65_536) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Its WezTerm window when this Mac is attached; otherwise a new one running `herdr --remote <target> --session <s>`.
    public func openRemote(_ r: RemoteSession) {
        guard r.isSafe else { return }
        Task.detached { await WezTerm.show(remote: r) }
    }

    /// Save a machine the way herdr does: `herdr machine add` in a WezTerm window, because it may ask before it
    /// installs or starts herdr there. nil when the window opened, else why not.
    public func saveMachine(target: String, session: String, label: String) -> String? {
        let r = RemoteSession(target: target.trimmingCharacters(in: .whitespaces), session: session.trimmingCharacters(in: .whitespaces))
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? r.host : label.trimmingCharacters(in: .whitespaces)
        guard r.isSafe, RemoteSession(target: r.target, session: name.replacingOccurrences(of: " ", with: "-")).isSafe else {
            return "a target is user@host (letters, digits, . _ - @ :), a session and a label plain names"
        }
        Task.detached { await WezTerm.run(["machine", "add", r.target, "--label", name, "--remote-session", r.session]) }
        return nil
    }

    /// Forget a saved machine: `herdr machine remove <id>`. Its sessions keep running there.
    public func removeMachine(_ r: RemoteSession) async -> String? {
        guard let id = r.profileId else { return nil }
        let out = await Shell.run("herdr", ["machine", "remove", id])
        await refresh(remotes: true)
        return out != nil ? nil : "herdr could not remove it — run:  herdr machine remove \(id)"
    }
    #endif

    /// Oracles that have an app, in name order — shown first, live or not.
    public var appOracles: [HubOracle] {
        apps.keys.sorted().map { key in
            oracles.first { $0.appKey == key }
                ?? HubOracle(repo: key, spaces: [], running: 0, open: 0, resumable: 0, cold: 0, checkout: nil, resume: nil)
        }
    }

    #if os(macOS)
    /// A click on an app card brings the app to the main display (Nat, 2026-10-08): it is sent
    /// `oracle-<name>://front?display=<main display>` and moves its own window there, so no Accessibility or yabai.
    /// The app is named by its bundle, so a dev build that registered the same scheme never gets the link.
    public func openApp(_ key: String) {
        guard let url = apps[key] else { return }
        if let link = Self.frontLink(app: url, display: CGMainDisplayID()) {
            NSWorkspace.shared.open([link], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// `oracle-<name>://front?display=<id>` from the app's own URL scheme (its Info.plist); nil for an app without one.
    nonisolated public static func frontLink(app: URL, display: CGDirectDisplayID) -> URL? {
        guard let types = Bundle(url: app)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]],
              let scheme = types.flatMap({ $0["CFBundleURLSchemes"] as? [String] ?? [] }).first(where: { $0.hasPrefix("oracle-") })
        else { return nil }
        return URL(string: "\(scheme)://front?display=\(display)")
    }

    /// Focus the space in herdr, by the state of the session's WezTerm window:
    /// front — the switch happens where Nat is looking, nothing moves or rises;
    /// behind — that window rises on its own screen, and the hub comes back on top only from another screen;
    /// no window — a new WezTerm window attached to the session, brought to the main screen.
    public func showInHerdr(_ s: HubSpace) {
        Task.detached {
            _ = await Shell.run("herdr", ["--session", s.session, "workspace", "focus", s.spaceId])
            switch await WezTerm.clientWindow(session: s.session) {
            case .front:
                return
            case .behind(let id, _):
                _ = await Shell.run("yabai", ["-m", "window", String(id), "--focus"])
                let there = await WezTerm.displayID(window: id), here = await WezTerm.hubDisplayID()
                guard let there, let here, there != here else { return }
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            case .none:
                await self.bringHereNow(s)
            }
        }
    }

    /// The old Show in herdr, kept as "Bring here": focus the space, move its WezTerm window to the main screen,
    /// then this app back on top.
    public func bringHere(_ s: HubSpace) {
        Task.detached {
            _ = await Shell.run("herdr", ["--session", s.session, "workspace", "focus", s.spaceId])
            await self.bringHereNow(s)
        }
    }

    nonisolated private func bringHereNow(_ s: HubSpace) async {
        await WezTerm.show(session: s.session, label: s.label)
        // like an oracle app's "bring here": the terminal is up on its space, and this app comes back on top
        try? await Task.sleep(for: .milliseconds(350))
        await MainActor.run { NSApp.activate(ignoringOtherApps: true); NSApp.mainWindow?.orderFrontRegardless() }
    }

    /// A whole session: its WezTerm client, or a new one — which also starts a stopped session.
    public func openSession(_ name: String) {
        Task.detached { await WezTerm.show(session: name) }
    }

    /// Start a stopped session in the background: a detached `herdr --session S server`, no window, focus
    /// untouched. herdr relaunches each recorded agent resumed; Show in herdr / Open in WezTerm attach later.
    /// nil once the server answers (≤10 s); otherwise the command to run.
    public func startSession(_ name: String) async -> String? {
        // never resume a conversation twice: one already live elsewhere comes back as a shell (session.json backed up first)
        let r = await HerdrPlaces.startSkippingLive(name: name, dir: sessions.first(where: { $0.name == name })?.dir)
        if let n = HerdrPlaces.skippedNote(name, r.skipped, backup: r.backup) { autostartHeld = Array((autostartHeld + [n]).suffix(3)) }
        await refresh()
        return r.error
    }

    /// Which agents a reopen brings back. herdr (0.9.1) saves each pane's `agent_session` when the session stops
    /// and relaunches that agent resumed on reopen — claude and codex alike; a pane whose agent never reported
    /// a session id comes back as a bare shell. Read live from `herdr --session S agent list`.
    public func resumeCheck(_ name: String) async -> (resumes: [String: Int], lost: [String])? {
        guard let out = await Shell.run("herdr", ["--session", name, "agent", "list"]) else { return nil }
        return RemoteParse.resume(agentList: out)   // the same reading as a remote session's (#100)
    }

    /// Stop a whole session: its server and every pane in it end. herdr resumes each recorded agent on reopen
    /// (see `resumeCheck`). nil when it stopped; otherwise the error with the command to run.
    /// What a stopped session holds, for the confirmation: the spaces session.json saved, and its files.
    public struct SessionContents: Sendable, Equatable {
        public let spaces: [String]
        public let files: Int
        public let bytes: Int64
    }

    nonisolated public static func contents(of s: HubSession) -> SessionContents {
        guard let dir = s.dir else { return SessionContents(spaces: [], files: 0, bytes: 0) }
        var spaces: [String] = []
        if let d = FileManager.default.contents(atPath: dir + "/session.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ws = o["workspaces"] as? [[String: Any]] {
            // a space is named by herdr's custom name, else its folder (identity_cwd), else its id
            spaces = ws.map { w in (w["custom_name"] as? String) ?? (w["identity_cwd"] as? String).map { ($0 as NSString).lastPathComponent }
                                   ?? (w["id"] as? String) ?? "space" }
        }
        let files = keepable(in: URL(fileURLWithPath: dir))
        return SessionContents(spaces: spaces, files: files.count, bytes: files.reduce(0) { $0 + $1.size })
    }

    /// The regular files under a session's folder: sockets and other specials are skipped (a stopped session keeps
    /// stale `herdr.sock` files, and a socket cannot be copied).
    nonisolated static func keepable(in dir: URL) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        return e.compactMap { item -> (URL, Int64)? in
            guard let u = item as? URL, let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (u, Int64(v.fileSize ?? 0))
        }
    }

    /// Where a deleted session's files are kept: ~/Library/Application Support/ARRA Oracles/deleted-sessions.
    nonisolated public static var deletedSessions: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles/deleted-sessions", isDirectory: true)
    }

    /// Copy a session's regular files to `deleted-sessions/<name>-<yyyyMMdd-HHmmss>` (Nothing is Deleted): the copy,
    /// or why it failed.
    enum Kept: Equatable { case copy(URL), failed(String) }

    nonisolated static func keepCopy(of s: HubSession, at now: Date = Date(), into root: URL = deletedSessions) -> Kept {
        guard let dir = s.dir else { return .failed("herdr did not say where \(s.name) keeps its files") }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let to = root.appendingPathComponent("\(s.name)-\(f.string(from: now))", isDirectory: true)
        let from = URL(fileURLWithPath: dir).standardizedFileURL
        do {
            for (u, _) in keepable(in: from) {
                let rel = String(u.standardizedFileURL.path.dropFirst(from.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let dest = to.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: u, to: dest)
            }
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)   // an empty session still leaves its mark
            return .copy(to)
        } catch {
            let ns = error as NSError
            return .failed("could not keep a copy of \(s.name) in \(to.path) (\(ns.domain) \(ns.code)); nothing was deleted")
        }
    }

    /// Why a session is not deleted from here: the default one is herdr's own config folder; a running one is stopped first.
    nonisolated static func refusal(_ s: HubSession) -> String? {
        if s.isDefault { return "the default session is herdr's own config folder (~/.config/herdr); it is not deleted from here" }
        if s.running { return "\(s.name) is running: stop it first, then delete it\n  herdr session stop \(s.name)" }
        return nil
    }

    /// Delete a stopped session with `herdr session delete`, after keeping a copy of its files. nil when it is gone;
    /// otherwise what went wrong, with the command to run.
    public func deleteSession(_ s: HubSession) async -> String? {
        if let no = Self.refusal(s) { return no }
        switch Self.keepCopy(of: s) {
        case .failed(let why): return why
        case .copy(let kept): HubLog.shared.add(.info, "session \(s.name): a copy of its files is in \(kept.path)")
        }
        let out = await Shell.run("herdr", ["session", "delete", s.name], timeout: 20)
        await refresh()
        if out == nil { return "herdr could not delete \(s.name) — run it in a terminal to see why:\n  herdr session delete \(s.name)" }
        HubLog.shared.add(.info, "session \(s.name) deleted (herdr session delete)")
        return nil
    }

    public func stopSession(_ name: String) async -> String? {
        let out = await Shell.run("herdr", ["session", "stop", name], timeout: 20)
        await refresh()
        return out != nil ? nil : "herdr could not stop \(name) — run it in a terminal to see why:  herdr session stop \(name)"
    }
    #endif
}

#if os(macOS)
extension HubStore {
    /// Why a name cannot be a new herdr session here, nil when it can: letters, digits, - and _ (herdr makes a folder of
    /// it under ~/.config/herdr/sessions), not one that already exists — that one is Started from its row instead.
    nonisolated public static func newSessionProblem(_ raw: String, existing: [String]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "give it a name" }
        if name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) == nil {
            return "use letters, digits, - and _ (it becomes a folder under ~/.config/herdr/sessions)"
        }
        if existing.contains(name) { return "\(name) already exists — open it from the list, or Start it there if it is off" }
        return nil
    }
}
#endif
