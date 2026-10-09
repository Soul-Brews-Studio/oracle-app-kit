#if os(macOS)
import XCTest
@testable import OracleKit

final class NewSessionTests: XCTestCase {
    func testNewSessionNameRules() {
        let have = ["default", "laris-co", "maeon-craft"]
        XCTAssertNil(HubStore.newSessionProblem("neo-lab", existing: have))
        XCTAssertNil(HubStore.newSessionProblem(" tmp_2 ", existing: have))                  // trimmed
        XCTAssertNotNil(HubStore.newSessionProblem("", existing: have))
        XCTAssertNotNil(HubStore.newSessionProblem("laris-co", existing: have))             // exists: Start it instead
        XCTAssertNotNil(HubStore.newSessionProblem("a b", existing: have))                  // becomes a folder
        XCTAssertNotNil(HubStore.newSessionProblem("../x", existing: have))
        XCTAssertNotNil(HubStore.newSessionProblem("-x", existing: have))
    }
}
#endif
