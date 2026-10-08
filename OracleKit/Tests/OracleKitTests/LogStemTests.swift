import XCTest
@testable import OracleKit

/// #90 renamed the apps "<Name> Oracle"; their log and trace files keep the "<Name>" stem the hub map,
/// check.sh and the existing history use.
final class LogStemTests: XCTestCase {
    func testOracleSuffixIsDropped() {
        XCTAssertEqual(HubLog.logStem("Pulse Oracle"), "Pulse")
        XCTAssertEqual(HubLog.logStem("Maeon Oracle"), "Maeon")
    }
    func testOtherNamesAreKept() {
        XCTAssertEqual(HubLog.logStem("Pulse"), "Pulse")            // a build from before #90
        XCTAssertEqual(HubLog.logStem("ARRA Oracles"), "ARRA Oracles")   // the hub (embed.log)
        XCTAssertEqual(HubLog.logStem("Oracle"), "Oracle")
    }
}
