import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Live state of one oracle, refreshed on a timer. macOS reads herdr, gh and ψ/ directly;
/// iPad reads GitHub over REST with a token from the Keychain.
@MainActor
public final class OracleStore: ObservableObject {
    @Published public private(set) var panes: [AgentPane] = []
    @Published public private(set) var tree: [StatusRow] = []
    @Published public private(set) var work: [WorkItem] = []
    @Published public private(set) var spaces: [HerdrSpace] = []
    private var lastLs: Data?
    @Published public private(set) var prs: [GHItem] = []
    @Published public private(set) var issues: [GHItem] = []
    @Published public private(set) var inbox: [InboxItem] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var problems: [String] = []
    @Published public var lastDrop: String?

    public let config: OracleConfig
    private var timer: Timer?

    public init(config: OracleConfig) { self.config = config }

    public func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    public func refresh() async {
        var issuesSeen: [String] = []
        #if os(macOS)
        async let t = loadTree()
        async let g = loadGitHubCLI()
        let path = config.inboxPath
        async let ib = Task.detached(priority: .utility) { OracleStore.scanInbox(path) }.value   // off the main thread
        let (tree, gh, inbox) = await (t, g, ib)
        if let tree { self.tree = tree.rows; self.panes = tree.panes } else { issuesSeen.append("maw / herdr not answering") }
        if let gh { self.prs = gh.0; self.issues = gh.1 } else { issuesSeen.append("gh failed — run `gh auth status`") }
        self.activity = await loadActivity().map { a in
            var a = a
            if let prev = statusSince[a.place], prev.status == a.status { a.since = prev.since }
            else { a.since = Date(); statusSince[a.place] = (a.status, a.since!) }
            return a
        }
        if let ls = lastLs {
            let porcelain = await Shell.run("git", ["-C", config.localPath, "worktree", "list", "--porcelain"]) ?? ""
            let repoName = (config.localPath as NSString).lastPathComponent
            self.work = WorkParse.items(ls: ls, locks: WorkParse.lockReasons(porcelain), activity: activity, prs: prs,
                                        localPath: config.localPath,
                                        extraRoots: [NSHomeDirectory() + "/.herdr/worktrees/" + repoName])
        }
        self.inbox = inbox
        recomputeUnread()
        #else
        if let gh = await loadGitHubREST() { self.prs = gh.0; self.issues = gh.1 }
        else { issuesSeen.append("Add a GitHub token in Settings to see PRs and issues") }
        #endif
        problems = issuesSeen
        lastRefresh = Date()
        publishSnapshot()
    }

    #if os(macOS)
    /// Bring a worktree's herdr space to Nat: focus it in herdr, then move its WezTerm window to the main
    /// display and focus it (the ARRA Oracles path — WezTerm.show).
    public func bringToMain(_ item: WorkItem) {
        let space = spaces.first { $0.checkout == item.path || (item.isMain && $0.checkout == nil && $0.label == item.folder) }
            ?? item.panes.first.flatMap { p in spaces.first { s in s.panes.contains { $0.place == p.place } } }
        guard let space else { return }
        Task.detached {
            _ = await Shell.run("herdr", ["--session", space.session, "workspace", "focus", space.workspaceId])
            await WezTerm.show(session: space.session, label: space.label)
            // the terminal is now on the main display, raised; the app comes back on top of it (Nat: "bring the app on top")
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run { NSApp.activate(ignoringOtherApps: true); NSApp.mainWindow?.orderFrontRegardless() }
        }
    }
    #endif

    #if os(macOS)
    /// Prompt one of this oracle's agents: `maw herdr hey --session <s> <pane> <message>`.
    public func hey(place: String, message: String) async -> Bool {
        let parts = place.split(separator: ":", maxSplits: 1).map(String.init)    // "laris-co:w22:p2"
        guard parts.count == 2 else { return false }
        return await Shell.run("maw", ["herdr", "hey", "--session", parts[0], parts[1], message], timeout: 20) != nil
    }
    #endif
    /// The same send as a command Nat can paste when the app could not deliver it.
    public nonisolated static func heyCommand(place: String, message: String) -> String {
        let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
        let quoted = "'" + message.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return parts.count == 2 ? "maw herdr hey --session \(parts[0]) \(parts[1]) \(quoted)" : "maw herdr hey \(place) \(quoted)"
    }

