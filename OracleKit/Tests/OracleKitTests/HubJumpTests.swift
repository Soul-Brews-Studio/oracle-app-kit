#if os(macOS)
import XCTest
@testable import OracleKit

final class HubJumpTests: XCTestCase {
    private let sessions = [HubSession(name: "laris-co", running: true), HubSession(name: "maeon-craft", running: true),
                            HubSession(name: "maeon", running: false)]

    func testPrefixBeforeContainsAndStoppedSessionsStay() {
        let ids = HubJump.matches("maeon", sessions: sessions, oracles: []).map(\.id)
        XCTAssertEqual(Set(ids), ["s:maeon-craft", "s:maeon"])          // both start with it; laris-co does not match
        XCTAssertFalse(ids.contains("s:laris-co"))
    }

    func testContainsMatchesAndEmptyQueryListsAll() {
        XCTAssertEqual(HubJump.matches("craft", sessions: sessions, oracles: []).map(\.id), ["s:maeon-craft"])
        XCTAssertEqual(HubJump.matches("", sessions: sessions, oracles: []).count, 3)
        XCTAssertTrue(HubJump.matches("zzz", sessions: sessions, oracles: []).isEmpty)
    }
}
#endif
