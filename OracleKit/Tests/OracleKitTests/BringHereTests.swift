import XCTest
@testable import OracleKit

#if os(macOS)
/// "bring here" moves the WezTerm window to the display the app is on, not always the main one
/// (Nat, 2026-10-09: "it should same the display of app"). Displays as m5's yabai reported them that day.
final class BringHereTests: XCTestCase {
    let displays: [[String: Any]] = [
        ["index": 1, "id": 5, "frame": ["x": 0.0, "y": 0.0, "w": 2560.0, "h": 1440.0]],
        ["index": 4, "id": 1, "frame": ["x": 2560.0, "y": 111.0, "w": 2056.0, "h": 1329.0]],
        ["index": 3, "id": 3, "frame": ["x": -2560.0, "y": 0.0, "w": 2560.0, "h": 1440.0]],
        ["index": 2, "id": 4, "frame": ["x": 4616.0, "y": -101.0, "w": 1692.0, "h": 3008.0]]]

    func testItAimsAtTheDisplayTheAppIsOn() {
        XCTAssertEqual(WezTerm.target(displays, appDisplay: 4)?["index"] as? Int, 2)   // the app on the tall screen
        XCTAssertEqual(WezTerm.target(displays, appDisplay: 1)?["index"] as? Int, 4)   // the laptop screen
    }

    func testWithNoAppWindowItFallsBackToTheMainDisplay() {
        XCTAssertEqual(WezTerm.target(displays, appDisplay: nil)?["index"] as? Int, 1)
        XCTAssertEqual(WezTerm.target(displays, appDisplay: 99)?["index"] as? Int, 1)  // a screen yabai does not list
    }
}
#endif