    /// Draft → GitHub issue through gh (macOS). The sheet that calls this is the human's confirm step.
    public func createIssue(title: String, body: String) async -> String? {
        #if os(macOS)
        let out = await Shell.run("gh", ["issue", "create", "-R", config.repoSlug, "--title", title, "--body", body], timeout: 30)
        if let url = out?.split(separator: "\n").last.map(String.init), url.contains("/issues/") {
            lastDrop = "created issue #" + (url.split(separator: "/").last.map(String.init) ?? "?")
            await refresh()
            return url
        }
        problems.append("gh issue create failed — run: gh auth status && gh issue create -R \(config.repoSlug)")
        #endif
        return nil
    }

    /// Title and body for an issue made from dropped links or files; small text files travel inside it.
    public nonisolated static func issueDraft(_ urls: [URL], oracle: String) -> (title: String, body: String) {
        let title: String
        if let u = urls.first {
            title = u.isFileURL ? "Look at \(u.lastPathComponent)" : "Look at \(u.host ?? "")\(u.path == "/" ? "" : u.path)"
        } else { title = "" }
        var lines = urls.map { u in u.isFileURL ? "- file: `\(u.path)`" : "- link: <\(u.absoluteString)>" }
        for u in urls where u.isFileURL && ["md", "txt"].contains(u.pathExtension.lowercased()) {
            if let d = try? Data(contentsOf: u), d.count < 8_000, let t = String(data: d, encoding: .utf8) {
                lines.append("\n<details><summary>\(u.lastPathComponent)</summary>\n\n```\n\(t)\n```\n</details>")
            }
        }
        let f = ISO8601DateFormatter(); f.timeZone = .current
        lines.append("\n_Dropped into the \(oracle) app, \(f.string(from: Date()))._")
        return (String(title.prefix(120)), lines.joined(separator: "\n"))
    }

    @Published public private(set) var activity: [OracleSnapshot.Activity] = []
    @Published public private(set) var unread: Set<String> = []
    private var readState = ReadState()
    private var statusSince: [String: (status: String, since: Date)] = [:]

