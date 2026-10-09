#if os(macOS)
import XCTest
@testable import OracleKit

final class SessionGroupTests: XCTestCase {
    func testCardFactsCountLiveSpaces() {
        let s = [GroupSpace(id: "a", label: "home", status: "unknown", panes: 1),                       // a shell
                 GroupSpace(id: "b", label: "dustboy-phd-oracle", status: "idle", panes: 1, agents: 1),  // an agent
                 GroupSpace(id: "c", label: "pigment", status: "done", panes: 2)]                        // remote, done
        XCTAssertEqual(GroupSpace.facts(s), "3 spaces · 2 live")
        XCTAssertEqual(GroupSpace.facts([]), "0 spaces · 0 live")
        XCTAssertEqual(GroupSpace.facts([s[0]]), "1 space · 0 live")
    }

    func testFilterMatchesNameOrBranch() {
        let s = [GroupSpace(id: "a", label: "nexus-oracle", status: "idle", panes: 1, branch: "main"),
                 GroupSpace(id: "b", label: "pulse", status: "idle", panes: 1, branch: "feat/board")]
        XCTAssertEqual(GroupSpace.matching(s, "NEX").map(\.id), ["a"])
        XCTAssertEqual(GroupSpace.matching(s, "board").map(\.id), ["b"])
        XCTAssertEqual(GroupSpace.matching(s, " ").count, 2)
    }
}
#endif
