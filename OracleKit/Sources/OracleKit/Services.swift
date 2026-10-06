import Foundation

/// Live state of one oracle, refreshed on a timer. macOS reads herdr, gh and ψ/ directly;
/// iPad reads GitHub over REST with a token from the Keychain.
@MainActor
public final class OracleStore: ObservableObject {
    @Published public private(set) var panes: [AgentPane] = []
    @Published public private(set) var tree: [StatusRow] = []
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
        self.inbox = inbox
        #else
        if let gh = await loadGitHubREST() { self.prs = gh.0; self.issues = gh.1 }
        else { issuesSeen.append("Add a GitHub token in Settings to see PRs and issues") }
        #endif
        problems = issuesSeen
        lastRefresh = Date()
    }

    #if os(macOS)
    /// One `maw herdr ls` pair (≈0.6 s for every session) instead of one herdr call per session.
    private func loadTree() async -> (rows: [StatusRow], panes: [AgentPane])? {
        async let ls = Shell.run("maw", ["herdr", "ls", "--json"], timeout: 15)
        async let ag = Shell.run("maw", ["herdr", "ls", "--agents", "--json"], timeout: 15)
        if let l = await ls, let a = await ag {
            let rows = MawParse.rows(ls: Data(l.utf8), agents: Data(a.utf8), localPath: config.localPath)
            let panes = rows.filter { $0.depth == 2 }.map {
                AgentPane(session: "", paneId: $0.id, name: $0.title, agent: "", status: $0.status, cwd: "", title: $0.title) }
            return (rows, panes)
        }
        guard let panes = await loadPanes() else { return nil }      // fallback: herdr directly
        return (panes.map { StatusRow(id: $0.id, depth: 2, glyph: "", live: $0.status == "working",
                                      title: "\($0.agent)  \($0.name)", detail: "\($0.session):\($0.paneId) · \($0.status)", status: $0.status) }, panes)
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
                                        "--json", "number,title,author,updatedAt,url,isDraft"], timeout: 20)
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
