#if os(macOS)
import Foundation
import OracleKit
import MapLayoutUMAP

/// Registers the in-process UMAP (Apple's Rust crate behind a C ABI) as the Map page's layout engine.
enum MapLayoutEngine {
    @MainActor static func install() {
        MapLayout.engineName = UMAPEngine.version
        MapLayout.engine = fit
    }

    /// Runs off the main actor: a 50k-doc fit takes seconds.
    @Sendable static func fit(_ data: [Float], _ n: Int, _ dim: Int, _ k: Int, _ minDist: Float, _ seed: UInt64) async throws -> (xyz: [Float], knn: [Int32], dist: [Float]) {
        let r = try await Task.detached(priority: .utility) { () throws -> UMAPEngine.Result in
            try UMAPEngine.fit(data: data, n: n, dim: dim, k: k, minDist: minDist, seed: seed)
        }.value
        return (r.xyz, r.knn, r.dist)
    }
}
#endif
