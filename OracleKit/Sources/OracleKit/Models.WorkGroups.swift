import Foundation

/// The Work page, grouped by where things run: each herdr session heads the rows it holds.
/// A running session heads the live cards whose panes are in it; a stopped one heads the worktrees its saved
/// conversations belong to. What no session holds follows: loose live cards, loose resumables, then cold.
/// Every work item appears once.
public struct WorkGroups: Equatable, Sendable {
    public struct Running: Identifiable, Equatable, Sendable {
        public var id: String { place.session }
        public let place: SessionPlace
        public let live: [WorkItem]
    }
    public struct Stopped: Identifiable, Equatable, Sendable {
        public var id: String { place.session }
        public let place: SessionPlace
        public let toResume: [SavedAgent]   // its saved conversations not live anywhere: what Resume brings back
        public let rows: [WorkItem]         // the worktrees those conversations belong to
        public var extras: [Extra] = []     // the conversations no row of its own shows: rows + extras = toResume
    }
    /// A conversation a stopped session resumes that has no row under it: one quiet line, so Resume's count is seen.
    public struct Extra: Identifiable, Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case listedUnder(String)        // its worktree is a row of that group (a session, or LIVE)
            case folderGone                 // no worktree holds its folder
        }
        public var id: String { agent.sessionId }
        public let agent: SavedAgent
        public let reason: Reason
        /// its agent's name, else its folder's name, else the space it was saved in
        public var label: String {
            if !agent.name.isEmpty { return agent.name }
            let leaf = (agent.cwd as NSString).lastPathComponent
            return leaf.isEmpty ? agent.space : leaf
        }
        public var line: String {
            switch reason {
            case .listedUnder(let s): return "\(label) · listed under \(s)"
            case .folderGone: return "\(label) · folder gone"
            }
        }
    }
    public var running: [Running] = []
    public var live: [WorkItem] = []        // live, but with no pane in a known session
    public var stopped: [Stopped] = []
    public var resumable: [WorkItem] = []   // resumable, held by no stopped session
    public var cold: [WorkItem] = []

    public static func make(work: [WorkItem], places: [SessionPlace]) -> WorkGroups {
        var g = WorkGroups(), takenBy: [String: String] = [:]   // worktree → the group it is listed under
        let live = work.filter { $0.state <= .open }
        for p in places where p.running {
            let mine = live.filter { w in takenBy[w.id] == nil && w.panes.contains { $0.place.hasPrefix(p.session + ":") } }
            for w in mine { takenBy[w.id] = p.session }
            if !mine.isEmpty { g.running.append(Running(place: p, live: mine)) }
        }
        g.live = live.filter { takenBy[$0.id] == nil }
        for w in g.live { takenBy[w.id] = "LIVE" }
        for p in places where !p.running {
            let back = HerdrPlaces.toResume(p)
            guard !back.isEmpty else { continue }
            var rows: [WorkItem] = [], extras: [Extra] = []
            for a in back {
                guard let w = owner(of: a, in: work) else { extras.append(Extra(agent: a, reason: .folderGone)); continue }
                if let by = takenBy[w.id] { extras.append(Extra(agent: a, reason: .listedUnder(by))); continue }
                takenBy[w.id] = p.session; rows.append(w)
            }
            g.stopped.append(Stopped(place: p, toResume: back, rows: rows, extras: extras))
        }
        g.resumable = work.filter { $0.state == .resumable && takenBy[$0.id] == nil }
        g.cold = work.filter { $0.state == .cold && takenBy[$0.id] == nil }
        return g
    }

    /// The worktree a saved conversation belongs to: the one it resumes by id, else the deepest holding its folder.
    static func owner(of a: SavedAgent, in work: [WorkItem]) -> WorkItem? {
        if let w = work.first(where: { $0.resumeId == a.sessionId }) { return w }
        guard !a.cwd.isEmpty else { return nil }
        return work.filter { a.cwd == $0.path || a.cwd.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// The repo each saved conversation reopens under: a team body's own repo for one saved in a body, else home.
    /// Resume runs one `ticket open --repo` per group, in the order the conversations came.
    public static func resumeRepos(_ agents: [SavedAgent], work: [WorkItem], home: String) -> [(repo: String, agents: [SavedAgent])] {
        var out: [(repo: String, agents: [SavedAgent])] = []
        for a in agents {
            let w = owner(of: a, in: work)
            let repo = w?.isBody == true ? (w?.repoRoot ?? home) : home
            if let i = out.firstIndex(where: { $0.repo == repo }) { out[i].agents.append(a) } else { out.append((repo, [a])) }
        }
        return out
    }

    /// The stopped session's buttons: where Resume lands is part of its name.
    public static func resumeLabel(_ n: Int, into target: String) -> String { "Resume \(n) in \(target)" }
    public static func startLabel(_ session: String) -> String { "Start \(session)" }
    /// COLD folded to one line.
    public static func coldLine(_ n: Int) -> String {
        "\(n) worktree\(n == 1 ? "" : "s") with no session to resume · Review cleanup"
    }
}
