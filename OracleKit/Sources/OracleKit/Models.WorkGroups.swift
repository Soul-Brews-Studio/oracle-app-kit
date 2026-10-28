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
    }
    public var running: [Running] = []
    public var live: [WorkItem] = []        // live, but with no pane in a known session
    public var stopped: [Stopped] = []
    public var resumable: [WorkItem] = []   // resumable, held by no stopped session
    public var cold: [WorkItem] = []

    public static func make(work: [WorkItem], places: [SessionPlace]) -> WorkGroups {
        var g = WorkGroups(), taken = Set<String>()
        let live = work.filter { $0.state <= .open }
        for p in places where p.running {
            let mine = live.filter { w in !taken.contains(w.id) && w.panes.contains { $0.place.hasPrefix(p.session + ":") } }
            taken.formUnion(mine.map(\.id))
            if !mine.isEmpty { g.running.append(Running(place: p, live: mine)) }
        }
        g.live = live.filter { !taken.contains($0.id) }
        taken.formUnion(g.live.map(\.id))
        let idle = work.filter { $0.state > .open }
        for p in places where !p.running {
            let back = HerdrPlaces.toResume(p)
            guard !back.isEmpty else { continue }
            var rows: [WorkItem] = []
            for a in back {
                guard let w = owner(of: a, in: idle), !taken.contains(w.id) else { continue }
                taken.insert(w.id); rows.append(w)
            }
            g.stopped.append(Stopped(place: p, toResume: back, rows: rows))
        }
        g.resumable = work.filter { $0.state == .resumable && !taken.contains($0.id) }
        g.cold = work.filter { $0.state == .cold && !taken.contains($0.id) }
        return g
    }

    /// The worktree a saved conversation belongs to: the one it resumes by id, else the deepest holding its folder.
    static func owner(of a: SavedAgent, in work: [WorkItem]) -> WorkItem? {
        if let w = work.first(where: { $0.resumeId == a.sessionId }) { return w }
        guard !a.cwd.isEmpty else { return nil }
        return work.filter { a.cwd == $0.path || a.cwd.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// The stopped session's buttons: where Resume lands is part of its name.
    public static func resumeLabel(_ n: Int, into target: String) -> String { "Resume \(n) in \(target)" }
    public static func startLabel(_ session: String) -> String { "Start \(session)" }
    /// COLD folded to one line.
    public static func coldLine(_ n: Int) -> String {
        "\(n) worktree\(n == 1 ? "" : "s") with no session to resume · Review cleanup"
    }
}
