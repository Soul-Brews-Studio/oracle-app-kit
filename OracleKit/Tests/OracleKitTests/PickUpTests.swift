import XCTest
@testable import OracleKit

/// The Issues page and /herdr-ticket's one-shot mode meet in two places: the words the page puts in the message box,
/// and the worktree name and lock the skill writes, which must flip the card to "in a worktree".
final class PickUpTests: XCTestCase {
    func testCommandsFollowTheWorktree() {
        XCTAssertEqual(PickUp.commands(issue: 4, inWorktree: false).map(\.text), ["/herdr-ticket 4 --oneshot"])
        XCTAssertEqual(PickUp.commands(issue: 4, inWorktree: true).map(\.text),
                       ["/herdr-ticket --continue 4 ", "/herdr-ticket --open 4"])   // the human types the follow-up after the space
        XCTAssertEqual(PickUp.commands(issue: 4, inWorktree: false).map(\.label), ["Pick up (one-shot)"])
    }

    func testOneShotWorktreeNamesItsIssue() {
        // what `oneshot.sh pick` cuts: wt/<slug>-<owner>-issue<N>-<day>
        let f = WorkParse.parseFolder("recipes-full-editor-maeon-craft-issue4-8oct-thu2026", oracle: "maeon-craft")
        XCTAssertEqual(f.slug, "recipes-full-editor")
        XCTAssertEqual(f.issue, 4)
        XCTAssertNotNil(f.born)
        // a repo that is not an oracle keeps its whole basename as the owner
        let kit = WorkParse.parseFolder("pickup-oneshot-oracle-app-kit-issue81-8oct-thu2026", oracle: "oracle-app-kit")
        XCTAssertEqual(kit.slug, "pickup-oneshot")
        XCTAssertEqual(kit.issue, 81)
    }

    func testOneShotLockCarriesIssueAndSession() {
        // herdr|who|when|<slug>|#N|claude:<uuid> — the 6th field is extra and must not hide #N
        let l = WorkParse.parseLock("herdr|beta@m5|2026-10-08T13:30:39+07:00|docs-app-census-mac|#150|claude:4bf8b259-f7f3-4189-b45d-a922bc42eaa5")
        XCTAssertEqual(l.slug, "docs-app-census-mac")
        XCTAssertEqual(l.issue, 150)
        XCTAssertNotNil(l.born)
        // the old /herdr-ticket lock wrote issue-N there, which never named an issue
        XCTAssertNil(WorkParse.parseLock("herdr|beta@m5|2026-10-08T13:30:39+07:00|issue-150").issue)
    }

    func testPickedUpIssueLeavesNext() {
        let ls = #"{"worktrees":[{"path":"/r/maeon-craft-oracle","branch":"main","state":"running"},{"path":"/r/maeon-craft-oracle/wt/recipes-full-editor-maeon-craft-issue4-8oct-thu2026","branch":"recipes-full-editor-maeon-craft-issue4-8oct-thu2026","state":"resumable","resume":{"provider":"claude","id":"4bf8b259-f7f3-4189-b45d-a922bc42eaa5"}}]}"#
        let work = WorkParse.items(ls: Data(ls.utf8), locks: [:], activity: [], prs: [], localPath: "/r/maeon-craft-oracle")
        XCTAssertEqual(work.compactMap(\.issue), [4])
        XCTAssertEqual(work.first { $0.issue == 4 }?.resumeCommand,
                       "cd '/r/maeon-craft-oracle/wt/recipes-full-editor-maeon-craft-issue4-8oct-thu2026' && claude --resume 4bf8b259-f7f3-4189-b45d-a922bc42eaa5")
        let issues = [4, 5].map { GHItem(number: $0, title: "t\($0)", author: "nazt", updatedAt: nil, url: nil, isDraft: false, branch: nil, closes: []) }
        XCTAssertEqual(WorkParse.unstarted(issues: issues, prs: [], work: work).map(\.issue.number), [5])
    }
}
