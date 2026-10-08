import XCTest
@testable import OracleKit

/// Nat's four displays as yabai measured them on 2026-10-08 (top-left global points).
final class ScreenMapTests: XCTestCase {
    let displays = [
        ScreenMap.Display(id: 3, name: "DELL U2719DC", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), main: false),
        ScreenMap.Display(id: 1, name: "DELL S2725QS", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), main: true),
        ScreenMap.Display(id: 4, name: "Built-in Retina Display", frame: CGRect(x: 2560, y: 111, width: 2056, height: 1329), main: false),
        ScreenMap.Display(id: 2, name: "DELL U2723QE", frame: CGRect(x: 4616, y: -101, width: 1692, height: 3008), main: false),
    ]

    func testAWindowBelongsToTheDisplayHoldingItsCentre() {
        XCTAssertEqual(ScreenMap.display(of: CGRect(x: -2400, y: 50, width: 1900, height: 1300), in: displays)?.name, "DELL U2719DC")   // the hub
        XCTAssertEqual(ScreenMap.display(of: CGRect(x: 0, y: 25, width: 2560, height: 1415), in: displays)?.name, "DELL S2725QS")     // laris-co's WezTerm
        XCTAssertEqual(ScreenMap.display(of: CGRect(x: 2000, y: 200, width: 1000, height: 500), in: displays)?.name, "DELL S2725QS",
                       "centre x 2500 < 2560: the 5K, though half of it is on the MacBook")
    }

    func testAWindowStraddlingTwoDisplaysGoesByItsCentre() {
        // centre x = 2600: on the MacBook, though most of its left part sits on the 5K
        XCTAssertEqual(ScreenMap.display(of: CGRect(x: 2200, y: 300, width: 800, height: 400), in: displays)?.name, "Built-in Retina Display")
        XCTAssertNil(ScreenMap.display(of: CGRect(x: 9000, y: 9000, width: 10, height: 10), in: displays), "off every display: none")
    }

    func testFitKeepsShapesAndOffsets() {
        let f = ScreenMap.fit(displays, into: CGSize(width: 886.8 + 24, height: 400), pad: 12)
        XCTAssertEqual(f.origin, CGPoint(x: -2560, y: -101))
        XCTAssertEqual(f.scale, 0.1, accuracy: 0.0001)   // 8868 pt wide → 888 pt, the binding side
        let main = ScreenMap.place(displays[1].frame, scale: f.scale, origin: f.origin, pad: 12)
        XCTAssertEqual(main.minX, 12 + 256, accuracy: 0.01); XCTAssertEqual(main.minY, 12 + 10.1, accuracy: 0.01)
        XCTAssertEqual(main.width / main.height, 2560.0 / 1440.0, accuracy: 0.0001)
    }

    func testAppKitFramesFlipToTopLeft() {
        // the portrait DELL in AppKit: y up from the main's bottom, so its top is 101 pt above the main's top
        let appKit = CGRect(x: 4616, y: 1440 - 2907, width: 1692, height: 3008)
        XCTAssertEqual(ScreenMap.topLeft(appKit, mainHeight: 1440), CGRect(x: 4616, y: -101, width: 1692, height: 3008))
    }
}
