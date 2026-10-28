#if os(macOS)
import XCTest
@testable import OracleKit

/// Closing the drawer puts the window back where it was: opening it at the screen's right edge moved the window left
/// (and could clamp its width), and taking back only the width left it there.
final class DrawerFrameTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1800, height: 1100)

    func testAnUntouchedWindowGoesBackToItsFrame() {
        let before = NSRect(x: 400, y: 100, width: 1000, height: 800)          // centred
        let after = Drawer.grown(before, by: 700, screen: screen)
        XCTAssertEqual(after, NSRect(x: 100, y: 100, width: 1700, height: 800))  // shifted left to fit
        XCTAssertEqual(Drawer.closedFrame(before: before, after: after, current: after, dx: 700, screen: screen), before)
        // the old close took back only the width: the window stayed at the left
        XCTAssertEqual(Drawer.grown(after, by: -700, screen: screen).minX, 100)
    }

    func testAMovedWindowGivesBackTheWidthWhereItIs() {
        let before = NSRect(x: 400, y: 100, width: 1000, height: 800)
        let after = Drawer.grown(before, by: 700, screen: screen)
        let moved = NSRect(x: 50, y: 200, width: 1700, height: 800)
        XCTAssertEqual(Drawer.closedFrame(before: before, after: after, current: moved, dx: 700, screen: screen),
                       NSRect(x: 50, y: 200, width: 1000, height: 800))
        // no record (the app quit with the drawer open): the width alone
        XCTAssertEqual(Drawer.closedFrame(before: nil, after: nil, current: after, dx: 700, screen: screen),
                       NSRect(x: 100, y: 100, width: 1000, height: 800))
    }

    func testAClampedWidthGoesBackToItsFrame() {
        let before = NSRect(x: 200, y: 100, width: 1500, height: 800)
        let after = Drawer.grown(before, by: 700, screen: screen)
        XCTAssertEqual(after.width, 1800)                                        // clamped: it took only 300
        XCTAssertEqual(Drawer.closedFrame(before: before, after: after, current: after, dx: 700, screen: screen), before)
    }
}
#endif
