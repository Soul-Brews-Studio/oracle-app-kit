import Foundation

public struct AgentPane: Identifiable, Hashable, Sendable {
    public var id: String { session + "/" + paneId }
    public let session: String
    public let paneId: String
    public let name: String
    public let agent: String      // claude, codex, …
    public let status: String     // working, idle, done, blocked, unknown
    public let cwd: String
    public let title: String
}

public struct GHItem: Identifiable, Hashable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let author: String
    public let updatedAt: Date?
    public let url: URL?
    public let isDraft: Bool
    public var branch: String? = nil      // head branch (PRs) — links a PR to its worktree
    public var closes: [Int] = []         // issues the PR closes (PRs) — links a PR to its issue
}

public struct InboxItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let folder: String     // "handoff", "dropped", …
    public let modified: Date
}

/// Parses `herdr agent list` JSON. Pure, so it is unit-tested.
public enum HerdrParse {
    public static func agents(json: Data, session: String) -> [AgentPane] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let list = result["agents"] as? [[String: Any]] else { return [] }
        return list.map { a in
            AgentPane(session: session,
                      paneId: a["pane_id"] as? String ?? "?",
                      name: a["name"] as? String ?? "",
                      agent: a["agent"] as? String ?? "?",
                      status: a["agent_status"] as? String ?? "unknown",
                      cwd: a["cwd"] as? String ?? "",
                      title: a["terminal_title_stripped"] as? String ?? "")
        }
    }

    /// `herdr session list` is a text table: name status directory socket.
    public static func runningSessions(table: String) -> [String] {
        table.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            return cols.count >= 2 && cols[1] == "running" ? String(cols[0]) : nil
        }
    }

    /// Panes that belong to this oracle: their cwd is the checkout or one of its worktrees.
    public static func belongs(_ pane: AgentPane, to localPath: String) -> Bool {
        !localPath.isEmpty && (pane.cwd == localPath || pane.cwd.hasPrefix(localPath + "/"))
    }
}

public enum GHParse {
    /// Parses `gh pr list --json number,title,author,updatedAt,url,isDraft` (issues: same minus isDraft),
    /// and the REST shape (number,title,user.login,updated_at,html_url,draft).
    public static func items(json: Data) -> [GHItem] {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return list.compactMap { o in
            guard let n = o["number"] as? Int, let t = o["title"] as? String else { return nil }
            let author = (o["author"] as? [String: Any])?["login"] as? String
                ?? (o["user"] as? [String: Any])?["login"] as? String ?? ""
            let date = (o["updatedAt"] as? String ?? o["updated_at"] as? String).flatMap { iso.date(from: $0) }
            let url = (o["url"] as? String ?? o["html_url"] as? String).flatMap(URL.init(string:))
            let draft = o["isDraft"] as? Bool ?? o["draft"] as? Bool ?? false
            let branch = o["headRefName"] as? String ?? (o["head"] as? [String: Any])?["ref"] as? String
            let closes = (o["closingIssuesReferences"] as? [[String: Any]])?.compactMap { $0["number"] as? Int } ?? []
            return GHItem(number: n, title: t, author: author, updatedAt: date, url: url, isDraft: draft, branch: branch, closes: closes)
        }
    }
}

/// One indented line of the status tree — the same shape as `maw herdr ls`:
/// checkout → herdr spaces (per session) → agent panes, then linked worktrees.
public struct StatusRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let depth: Int          // 0 checkout/worktree, 1 space, 2 pane
    public let glyph: String       // tree glyph prefix, e.g. "├─", "└─"
    public let live: Bool          // filled dot = running/working
    public let title: String
    public let detail: String
    public let status: String
}

