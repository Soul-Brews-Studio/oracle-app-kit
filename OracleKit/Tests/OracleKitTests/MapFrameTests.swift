import XCTest
@testable import OracleKit

/// The phone frames the Mac's map on the body of the cloud (#46): centred on it, 80 % of the points within 0.45.
final class MapFrameTests: XCTestCase {
    func testTheBodyFillsTheFrameWhateverTheStrays() {
        let c = SIMD3<Float>(0.3, -0.2, 0.1)
        var p: [SIMD3<Float>] = (0..<90).map { i in
            let a = Float(i) * 0.7, b = Float(i) * 1.3
            return c + 0.1 * SIMD3<Float>(cos(a) * sin(b), sin(a) * sin(b), cos(b))
        }
        p += (0..<10).map { i in SIMD3<Float>(0.9, Float(i) * 0.01, -0.9) }   // strays far out on one side
        let f = MapFrame.fit(p, drawn: Array(repeating: true, count: p.count))
        XCTAssertEqual(f.centre.x, c.x, accuracy: 0.06)
        XCTAssertEqual(f.centre.y, c.y, accuracy: 0.06)
        XCTAssertEqual(f.centre.z, c.z, accuracy: 0.06)
        XCTAssertEqual(f.scale, 0.45 / 0.1, accuracy: 1.2)   // the 80th distance is the body's radius, not the strays'
    }

    func testOnlyDrawnFinitePointsCount() {
        let p: [SIMD3<Float>] = [[0, 0, 0], [0.2, 0, 0], [-0.2, 0, 0], [50, 50, 50], [.nan, 0, 0]]
        let f = MapFrame.fit(p, drawn: [true, true, true, false, true])
        XCTAssertEqual(f.centre, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(f.scale, 0.45 / 0.2, accuracy: 0.001)
    }

    func testNothingToFrameLeavesTheMapAsItIs() {
        XCTAssertEqual(MapFrame.fit([], drawn: []).scale, 1)
        XCTAssertEqual(MapFrame.fit([[0.5, 0.5, 0.5]], drawn: [false]).scale, 1)
        let one = MapFrame.fit([[0.5, 0.5, 0.5]], drawn: [true])   // a single point: centred, not blown up
        XCTAssertEqual(one.centre, SIMD3<Float>(0.5, 0.5, 0.5))
        XCTAssertEqual(one.scale, 1)
    }
}
