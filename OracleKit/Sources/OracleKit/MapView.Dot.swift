#if os(macOS)
import RealityKit
import simd

/// A map point: a 20-triangle icosahedron (60 indices). A RealityKit sphere is about 3,000 indices, so a chunk of 4,096
/// of them passed MeshInstancesComponent's 10,000,000-index limit and the fleet map drew nothing ("attempted to render
/// beyond the per component vertex/index limit"). Cached per radius. Mac only, inside this file's `#if os(macOS)`:
/// outside it the iOS apps had no RealityKit import and did not build.
@MainActor
enum MapDot {
    private static var made: [Float: MeshResource] = [:]
    static func mesh(radius: Float) -> MeshResource {
        if let m = made[radius] { return m }
        let t = (1 + Float(5).squareRoot()) / 2
        let corners: [SIMD3<Float>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                                       [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { simd_normalize($0) }
        let faces: [UInt32] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                               3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        var d = MeshDescriptor(name: "dot")
        d.positions = MeshBuffers.Positions(corners.map { $0 * radius })
        d.normals = MeshBuffers.Normals(corners)
        d.primitives = .triangles(faces)
        let m = (try? MeshResource.generate(from: [d])) ?? MeshResource.generateSphere(radius: radius)
        if made.count < 64 { made[radius] = m }
        return m
    }
}
#endif