/// Builds StatusRows from `maw herdr ls --json` and `maw herdr ls --agents --json`. Pure → unit-tested.
public enum MawParse {
    public static func rows(ls: Data, agents: Data, localPath: String) -> [StatusRow] {
        guard !localPath.isEmpty,
              let l = try? JSONSerialization.jsonObject(with: ls) as? [String: Any],
              let a = try? JSONSerialization.jsonObject(with: agents) as? [String: Any] else { return [] }
        let wts = (l["worktrees"] as? [[String: Any]] ?? []).filter {
            let p = $0["path"] as? String ?? ""; return p == localPath || p.hasPrefix(localPath + "/")
        }.sorted { (($0["linked"] as? Bool) == true ? 1 : 0, $0["path"] as? String ?? "") < (($1["linked"] as? Bool) == true ? 1 : 0, $1["path"] as? String ?? "") }
        let spaces = l["workspaces"] as? [[String: Any]] ?? []
        let panes = a["agents"] as? [[String: Any]] ?? []
        var rows: [StatusRow] = []
        for (wi, w) in wts.enumerated() {
            let path = w["path"] as? String ?? ""
            let linked = w["linked"] as? Bool ?? false
            let state = w["state"] as? String ?? "?"
            let name = linked ? (path as NSString).lastPathComponent : (localPath as NSString).lastPathComponent
            let lastWT = wi == wts.count - 1
            rows.append(StatusRow(id: "wt:" + path, depth: 0, glyph: linked ? (lastWT ? "└─" : "├─") : "",
                                  live: state == "running", title: name,
                                  detail: "\(w["branch"] as? String ?? "")  ·  \(state)  ·  \(w["agents"] as? Int ?? 0) agents", status: state))
            let mine = spaces.filter { ($0["checkout"] as? String) == path }
            for (si, s) in mine.enumerated() {
                let sid = s["id"] as? String ?? "?", sess = s["session"] as? String ?? "?"
                let lastS = si == mine.count - 1
                rows.append(StatusRow(id: "sp:\(sess):\(sid)", depth: 1, glyph: lastS ? "└─" : "├─",
                                      live: (s["status"] as? String) == "working",
                                      title: "space \(s["label"] as? String ?? sid)",
                                      detail: "\(sess):\(sid)  ·  \(s["status"] as? String ?? "")  ·  \(s["panes"] as? Int ?? 0) panes",
                                      status: s["status"] as? String ?? ""))
                let ps = panes.filter { ($0["session"] as? String) == sess && ($0["pane"] as? String ?? "").hasPrefix(sid + ":") }
                for (pi, p) in ps.enumerated() {
                    let st = p["status"] as? String ?? "?"
                    rows.append(StatusRow(id: "pn:\(sess):\(p["pane"] as? String ?? "")", depth: 2, glyph: pi == ps.count - 1 ? "└─" : "├─",
                                          live: st == "working",
                                          title: "\(p["agent"] as? String ?? "?")  \((p["name"] as? String) ?? "")",
                                          detail: "\(p["pane"] as? String ?? "")  ·  \(st)  ·  tab \(p["tabLabel"] as? String ?? "")",
                                          status: st))
                }
            }
        }
        return rows
    }
}

// MARK: - Work items (the /herdr-wt model)

/// One piece of work = one /herdr-wt worktree <repo>/wt/<slug>-<oracle>-<date>: its issue (from the git lock
/// reason), its branch and PR, its herdr panes and their current task, and how to resume it.
public struct WorkItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let isMain: Bool
    public let slug: String
    public let folder: String
    public let branch: String
    public let born: Date?
    public let issue: Int?
    public let pr: GHItem?
    public let mawState: String               // running · open · resumable · cold
    public let panes: [OracleSnapshot.Activity]
    public let resumeId: String?
    public var resumeProvider: String? = nil

    public enum State: Int, Comparable, Sendable {
        case needsYou, working, open, resumable, cold
        public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
        public var label: String { ["needs you", "working", "open", "resumable", "cold"][rawValue] }
    }
    public var state: State {
        if panes.contains(where: { $0.status == "blocked" || $0.status == "done" }) { return .needsYou }
        if panes.contains(where: { $0.status == "working" }) { return .working }
        if mawState == "running" || mawState == "open" || !panes.isEmpty { return .open }
        if mawState == "resumable" || resumeId != nil { return .resumable }
        return .cold
    }
    /// What is happening there, in words: the most urgent pane's task, else the branch.
    public var task: String? {
        let rank = ["blocked": 0, "done": 1, "working": 2, "idle": 3]
        return panes.sorted { (rank[$0.status] ?? 4) < (rank[$1.status] ?? 4) }.first?.title
    }
    public var resumeCommand: String? {
        guard let id = resumeId else { return nil }
        return "cd '\(path)' && " + (resumeProvider == "codex" ? "codex resume \(id)" : "claude --resume \(id)")
    }
}

