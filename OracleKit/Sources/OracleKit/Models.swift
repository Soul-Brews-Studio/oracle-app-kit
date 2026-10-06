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
            return GHItem(number: n, title: t, author: author, updatedAt: date, url: url, isDraft: draft)
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