    /// Hand the widget its numbers, then ask WidgetKit to redraw.
    private func publishSnapshot() {
        let rank = ["blocked": 0, "done": 1, "working": 2, "idle": 3]
        let acts = activity.sorted { (rank[$0.status] ?? 4, $0.place) < (rank[$1.status] ?? 4, $1.place) }
        let dayAgo = Date().addingTimeInterval(-86_400)
        let handoff = inbox.first { $0.folder == "handoff" }.map { OracleStore.prettify($0.name) }
        let snap = OracleSnapshot(name: config.name, colorHex: config.colorHex, symbol: config.symbol,
                                  working: acts.filter { $0.status == "working" }.count,
                                  panes: acts.count, prs: prs.count, issues: issues.count, inbox: inbox.count,
                                  topPR: prs.first.map { "#\($0.number) \($0.title)" }, updated: Date(),
                                  needsYou: acts.filter { $0.status == "blocked" || $0.status == "done" }.count,
                                  activity: Array(acts.prefix(4)),
                                  prTitles: prs.prefix(3).map { "#\($0.number) \($0.title)" },
                                  inboxNew: inbox.filter { $0.modified > dayAgo }.count,
                                  latestHandoff: handoff,
                                  inboxUnread: unread.count,
                                  unreadTitles: inbox.filter { unread.contains($0.path) }.prefix(3).map { OracleStore.prettify($0.name) })
        SnapshotStore.write(snap, config: config)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// "2026-10-05_13-47_fido-key-blocked-on-hardware.md" → "fido key blocked on hardware"
    nonisolated static func prettify(_ file: String) -> String {
        var s = (file as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}[_-]?(\d{2}[-_:]?\d{2}([-_:]?\d{2})?[_-]?)?"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // MARK: unread
    /// Unread = changed after the baseline (first launch) and not opened since. A 4,000-file inbox must not
    /// start as 4,000 unread, so everything already there on first launch counts as read.
    struct ReadState: Codable {
        var baseline: Date = Date()
        var read: [String: Date] = [:]          // path → modification date when it was read
        var forcedUnread: Set<String>? = []     // "Mark as unread", even for files older than the baseline
    }
    private var readURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OracleKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(config.name.lowercased())-read.json")
    }
    private func loadReadState() {
        if let d = try? Data(contentsOf: readURL), let s = try? JSONDecoder().decode(ReadState.self, from: d) { readState = s }
        else { readState = ReadState(); saveReadState() }
    }
    private func saveReadState() { if let d = try? JSONEncoder().encode(readState) { try? d.write(to: readURL, options: .atomic) } }
    private func recomputeUnread() {
        if readState.read.isEmpty && !FileManager.default.fileExists(atPath: readURL.path) { loadReadState() }
        let forced = readState.forcedUnread ?? []
        unread = Set(inbox.filter { item in
            forced.contains(item.path)
            || (item.modified > readState.baseline && (readState.read[item.path].map { $0 < item.modified } ?? true))
        }.map(\.path))
    }
    public func isUnread(_ item: InboxItem) -> Bool { unread.contains(item.path) }
    public func markRead(_ item: InboxItem) {
        readState.read[item.path] = item.modified; readState.forcedUnread?.remove(item.path)
        saveReadState(); recomputeUnread(); publishSnapshot()
    }
    public func markUnread(_ item: InboxItem) {
        readState.read[item.path] = nil
        if readState.forcedUnread == nil { readState.forcedUnread = [] }
        readState.forcedUnread?.insert(item.path)
        saveReadState(); recomputeUnread(); publishSnapshot()
    }
    public func markAllRead() {
        for i in inbox where unread.contains(i.path) { readState.read[i.path] = i.modified }
        readState.forcedUnread = []
        saveReadState(); recomputeUnread(); publishSnapshot()
    }

    #if os(macOS)
    /// One `maw herdr ls` pair (≈0.6 s for every session) instead of one herdr call per session.
    private func loadTree() async -> (rows: [StatusRow], panes: [AgentPane])? {
        async let ls = Shell.run("maw", ["herdr", "ls", "--json"], timeout: 15)
        async let ag = Shell.run("maw", ["herdr", "ls", "--agents", "--json"], timeout: 15)
        if let l = await ls, let a = await ag {
            lastLs = Data(l.utf8)
            let rows = MawParse.rows(ls: Data(l.utf8), agents: Data(a.utf8), localPath: config.localPath)
            let panes = rows.filter { $0.depth == 2 }.map {
                AgentPane(session: "", paneId: $0.id, name: $0.title, agent: "", status: $0.status, cwd: "", title: $0.title) }
            return (rows, panes)
        }
        guard let panes = await loadPanes() else { return nil }      // fallback: herdr directly
        return (panes.map { StatusRow(id: $0.id, depth: 2, glyph: "", live: $0.status == "working",
                                      title: "\($0.agent)  \($0.name)", detail: "\($0.session):\($0.paneId) · \($0.status)", status: $0.status) }, panes)
    }

    /// Each pane's current task: herdr's terminal title (Claude Code titles a session by its topic).
    /// A pane named after the oracle carries no task, so fall back to its tab label.
    private func loadActivity() async -> [OracleSnapshot.Activity] {
        guard let table = await Shell.run("herdr", ["session", "list"]) else { return [] }
        let repoName = (config.localPath as NSString).lastPathComponent
        let herdrWT = NSHomeDirectory() + "/.herdr/worktrees/" + repoName
        var out: [OracleSnapshot.Activity] = []
        var found: [HerdrSpace] = []
        for s in HerdrParse.runningSessions(table: table) {
            // one call per session gives both the agents and herdr's own layout (spaces · tabs · split rects)
            guard let json = await Shell.run("herdr", ["--session", s, "api", "snapshot"]) else { continue }
            let snap = HerdrSnapshot.parse(Data(json.utf8), session: s)
            found += HerdrSnapshot.mine(snap.spaces, roots: [config.localPath, herdrWT])
            for a in snap.agents {
                let cwd = a["cwd"] as? String ?? ""
                guard HerdrParse.belongs(AgentPane(session: s, paneId: "", name: "", agent: "", status: "", cwd: cwd, title: ""), to: config.localPath)
                        || cwd == herdrWT || cwd.hasPrefix(herdrWT + "/") else { continue }
                let pane = a["pane_id"] as? String ?? "?"
                var title = (a["terminal_title_stripped"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let generic = title.isEmpty || title == (a["name"] as? String) || title.lowercased() == repoName.lowercased()
                    || title == "Claude Code" || title == "zsh"
                let sid = (a["agent_session"] as? [String: Any])?["value"] as? String
                if generic {
                    // what was last asked of this pane: its own transcript's last typed prompt
                    if (a["agent"] as? String) == "claude", let sid, let ask = OracleStore.lastPrompt(cwd: cwd, session: sid) {
                        title = ask
                    } else {
                        let inWT = cwd.hasPrefix(config.localPath + "/wt/") || cwd.hasPrefix(herdrWT + "/")
                        let leaf = (cwd as NSString).lastPathComponent
                        title = inWT ? (leaf.hasPrefix("worktree") ? leaf : "worktree " + leaf) : "\(config.name) main"
                    }
                }
                out.append(.init(title: title, status: a["agent_status"] as? String ?? "idle", place: "\(s):\(pane)", cwd: cwd, session: sid))
            }
        }
        spaces = found
        return out
    }

    /// Last prompt a human (or agent) typed into a Claude session: the tail of
    /// ~/.claude/projects/<cwd with / and . as ->/<session>.jsonl, cached by file size.
    nonisolated(unsafe) static var promptCache: [String: (size: UInt64, prompt: String?)] = [:]
    /// One line of what a human asked, or nil for machine traffic (pane reports, agent relays, wrappers).
    nonisolated static func humanAsk(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // a slash command: <command-name>/impeccable</command-name> … <command-args>styling …</command-args>
        if let n = s.range(of: #"<command-name>[^<]*</command-name>"#, options: .regularExpression) {
            let name = s[n].replacingOccurrences(of: #"</?command-name>"#, with: "", options: .regularExpression)
            var args = ""
            if let r = s.range(of: #"<command-args>[\s\S]*?</command-args>"#, options: .regularExpression) {
                args = s[r].replacingOccurrences(of: #"</?command-args>"#, with: "", options: .regularExpression)
            }
            s = (name + " " + args).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // pasted text: keep the inside, unless it is a pane/terminal report
        if s.hasPrefix("<pasted_content") {
            s = s.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let machine = ["<", "PANE ", "TERMINAL ", "[from ", "[reply", "[CHECK-IN", "[checkin", "[SYSTEM", "[Request interrupted",
                       "Caveat:", "[Image", "Another Claude session", "This session is being continued", "Tool loaded",
                       "Base directory for this skill", "(Re-invocation of", "Concise output style"]
        if s.isEmpty || machine.contains(where: { s.hasPrefix($0) }) { return nil }
        s = String(s.split(separator: "\n").first ?? "")
        s = s.replacingOccurrences(of: #"^[❯>$#]\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    nonisolated static func lastPrompt(cwd: String, session: String) -> String? {
        let dir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let path = NSHomeDirectory() + "/.claude/projects/" + dir + "/" + session + ".jsonl"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        if let c = promptCache[path], c.size == size { return c.prompt }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        // Walk back in 2 MB steps (up to 24 MB): a busy session's tail is mostly tool output and screenshots.
        let step: UInt64 = 2 * 1024 * 1024, cap: UInt64 = 24 * 1024 * 1024
        var end = size, found: String?
        var carry = Data()
        while found == nil && end > 0 && size - end < cap {
            let start = end > step ? end - step : 0
            try? fh.seek(toOffset: start)
            var chunk = fh.readData(ofLength: Int(end - start)) + carry
            // keep the partial first line for the next (earlier) chunk
            if start > 0, let nl = chunk.firstIndex(of: 0x0A) {
                carry = chunk.subdata(in: chunk.startIndex..<nl); chunk = chunk.subdata(in: nl..<chunk.endIndex)
            } else { carry = Data() }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"type\":\"user\""), !line.contains("\"tool_result\""),
                      let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let m = o["message"] as? [String: Any] else { continue }
                var t: String?
                if let c = m["content"] as? String { t = c }
                else if let parts = m["content"] as? [[String: Any]] {
                    t = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.first
                }
                guard let raw = t, let s = OracleStore.humanAsk(raw) else { continue }
                found = s.count > 70 ? String(s.prefix(69)) + "…" : s
                break
            }
            end = start
        }
        promptCache[path] = (size, found)
        return found
    }

    private func loadPanes() async -> [AgentPane]? {
        guard let table = await Shell.run("herdr", ["session", "list"]) else { return nil }
        var all: [AgentPane] = []
        for s in HerdrParse.runningSessions(table: table) {
            if let out = await Shell.run("herdr", ["--session", s, "agent", "list"]) {
                all += HerdrParse.agents(json: Data(out.utf8), session: s).filter { HerdrParse.belongs($0, to: config.localPath) }
            }
        }
        return all.sorted { ($0.status, $0.paneId) < ($1.status, $1.paneId) }
    }

    private func loadGitHubCLI() async -> ([GHItem], [GHItem])? {
        async let pr = Shell.run("gh", ["pr", "list", "-R", config.repoSlug, "--state", "open", "--limit", "50",
                                        "--json", "number,title,author,updatedAt,url,isDraft,headRefName,closingIssuesReferences"], timeout: 20)
        async let iss = Shell.run("gh", ["issue", "list", "-R", config.repoSlug, "--state", "open", "--limit", "50",
                                         "--json", "number,title,author,updatedAt,url"], timeout: 20)
        guard let a = await pr, let b = await iss else { return nil }
        return (GHParse.items(json: Data(a.utf8)), GHParse.items(json: Data(b.utf8)))
    }

    private func loadInbox() -> [InboxItem] { OracleStore.scanInbox(config.inboxPath) }

    /// Newest 300 files, at most 2 folders deep. Runs off the main thread: neo's inbox holds 4,000+ entries.
    nonisolated public static func scanInbox(_ root: String) -> [InboxItem] {
        guard !root.isEmpty, let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var items: [InboxItem] = []
        while let rel = e.nextObject() as? String {
            if e.level > 2 { e.skipDescendants(); continue }
            let full = root + "/" + rel
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &dir), !dir.boolValue,
                  !rel.hasPrefix("."), !(rel as NSString).lastPathComponent.hasPrefix(".") else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            let folder = rel.contains("/") ? String(rel.split(separator: "/").first!) : "inbox"
            items.append(InboxItem(path: full, name: (rel as NSString).lastPathComponent, folder: folder,
                                   modified: attrs?[.modificationDate] as? Date ?? .distantPast))
        }
        return items.sorted { $0.modified > $1.modified }.prefix(300).map { $0 }
    }

    /// Files dropped on the Dock icon or the window land in ψ/inbox/dropped/, date-stamped, never overwritten.
    /// One copy per drop: the app delegate and the window both call this, never the views of every window.
    @discardableResult
    public func receive(_ urls: [URL]) -> Int {
        let n = OracleStore.copyIntoInbox(urls, config: config)
        noteDrop(n)
        return n
    }

    public func noteDrop(_ n: Int) {
        lastDrop = n > 0 ? "\(n) file\(n == 1 ? "" : "s") → ψ/inbox/dropped" : "drop failed"
        inbox = loadInbox()
        recomputeUnread()
        publishSnapshot()
    }

    nonisolated public static func copyIntoInbox(_ urls: [URL], config: OracleConfig) -> Int {
        guard !config.inboxPath.isEmpty else { return 0 }
        let dest = URL(fileURLWithPath: config.inboxPath + "/dropped")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = f.string(from: Date())
        var n = 0
        for u in urls {
            var target = dest.appendingPathComponent("\(stamp)_\(u.lastPathComponent)")
            var i = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = dest.appendingPathComponent("\(stamp)_\(i)_\(u.lastPathComponent)"); i += 1
            }
            let scheme = (u.scheme ?? "").lowercased()
            guard u.isFileURL || scheme == "http" || scheme == "https" else { continue }   // never our own oracle-* links
            if u.isFileURL {
                if (try? FileManager.default.copyItem(at: u, to: target)) != nil { n += 1 }
            } else {
                // a web link (browser address bar, bookmark, tab): keep it as a small markdown note
                let slug = ((u.host ?? "link") + u.path).replacingOccurrences(of: "/", with: "-")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(80)
                let note = dest.appendingPathComponent("\(stamp)_\(slug).md")
                let body = "# \(u.absoluteString)\n\n- url: <\(u.absoluteString)>\n- dropped: \(stamp)\n- for: \(config.name)\n"
                if (try? body.write(to: note, atomically: true, encoding: .utf8)) != nil { n += 1 }
            }
        }
        return n
    }
    #else
    @discardableResult public func receive(_ urls: [URL]) -> Int { 0 }

    private func loadGitHubREST() async -> ([GHItem], [GHItem])? {
        guard let token = TokenStore.read(), !token.isEmpty else { return nil }
        func get(_ path: String) async -> Data? {
            var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(config.repoSlug)/\(path)")!)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return d
        }
        guard let p = await get("pulls?state=open&per_page=50"), let i = await get("issues?state=open&per_page=50") else { return nil }
        // the issues endpoint also returns PRs; keep real issues only
        let issuesJSON = (try? JSONSerialization.jsonObject(with: i) as? [[String: Any]])?.filter { $0["pull_request"] == nil } ?? []
        let issuesData = (try? JSONSerialization.data(withJSONObject: issuesJSON)) ?? Data("[]".utf8)
        return (GHParse.items(json: p), GHParse.items(json: issuesData))
    }
    #endif
}

#if os(iOS)
import Security
/// The iPad keeps a GitHub token (read-only scope is enough) in the Keychain.
public enum TokenStore {
    static let account = "github-token", service = "co.laris.oracle.kit"
    public static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
    public static func write(_ token: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
