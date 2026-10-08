#if os(macOS)
import XCTest
@testable import OracleKit

/// The Network page's machine cards (#93): columns as the adaptive grid made them, and every card in a row as tall as
/// the row's tallest, so a row ends level.
final class MachineGridTests: XCTestCase {
    func testColumnsMatchTheAdaptiveGrid() {
        XCTAssertEqual(MachineGrid.columns(1044, minWidth: 330, spacing: 14), 3)   // the page at its 1100 cap, less padding
        XCTAssertEqual(MachineGrid.columns(1000, minWidth: 330, spacing: 14), 2)
        XCTAssertEqual(MachineGrid.columns(200, minWidth: 330, spacing: 14), 1)    // narrower than one card: still one column
    }

    func testEveryRowIsAsTallAsItsTallestCard() {
        // Nat's screenshot: m5 (4 sessions and "5 stopped") over black and white (3 each); a fourth machine wraps
        XCTAssertEqual(MachineGrid.rows([254, 194, 194], columns: 3), [254])
        XCTAssertEqual(MachineGrid.rows([254, 194, 194, 120], columns: 3), [254, 120])
        XCTAssertEqual(MachineGrid.rows([], columns: 3), [])
    }
}
#endif