public enum WorkParse {
    /// git worktree list --porcelain → path : lock reason
    public static func lockReasons(_ porcelain: String) -> [String: String] {
        var out: [String: String] = [:]; var cur: String?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { cur = String(line.dropFirst(9)) }
            else if line.hasPrefix("locked "), let c = cur { out[c] = String(line.dropFirst(7)) }
        }
        return out
    }
    /// "herdr|beta@m5|2026-09-29T12:24:26+07:00|heartrate-ble|#11|herdr-send" → (slug, issue, born)
    public static func parseLock(_ reason: String) -> (slug: String?, issue: Int?, born: Date?) {
        let f = reason.split(separator: "|").map(String.init)
        guard f.first == "herdr" else { return (nil, nil, nil) }
        let born = f.count > 2 ? ISO8601DateFormatter().date(from: f[2]) : nil
        let slug = f.count > 3 ? f[3] : nil
        let issue = f.dropFirst(4).first { $0.hasPrefix("#") }.flatMap { Int($0.dropFirst()) }
        return (slug, issue, born)
    }
    /// The /herdr-wt folder is <slug>-<oracle>[-issueN]-<date> (before 09-27: <oracle>-<slug>-<date>):
    /// "heartrate-ble-nexus-issue11-29sep-tue2026" → ("heartrate-ble", 11, 2026-09-29)
    public static func parseFolder(_ folder: String, oracle: String) -> (slug: String, issue: Int?, born: Date?) {
        var s = folder, issue: Int?, born: Date?
        if let m = match(#"-(\d{1,2})([a-z]{3})-[a-z]{3}(\d{4})$"#, in: s) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            if let d = Int(m.groups[0]), let mo = months.firstIndex(of: m.groups[1]), let y = Int(m.groups[2]) {
                born = Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: mo + 1, day: d))
            }
            s.removeSubrange(m.range)
        }
        if let m = match(#"(^|-)issue-?(\d+)(?=-|$)"#, in: s) { issue = Int(m.groups[1]); s.removeSubrange(m.range) }
        if !oracle.isEmpty {
            if s.hasSuffix("-" + oracle) { s.removeLast(oracle.count + 1) }
            else if s.hasPrefix(oracle + "-") { s.removeFirst(oracle.count + 1) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (s.isEmpty ? folder : s, issue, born)
    }
    static func match(_ pattern: String, in s: String) -> (range: Range<String.Index>, groups: [String])? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        return (r, (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" })
    }

    public static func items(ls: Data, locks: [String: String], activity: [OracleSnapshot.Activity],
                             prs: [GHItem], localPath: String, extraRoots: [String] = []) -> [WorkItem] {
        guard !localPath.isEmpty, let l = try? JSONSerialization.jsonObject(with: ls) as? [String: Any] else { return [] }
        let roots = [localPath] + extraRoots
        let wts = (l["worktrees"] as? [[String: Any]] ?? []).filter { w in
            let p = w["path"] as? String ?? ""
            return roots.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
        let paths = wts.compactMap { $0["path"] as? String }
        let repo = (localPath as NSString).lastPathComponent
        let oracle = repo.hasSuffix("-oracle") ? String(repo.dropLast(7)) : repo
        // each pane belongs to the DEEPEST worktree containing its own cwd (not to the space it sits in)
        func owner(_ cwd: String) -> String? {
            paths.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }
        var panesBy: [String: [OracleSnapshot.Activity]] = [:]
        for a in activity { if let c = a.cwd, let o = owner(c) { panesBy[o, default: []].append(a) } }
        let items: [WorkItem] = wts.map { w -> WorkItem in
            let path = w["path"] as? String ?? ""
            let folder = (path as NSString).lastPathComponent
            let lock = parseLock(locks[path] ?? "")
            let isMain = path == localPath
            let name = isMain ? (slug: folder, issue: Int?.none, born: Date?.none) : parseFolder(folder, oracle: oracle)
            let branch = w["branch"] as? String ?? ""
            let resume = w["resume"] as? [String: Any]
            let issue = lock.issue ?? name.issue
            // the PR is the one built from this branch, else the one that closes this tree's issue
            let pr = (branch.isEmpty ? nil : prs.first { $0.branch == branch }) ?? issue.flatMap { n in prs.first { $0.closes.contains(n) } }
            return WorkItem(path: path, isMain: isMain, slug: name.slug,
                            folder: folder, branch: branch, born: lock.born ?? name.born, issue: issue, pr: pr,
                            mawState: w["state"] as? String ?? "cold", panes: panesBy[path] ?? [],
                            resumeId: resume?["id"] as? String, resumeProvider: resume?["provider"] as? String)
        }
        return items.sorted(by: order)
    }
    /// The plain shells a work item owns. A pane with no agent belongs to the DEEPEST work item whose path holds its
    /// cwd — the rule `items` uses for agent panes; a shell cd'd elsewhere stays with its space's checkout. The Mac's
    /// `panesOf` and the phone's `shells(of:)` both read this (#88): their old `cwd.hasPrefix(item.path + "/")` handed
    /// the main checkout every pane under <main>/wt/…, other worktrees' agents included, as "shell" rows.
    public static func shells(of item: WorkItem, work: [WorkItem], spaces: [HerdrSpace]) -> [HerdrPaneBox] {
        let paths = work.map(\.path)
        func owner(_ cwd: String) -> String? { paths.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.max { $0.count < $1.count } }
        let agents = Set(work.flatMap(\.panes).map(\.place))
        return spaces.flatMap { s in
            s.panes.filter { p in
                p.agent == nil && !agents.contains(p.place)
                    && (owner(p.cwd) ?? s.checkout.flatMap { paths.contains($0) ? $0 : nil }) == item.path
            }
        }
    }
    /// An open issue no worktree names yet — where /herdr-wt starts (issue first, then the tree).
    public struct NextIssue: Identifiable, Hashable, Sendable {
        public let issue: GHItem
        public let pr: GHItem?
        public var id: Int { issue.number }
    }
    public static func unstarted(issues: [GHItem], prs: [GHItem], work: [WorkItem]) -> [NextIssue] {
        let taken = Set(work.compactMap(\.issue))
        return issues.filter { !taken.contains($0.number) }
            .map { i in NextIssue(issue: i, pr: prs.first { $0.closes.contains(i.number) }) }
    }
    /// Two panes on one session id write one transcript: place → the pane it duplicates
    /// (the busiest of the group counts as the original).
    public static func twins(_ acts: [OracleSnapshot.Activity]) -> [String: String] {
        let rank = ["working": 0, "blocked": 1, "done": 2, "idle": 3]
        func before(_ a: OracleSnapshot.Activity, _ b: OracleSnapshot.Activity) -> Bool {
            let ra = rank[a.status] ?? 4, rb = rank[b.status] ?? 4
            return ra != rb ? ra < rb : a.place < b.place
        }
        var out: [String: String] = [:]
        for group in Dictionary(grouping: acts.filter { $0.session != nil }, by: { $0.session ?? "" }).values where group.count > 1 {
            let sorted = group.sorted(by: before)
            for g in sorted.dropFirst() { out[g.place] = sorted[0].place }
        }
        return out
    }
    /// needs-you first; the main checkout before its worktrees; newest worktree first
    static func order(_ a: WorkItem, _ b: WorkItem) -> Bool {
        if a.state != b.state { return a.state < b.state }
        if a.isMain != b.isMain { return a.isMain }
        return (a.born ?? .distantPast) > (b.born ?? .distantPast)
    }
}
