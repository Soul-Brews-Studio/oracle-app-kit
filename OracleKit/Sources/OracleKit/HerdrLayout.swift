import Foundation

// MARK: - herdr's own picture of a session: spaces → tabs → panes with their real split rectangles
// Source: `herdr --session S api snapshot` (workspaces · tabs · layouts[].panes[].rect · agents), cells.

public struct HerdrRect: Hashable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    init?(_ o: Any?) {
        guard let d = o as? [String: Any], let w = d["width"] as? Int, let h = d["height"] as? Int else { return nil }
        self.init(x: d["x"] as? Int ?? 0, y: d["y"] as? Int ?? 0, width: w, height: h)
    }
}

public struct HerdrPaneBox: Identifiable, Hashable, Sendable {
    public var id: String { place }
    public let place: String        // "laris-co:w22:pA" — the same key as Activity.place
    public let paneId: String
    public let rect: HerdrRect
    public let focused: Bool
    public let agent: String?       // claude · codex · nil = a plain shell
    public let name: String?        // agent name ("nexus-oracle") — tells room members apart
    public let status: String       // working · done · blocked · idle · unknown
    public let cwd: String
    public let label: String?       // herdr pane label ("serve")
}

public struct HerdrTab: Identifiable, Hashable, Sendable {
    public var id: String { place }
    public let place: String        // "laris-co:w22:t2"
    public let tabId: String
    public let label: String
    public let area: HerdrRect
    public let zoomed: Bool
    public let panes: [HerdrPaneBox]
}

public struct HerdrSpace: Identifiable, Hashable, Sendable {
    public var id: String { place }
    public let place: String        // "laris-co:w22"
    public let session: String
    public let workspaceId: String
    public let label: String
    public let number: Int
    public let status: String
    public let checkout: String?    // worktree.checkout_path, when herdr knows the repo
    public let linked: Bool         // a linked worktree — nests under its repo's space, like herdr's sidebar
    public let repoRoot: String?
    public let activeTab: String    // tab place
    public let tabs: [HerdrTab]
    public var panes: [HerdrPaneBox] { tabs.flatMap(\.panes) }
}

public enum HerdrSnapshot {
    /// One session's snapshot → its spaces (tabs in order, panes with rectangles) and its raw agent records.
    public static func parse(_ data: Data, session: String) -> (spaces: [HerdrSpace], agents: [[String: Any]]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = (root["result"] as? [String: Any])?["snapshot"] as? [String: Any] else { return ([], []) }
        let agents = s["agents"] as? [[String: Any]] ?? []
        var agentOf: [String: [String: Any]] = [:], paneOf: [String: [String: Any]] = [:], layoutOf: [String: [String: Any]] = [:]
        for a in agents { if let p = a["pane_id"] as? String { agentOf[p] = a } }
        for p in s["panes"] as? [[String: Any]] ?? [] { if let id = p["pane_id"] as? String { paneOf[id] = p } }
        for l in s["layouts"] as? [[String: Any]] ?? [] { if let t = l["tab_id"] as? String { layoutOf[t] = l } }
        let tabs = (s["tabs"] as? [[String: Any]] ?? []).sorted { ($0["number"] as? Int ?? 0) < ($1["number"] as? Int ?? 0) }

        func box(_ p: [String: Any], focusedId: String?) -> HerdrPaneBox? {
            guard let pid = p["pane_id"] as? String, let r = HerdrRect(p["rect"]) else { return nil }
            let a = agentOf[pid], info = paneOf[pid]
            return HerdrPaneBox(place: "\(session):\(pid)", paneId: pid, rect: r, focused: focusedId == pid,
                                agent: a?["agent"] as? String, name: a?["name"] as? String,
                                status: a?["agent_status"] as? String ?? info?["agent_status"] as? String ?? "unknown",
                                cwd: a?["cwd"] as? String ?? info?["cwd"] as? String ?? "",
                                label: info?["label"] as? String)
        }
        func tab(_ t: [String: Any]) -> HerdrTab? {
            guard let tid = t["tab_id"] as? String, let l = layoutOf[tid], let area = HerdrRect(l["area"]) else { return nil }
            let focusedId = l["focused_pane_id"] as? String
            return HerdrTab(place: "\(session):\(tid)", tabId: tid, label: t["label"] as? String ?? "", area: area,
                            zoomed: l["zoomed"] as? Bool ?? false,
                            panes: (l["panes"] as? [[String: Any]] ?? []).compactMap { box($0, focusedId: focusedId) })
        }
        let spaces: [HerdrSpace] = (s["workspaces"] as? [[String: Any]] ?? []).compactMap { w in
            guard let wid = w["workspace_id"] as? String else { return nil }
            let wt = w["worktree"] as? [String: Any]
            return HerdrSpace(place: "\(session):\(wid)", session: session, workspaceId: wid,
                              label: w["label"] as? String ?? wid, number: w["number"] as? Int ?? 0,
                              status: w["agent_status"] as? String ?? "unknown",
                              checkout: wt?["checkout_path"] as? String, linked: wt?["is_linked_worktree"] as? Bool ?? false,
                              repoRoot: wt?["repo_root"] as? String,
                              activeTab: "\(session):\(w["active_tab_id"] as? String ?? "")",
                              tabs: tabs.filter { ($0["workspace_id"] as? String) == wid }.compactMap(tab))
        }
        return (spaces, agents)
    }

    /// This oracle's spaces: herdr's checkout is the repo or one of its worktrees, or one of its panes works
    /// there — a room holds many oracles' panes, and every member's app shows it.
    public static func mine(_ spaces: [HerdrSpace], roots: [String]) -> [HerdrSpace] {
        func under(_ p: String) -> Bool { roots.contains { !$0.isEmpty && (p == $0 || p.hasPrefix($0 + "/")) } }
        return spaces.filter { s in s.checkout.map(under) == true || s.panes.contains { under($0.cwd) } }
    }
}
