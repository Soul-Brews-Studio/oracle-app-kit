import XCTest
@testable import OracleKit
import simd

/// The Map page's positions: file round-trip, placing a new doc among its neighbours, aligning a re-fit.
final class MapLayoutTests: XCTestCase {
    func testPackUnpackRoundTrip() {
        let p: [SIMD3<Float>] = [SIMD3(0.1, -0.2, 0.3), SIMD3(1, 2, 3), SIMD3(-4.5, 0, 9)]
        let raw = MapLayout.pack(p)
        XCTAssertEqual(raw.count, 36)
        XCTAssertEqual(MapLayout.unpack(raw), p)
    }

    func testPlaceAmongNeighbours() {
        // three unit vectors on axes; a new vector near e0 lands near e0's position
        let base: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        let xyz: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let v: [Float] = [0.95, 0.3, 0.1].normalised()
        let r = MapLayout.place(v, among: base, xyz: xyz, k: 2)!
        XCTAssertEqual(r.neighbours, [0, 1])
        XCTAssertEqual(r.position.x, 2.0 / 3.0, accuracy: 1e-5)   // weights 1 and 1/2 → (1·e0 + 0.5·e1) / 1.5
        XCTAssertEqual(r.position.y, 1.0 / 3.0, accuracy: 1e-5)
        XCTAssertEqual(r.position.z, 0, accuracy: 1e-6)
    }

    func testNormaliseCentresAndScales() {
        let p = (0..<200).map { SIMD3<Float>(Float($0) * 0.01, 2, 2) } + [SIMD3(100, 2, 2)]   // one far outlier
        let n = MapLayout.normalise(p)
        let r = n.map { simd_length($0) }.sorted()
        XCTAssertLessThan(r[195], 0.51)          // the 98th percentile sits at 0.5
        XCTAssertGreaterThan(r.last!, 5)         // the outlier stays outside
    }

    func testAlignUndoesARotation() {
        var g = SystemRandomNumberGenerator()
        let old: [SIMD3<Float>] = (0..<60).map { _ in SIMD3(Float.random(in: -1...1, using: &g), Float.random(in: -1...1, using: &g), Float.random(in: -1...1, using: &g)) }
        let q = simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        let new = old.map { q.act($0) * 1.7 + SIMD3(0.3, -0.2, 0.5) }   // rotated, scaled, shifted
        let aligned = MapLayout.align(new, onto: old, pairs: (0..<60).map { ($0, $0) })
        let err = zip(aligned, old).map { simd_distance($0, $1) }.max()!
        XCTAssertLessThan(err, 1e-3, "aligned layout differs from the old one by \(err)")
    }

    func testJacobiEigenOfDiagonal() {
        let (e, v) = MapLayout.jacobiEigen(simd_float3x3(diagonal: SIMD3(3, 1, 2)))
        XCTAssertEqual(e, SIMD3(3, 1, 2))
        XCTAssertEqual(v, matrix_identity_float3x3)
    }
}

private extension Array where Element == Float {
    func normalised() -> [Float] { let n = sqrt(reduce(0) { $0 + $1 * $1 }); return map { $0 / n } }
}
