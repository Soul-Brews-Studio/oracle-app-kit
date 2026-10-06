import XCTest
@testable import OracleKit

/// `DUMP_WORK=1 swift test --filter LiveWorkDumpTests` prints what the Work view would show for
/// Neo and Nexus, from live maw/herdr/git/gh data. Skipped otherwise (needs this Mac's fleet).
final class LiveWorkDumpTests: XCTestCase {
    @MainActor func testDumpLiveWork() async throws {
        guard ProcessInfo.processInfo.environment["DUMP_WORK"] != nil else { throw XCTSkip("set DUMP_WORK=1") }
        let configs = [
            OracleConfig(name: "Neo", tagline: "the builder", repoSlug: "laris-co/neo-oracle",
                         localPath: "/opt/Code/github.com/laris-co/neo-oracle", colorHex: "#64b5f6", symbol: "chevron.left.forwardslash.chevron.right"),
            OracleConfig(name: "Nexus", tagline: "the telescope — research", repoSlug: "laris-co/nexus-oracle",
                         localPath: "/opt/Code/github.com/laris-co/nexus-oracle", colorHex: "#ab47bc", symbol: "scope"),
        ]
        for c in configs {
            let store = OracleStore(config: c)
            await store.refresh()
            print("== \(c.name): \(store.work.count) worktrees, \(store.activity.count) panes, \(store.prs.count) PRs, \(store.issues.count) issues, inbox \(store.inbox.count) (\(store.unread.count) unread)")
            for w in store.work {
                let age = w.born.map { Int(-$0.timeIntervalSinceNow / 86400) }.map { "\($0)d" } ?? "-"
                print("  [\(w.state.label)] \(w.isMain ? "MAIN " : "")\(w.slug) | \(w.folder) | br=\(w.branch) | #\(w.issue.map(String.init) ?? "-") | pr=\(w.pr.map { "#\($0.number)" } ?? "-") | maw=\(w.mawState) | age=\(age) | resume=\(w.resumeId?.prefix(8) ?? "-")")
                for p in w.panes { print("      pane \(p.place) \(p.status): \(p.title)") }
            }
        }
    }
}
