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
    /// each machine (ssh target) the hub knows: its herdr and every session on it (Nat: "if we have many machines,
    /// group, show machine")
    @Published public private(set) var remoteMachines: [String: RemoteMachineState] = [:]
    private var knownRemotes: [RemoteSession] = []   // remembered, saved machines, attached now: what the probe asks
    /// remotes with a `herdr --remote` client running on this Mac now
    @Published public private(set) var attachedRemotes: Set<String> = []
    /// local session folders that are only a remote client's trace → the remote that left it
    @Published public private(set) var remoteTraces: [String: RemoteSession] = [:]
    /// …and the traces no known target explains: session name → the target's first 8 characters, as herdr kept them
    @Published public private(set) var unknownTraces: [String: String] = [:]
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
        problems = issues
        lastRefresh = Date()
        if force { lastRemoteProbe = .distantPast }
        await refreshRemotes()
        #endif
    }

    /// The local sessions, without the folders that are only a remote client's trace.
    public var localSessions: [HubSession] { sessions.filter { remoteTraces[$0.name] == nil && unknownTraces[$0.name] == nil } }

    #if os(macOS)
    /// Remote sessions: attached from here now (the process table carries `herdr --remote <target> --session <s>`),
    /// saved as herdr machines, remembered, and read back from the traces a remote attach leaves in
    /// ~/.config/herdr/sessions (`RemoteParse.socketHash`). Probed over ssh in the background, at most every 45 s.
    func refreshRemotes() async {
        async let ps = Shell.run("ps", ["-axo", "args="])
        async let machineList = Shell.run("herdr", ["machine", "list", "--json"])
        let (psOut, machineOut) = await (ps, machineList)
        let live = Set((psOut ?? "").split(separator: "\n").compactMap { RemoteParse.remote(of: String($0)) })
        let machines = machineOut.map { RemoteParse.machines(Data($0.utf8)) } ?? []
        var remembered = RemoteRegistry.load()
        var changed = false
        for r in live where !remembered.contains(where: { $0.id == r.id }) { remembered.append(r); changed = true }
        let traces: [(name: String, trace: (prefix: String, hash: String))] = sessions.compactMap { s in
            guard !s.running, !s.isDefault, let dir = s.dir, Self.isRemoteTrace(dir: dir),
                  let log = Self.tail(dir + "/herdr-client.log"), let t = RemoteParse.trace(clientLog: log) else { return nil }
            return (s.name, t)
        }
        var matched: [String: RemoteSession] = [:]
        let sshConfig = traces.isEmpty ? "" : ((try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? "")
        for _ in 0..<3 {   // a trace found teaches its domain, which can explain the next one
            var learned = false
            for (name, t) in traces where matched[name] == nil {
                let known = remembered + machines
                if let r = known.first(where: { $0.session == name && RemoteParse.left(t, $0) }) { matched[name] = r; continue }
                let found = RemoteParse.candidates(sshConfig: sshConfig, knownTargets: known.map(\.target))
                    .lazy.map { RemoteSession(target: $0, session: name) }.first { RemoteParse.left(t, $0) }
                if let r = found { matched[name] = r; remembered.append(r); changed = true; learned = true }
            }
            if !learned { break }
        }
        if changed { RemoteRegistry.save(remembered) }
        var all = machines
        for r in remembered where !all.contains(where: { $0.id == r.id }) { all.append(r) }
        knownRemotes = all
        remotes = withDiscovered(all)
        attachedRemotes = Set(live.map(\.id))
        remoteTraces = matched
        unknownTraces = Dictionary(uniqueKeysWithValues: traces.filter { matched[$0.name] == nil }.map { ($0.name, $0.trace.prefix) })
        if Date().timeIntervalSince(lastRemoteProbe) > 45 { lastRemoteProbe = Date(); Task { await probeRemotes() } }
    }

    /// The known remotes plus every session running on their machines that the hub did not know of yet.
    private func withDiscovered(_ known: [RemoteSession]) -> [RemoteSession] {
        var all = known
        for (target, m) in remoteMachines {
            for (name, running) in m.sessions where running {
                let r = RemoteSession(target: target, session: name)
                if r.isSafe, !all.contains(where: { $0.id == r.id }) { all.append(r) }
            }
        }
        return all
    }

    /// Each machine once, all at once: `herdr session list` over ssh, then the agents of its running sessions.
    public func probeRemotes() async {
        guard !probing else { probeAgain = true; return }
        probing = true
        defer {
            probing = false
            if probeAgain { probeAgain = false; Task { await probeRemotes() } }
        }
        lastRemoteProbe = Date()
        let targets = Array(Set(knownRemotes.filter(\.isSafe).map(\.target)))
        let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]
        await withTaskGroup(of: (String, RemoteMachineState, [String: RemoteState]).self) { g in
            for target in targets {
                g.addTask {
                    guard let out = await Shell.run("ssh", ssh + [target, RemoteParse.listCommand()], timeout: 20) else {
                        return (target, RemoteMachineState(problem: "ssh \(target) did not answer without a prompt — try it in a terminal:\n  ssh \(target)"), [:])
                    }
                    guard let m = RemoteParse.machine(out) else {
                        return (target, RemoteMachineState(problem: "no herdr on \(target)'s PATH (~/.local/bin, /opt/homebrew/bin, /usr/local/bin)"), [:])
                    }
                    let running = m.sessions.filter { $0.running && RemoteSession(target: target, session: $0.name).isSafe }.map(\.name)
                    var states: [String: RemoteState] = [:]
                    if !running.isEmpty, let a = await Shell.run("ssh", ssh + [target, RemoteParse.agentsCommand(sessions: running)], timeout: 25) {
                        states = RemoteParse.agents(a, version: m.version)
                    }
                    for s in m.sessions where !s.running { states[s.name] = RemoteState(running: false, version: m.version) }
                    return (target, RemoteMachineState(version: m.version, sessions: Dictionary(m.sessions.map { ($0.name, $0.running) }, uniquingKeysWith: { a, _ in a })), states)
                }
            }
            for await (target, machine, states) in g {
                remoteMachines[target] = machine
                for (name, st) in states { remoteState[RemoteSession(target: target, session: name).id] = st }
                if let p = machine.problem {
                    for r in knownRemotes where r.target == target { remoteState[r.id] = RemoteState(running: false, problem: p) }
                }
            }
        }
        remotes = withDiscovered(knownRemotes)
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

    /// Remember a remote by hand (Add remote…); nil when added, else why not.
    public func addRemote(target: String, session: String) async -> String? {
        let r = RemoteSession(target: target.trimmingCharacters(in: .whitespaces), session: session.trimmingCharacters(in: .whitespaces))
        guard r.isSafe else { return "a target is user@host (letters, digits, . _ - @ :), a session a plain name" }
        var list = RemoteRegistry.load()
        if !list.contains(where: { $0.id == r.id }) { list.append(r); RemoteRegistry.save(list) }
        lastRemoteProbe = .distantPast
        await refreshRemotes()
        return nil
    }

    /// Forget one the hub remembered (a saved herdr machine stays: `herdr machine remove <id>`).
    public func forgetRemote(_ r: RemoteSession) {
        RemoteRegistry.save(RemoteRegistry.load().filter { $0.id != r.id })
        knownRemotes.removeAll { $0.id == r.id && $0.label == nil }
        remotes = withDiscovered(knownRemotes)
    }

    /// Forget a whole machine the hub remembered (its saved herdr machines stay: `herdr machine remove <id>`).
    public func forgetMachine(host: String) {
        RemoteRegistry.save(RemoteRegistry.load().filter { $0.host != host })
        knownRemotes.removeAll { $0.host == host && $0.label == nil }
        for t in remoteMachines.keys where RemoteSession(target: t, session: "x").host == host && !knownRemotes.contains(where: { $0.target == t }) {
            remoteMachines[t] = nil
        }
        remotes = withDiscovered(knownRemotes)
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
        let cmd = "herdr --session \(name) server"
        guard let herdr = Shell.which("herdr") else { return "herdr not found — run:  \(cmd)" }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        _ = await Shell.run("sh", ["-c", "nohup \(q(herdr)) --session \(q(name)) server >/dev/null 2>&1 &"])
        for _ in 0..<20 {
            if await Shell.run("herdr", ["--session", name, "pane", "list"]) != nil { await refresh(); return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await refresh()
        return "\(name) did not answer within 10 s — run:  \(cmd)"
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
