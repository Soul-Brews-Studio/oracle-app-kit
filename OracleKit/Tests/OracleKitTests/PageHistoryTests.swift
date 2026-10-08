import XCTest
@testable import OracleKit

/// Back / forward between an oracle app's pages (#86): Open session jumps Issues → Work; mouse 4 must land on Issues.
final class PageHistoryTests: XCTestCase {
    func testBackFromOpenSessionLandsOnIssues() {
        var h = PageHistory<Section>()
        h.visit(from: .status, to: .issues)          // the human opens Issues
        h.visit(from: .issues, to: .status)          // Open session jumps to Work for the agent's pane
        XCTAssertEqual(h.goBack(from: .status), .issues)
        XCTAssertEqual(h.goBack(from: .issues), .status)
        XCTAssertNil(h.goBack(from: .status))        // nothing further back: the button is disabled, the click a no-op
        XCTAssertEqual(h.goForward(from: .status), .issues)
        XCTAssertEqual(h.goForward(from: .issues), .status)
        XCTAssertNil(h.goForward(from: .status))
    }

    func testAVisitAfterGoingBackDropsForward() {
        var h = PageHistory<Section>()
        h.visit(from: .status, to: .issues)
        h.visit(from: .issues, to: .prs)
        XCTAssertEqual(h.goBack(from: .prs), .issues)
        h.visit(from: .issues, to: .memory)          // a new page, like a browser link: forward is gone
        XCTAssertTrue(h.forward.isEmpty)
        XCTAssertEqual(h.back, [.status, .issues])
    }

    func testSamePageIsNotAVisitAndTheStackIsCapped() {
        var h = PageHistory<Int>(limit: 3)
        h.visit(from: 1, to: 1)
        XCTAssertTrue(h.back.isEmpty)
        for i in 1...5 { h.visit(from: i, to: i + 1) }
        XCTAssertEqual(h.back, [3, 4, 5])
    }
}
