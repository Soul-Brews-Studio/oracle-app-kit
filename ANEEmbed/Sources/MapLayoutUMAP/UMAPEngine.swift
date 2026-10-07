import Foundation
import CUmapFFI

/// UMAP over row-major Float32 data: positions in `components` dimensions plus the kNN graph it built.
public enum UMAPEngine {
    public struct Result: Sendable { public let xyz: [Float]; public let knn: [Int32]; public let dist: [Float] }
    public enum Failure: Error, CustomStringConvertible {
        case arguments, fit(Int32)
        public var description: String { switch self { case .arguments: "bad arguments to umap_fit"; case .fit(let c): "umap_fit failed (\(c))" } }
    }
    public static var version: String { String(cString: umap_ffi_version()) }

    public static func fit(data: [Float], n: Int, dim: Int, components: Int = 3, k: Int, minDist: Float, epochs: Int = 0, seed: UInt64) throws -> Result {
        guard data.count == n * dim, n > k, k >= 2 else { throw Failure.arguments }
        var xyz = [Float](repeating: 0, count: n * components)
        var knn = [Int32](repeating: -1, count: n * k)
        var dist = [Float](repeating: 0, count: n * k)
        let rc = data.withUnsafeBufferPointer { d in
            xyz.withUnsafeMutableBufferPointer { x in knn.withUnsafeMutableBufferPointer { ki in dist.withUnsafeMutableBufferPointer { kd in
                umap_fit(d.baseAddress, n, dim, components, k, minDist, epochs, seed, x.baseAddress, ki.baseAddress, kd.baseAddress)
            } } }
        }
        guard rc == 0 else { throw rc == -1 ? Failure.arguments : Failure.fit(rc) }
        return Result(xyz: xyz, knn: knn, dist: dist)
    }
}
