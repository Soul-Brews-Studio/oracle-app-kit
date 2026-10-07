import Foundation
#if os(macOS)
import AppKit
#else
import Combine
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Live state of one oracle, refreshed on a timer. macOS reads herdr, gh and ψ/ directly;
/// iPhone and iPad ask their paired Mac app (the companion API), or read GitHub over REST with a token from the Keychain.
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
    /// What the paired Mac last answered, as it sent it (iPhone/iPad; the Mac app IS the server and leaves both nil).
    @Published public private(set) var companionWork: CompanionAPI.Work?
    @Published public private(set) var companionInbox: CompanionAPI.Inbox?
    @Published public var lastDrop: String?

    public let config: OracleConfig
    private var timer: Timer?

    public init(config: OracleConfig) { self.config = config }

    public func start() {
        #if os(macOS)
        Task { await refresh() }
        #else
        // `-companionPair <link>` on the launch line pairs first; once that is settled, a pairing change refreshes at once
        CompanionClient.shared.device = PhoneStyle.device   // the Mac's trace says "iPad · companion"
        Task { await pairFromLaunchArgument(); watchCompanion(); await refresh() }
        #endif
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
        // Ask the Mac once it has answered hello with this pairing, else GitHub. If that stops being true while the answers
        // are on the way (Unpair, another Pair…, a refused hello), they are not the phone's to show any more: return without
        // touching the pages, the problems or the widget — the refresh that the change started owns them.
        let client = CompanionClient.shared
        let mac = client.verifiedPairing
        var answered = true                                  // false: the Mac answered none of work, GitHub, inbox
        if let mac {
            guard let got = await loadCompanion(mac) else { return }
            issuesSeen += got.seen; answered = got.answered
        } else {
            forgetCompanion()
            let gh = await loadGitHubREST()
            guard client.verifiedPairing == nil else { return }  // the phone paired while GitHub was answering
            if let gh { self.prs = gh.0; self.issues = gh.1 }
            else { issuesSeen.append("Add a GitHub token in Settings to see PRs and issues") }
            // a -companionPair that did not take says why, with its fix. A pairing tried in the sheet says so there — its
            // problem is not repeated here on every tick after the sheet is gone
            if let p = launchPairProblem { issuesSeen.append(p) }
        }
        #endif
        problems = issuesSeen
        #if os(macOS)
        lastRefresh = Date()
        #else
        if answered { lastRefresh = Date() }                 // the widget's "updated" is the last time the Mac answered
        // nothing has answered since launch (the Mac asleep, away, or its token rotated): the widget keeps the last snapshot
        // the Mac's answers made, rather than empty counts stamped "now"
        guard answered || lastRefresh != nil else { return }
        #endif
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
                                  topPR: prs.first.map { "#\($0.number) \($0.title)" }, updated: lastRefresh ?? Date(),   // the last refresh that got answers
                                  needsYou: acts.filter { $0.status == "blocked" || $0.status == "done" }.count,
                                  activity: Array(acts.prefix(4)),
                                  prTitles: prs.prefix(3).map { "#\($0.number) \($0.title)" },
                                  inboxNew: inbox.filter { $0.modified > dayAgo }.count,
                                  latestHandoff: handoff,
                                  inboxUnread: unread.count,
                                  unreadTitles: inbox.filter { unread.contains($0.path) }.prefix(3).map { OracleStore.prettify($0.name) })
        SnapshotStore.write(snap, config: config) {   // off the main thread; reload once it's on disk
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
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
        return dir.appendingPathComponent("\(config.appKey)-read.json")
    }
    private func loadReadState() {
        if let d = try? Data(contentsOf: readURL), let s = try? JSONDecoder().decode(ReadState.self, from: d) { readState = s }
        else { readState = ReadState(); saveReadState() }
    }
    private func saveReadState() { if let d = try? JSONEncoder().encode(readState) { try? d.write(to: readURL, options: .atomic) } }
    private func recomputeUnread() {
        if readState.read.isEmpty && !FileManager.default.fileExists(atPath: readURL.path) { loadReadState() }
        #if !os(macOS)
        // Paired: the Mac's own flags (its baseline, its reads), less what this phone has opened since — the same set the
        // Inbox page, the sidebar badge and the widget count
        if let mac = companionInbox {
            unread = Set(mac.items.filter { $0.unread && !hasRead(path: $0.path, modified: $0.modified) }.map(\.path))
            return
        }
        #endif
        let forced = readState.forcedUnread ?? []
        unread = Set(inbox.filter { item in
            forced.contains(item.path)
            || (item.modified > readState.baseline && (readState.read[item.path].map { $0 < item.modified } ?? true))
        }.map(\.path))
    }
    public func isUnread(_ item: InboxItem) -> Bool { unread.contains(item.path) }
    /// Opened here since it last changed.
    public func hasRead(path: String, modified: Date) -> Bool { readState.read[path].map { $0 >= modified } ?? false }
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

    // MARK: the paired Mac (issue #46)
    private var companionWatch: AnyCancellable?
    private var launchPairTried = false
    private var launchPairProblem: String?
    private var companionMac: CompanionAPI.Pairing?     // the Mac that prs, issues, activity and inbox came from; nil = GitHub or none yet

    /// Paired with `mac` (it has answered hello): it answers work, GitHub and inbox at once. What it fails to answer keeps
    /// its last good value (a tunnel must not blank the pages) and comes back as a problem with the Mac's own fix.
    /// nil when the phone let go of this Mac while it was answering — its answers are not the phone's to show any more.
    private func loadCompanion(_ mac: CompanionAPI.Pairing) async -> (seen: [String], answered: Bool)? {
        let client = CompanionClient.shared
        async let w = ask("work") { await client.work() }
        async let g = ask("github") { await client.github() }
        async let i = ask("inbox") { await client.inbox() }
        let (work, workProblem) = await w
        let (gh, ghProblem) = await g
        let (inbox, inboxProblem) = await i
        guard client.pairing == mac else { return nil }
        if let other = companionMac, other != mac { forgetCompanion() }   // another Mac's pages must not fill gaps in this one's
        var seen = work?.problems ?? []                            // what the Mac itself could not read
        for p in [workProblem, ghProblem, inboxProblem, client.problem] { if let p, !seen.contains(p) { seen.append(p) } }
        if let work {
            companionWork = work
            activity = work.activity.map { OracleSnapshot.Activity(title: $0.title, status: $0.status, place: $0.place, since: $0.since, cwd: $0.cwd) }
        }
        if let gh { prs = gh.prs.map(OracleStore.ghItem); issues = gh.issues.map(OracleStore.ghItem) }
        // the Mac's worktrees as the pages already know them, so an issue card on the phone says whether it has one
        if let work { self.work = work.items.map { OracleStore.workItem($0, prs: prs) } }
        if let inbox {
            companionInbox = inbox
            self.inbox = inbox.items.map { InboxItem(path: $0.path, name: $0.name, folder: $0.folder, modified: $0.modified) }
            recomputeUnread()                                      // the Mac's flags, less what this phone opened
        }
        companionMac = mac
        return (seen, work != nil || gh != nil || inbox != nil)
    }

    /// One call to the Mac and, if it failed, the problem it left. `client.problem` is a single slot that the next
    /// success clears, so it is read the moment the call returns — never after the other two calls have had their say.
    /// `@MainActor` on the closure keeps the call and the read in one stretch: a plain `() async -> T?` is a nonisolated
    /// thunk, and the hop back to the main actor is a new job that another call's success can run before.
    private func ask<T: Sendable>(_ what: String, _ call: @MainActor () async -> T?) async -> (T?, String?) {
        let answer = await call()
        guard answer == nil else { return (answer, nil) }
        return (nil, CompanionClient.shared.problem ?? "the Mac did not answer \(what) — Settings → Companion → Check")
    }

    /// Unpaired (Unpair was just tapped) or paired with another Mac: nothing the old Mac said stays on screen or in the widget.
    private func forgetCompanion() {
        guard companionMac != nil else { return }
        companionMac = nil
        companionWork = nil; companionInbox = nil
        activity = []; prs = []; issues = []; inbox = []; work = []
        recomputeUnread()
    }

    /// The Mac's worktree as the pages already know it: its issue and branch tie it to a card, its panes give its state.
    /// The resume command stays the Mac's (companionWork has it); the phone does not rebuild it.
    nonisolated private static func workItem(_ w: CompanionAPI.WorkItem, prs: [GHItem]) -> WorkItem {
        let maw = ["resumable": "resumable", "cold": "cold"][w.state] ?? "open"
        return WorkItem(path: w.path, isMain: w.isMain, slug: w.slug ?? w.folder, folder: w.folder, branch: w.branch, born: w.born, issue: w.issue,
                        pr: w.prNumber.flatMap { n in prs.first { $0.number == n } }, mawState: maw,
                        panes: w.panes.map { OracleSnapshot.Activity(title: $0.title, status: $0.status, place: $0.place, since: $0.since, cwd: $0.cwd) },
                        resumeId: nil)
    }

    /// The Mac's PR or issue as the pages already know it: a PR links to a worktree by its branch or by the issues it closes.
    nonisolated private static func ghItem(_ e: CompanionAPI.GHEntry) -> GHItem {
        var g = GHItem(number: e.number, title: e.title, author: e.author, updatedAt: e.updatedAt, url: e.url, isDraft: e.isDraft, branch: e.branch)
        g.closes = e.closes ?? []
        return g
    }

    /// `-companionPair <link>` on the launch line pairs before the first refresh (the simulator checks start this way).
    private func pairFromLaunchArgument() async {
        guard !launchPairTried, let raw = UserDefaults.standard.string(forKey: "companionPair") else { return }
        launchPairTried = true
        guard let found = CompanionPairLink.find(in: raw) else {
            launchPairProblem = "-companionPair is not a pairing link — copy it on the Mac: \(config.name) → Settings → Companion → Copy link"
            return
        }
        if let why = CompanionPairLink.mismatch(found, oracle: config) { launchPairProblem = why; return }   // the sheet's check too
        if !(await CompanionClient.shared.pair(found.pairing)) { launchPairProblem = CompanionClient.shared.problem }
    }

    /// A new pairing, an Unpair, a refused pairing put back, a hello that arrived: refresh at once, so the pages do not wait
    /// for the next 20 s tick to fill or empty. Every hello counts, equal or not — the Mac that answers a re-pair (a rotated
    /// token) sends the hello it sent before — and an Unpair with the Mac unreachable changes the pairing, never the hello.
    private func watchCompanion() {
        guard companionWatch == nil else { return }
        let client = CompanionClient.shared
        companionWatch = client.$pairing.removeDuplicates().dropFirst().map { _ in () }
            .merge(with: client.$hello.dropFirst().map { _ in () })
            .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }

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
