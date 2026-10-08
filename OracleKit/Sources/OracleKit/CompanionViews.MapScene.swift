#if os(iOS)
import SwiftUI
import UIKit
import RealityKit
import simd

/// The flat Map: every point at its (x, y). Pinch to zoom, drag to pan, tap for the nearest point.
struct PhoneMapCanvas: View {
    let model: PhoneMapModel
    let accent: Color
    let hidden: Set<String>
    @Binding var selected: Int?
    let resetTick: Int
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinching: CGFloat = 1
    @GestureState private var dragging: CGSize = .zero

    /// map space → screen: the map's [-0.8, 0.8] fits the short side at zoom 1.
    private struct Space {
        let cx: CGFloat, cy: CGFloat, scale: CGFloat
        func point(_ p: SIMD3<Float>) -> CGPoint { CGPoint(x: cx + CGFloat(p.x) * scale, y: cy - CGFloat(p.y) * scale) }
    }
    private func space(_ size: CGSize) -> Space {
        let z = max(0.4, min(80, zoom * pinching))
        return Space(cx: size.width / 2 + pan.width + dragging.width, cy: size.height / 2 + pan.height + dragging.height,
                     scale: min(size.width, size.height) / 1.7 * z)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let sp = space(size)
                let r = max(1.2, min(3.4, 1.0 + log2(Double(max(1, zoom * pinching))) * 0.5))   // a dot grows a little as you zoom in
                for kind in PhoneStyle.kinds where !hidden.contains(kind) {
                    var path = Path()
                    for i in model.rowsOfKind[kind] ?? [] {
                        let q = sp.point(model.xyz[i])
                        if q.x < -4 || q.y < -4 || q.x > size.width + 4 || q.y > size.height + 4 { continue }
                        path.addRect(CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
                    }
                    ctx.fill(path, with: .color(Color(PhoneStyle.kindColor(kind, accent: accent)).opacity(0.85)))
                }
                if let s = selected, model.isDrawn(s) {
                    let from = sp.point(model.xyz[s])
                    let nbrs = model.neighbours(of: s)
                    var lines = Path()
                    for n in nbrs { lines.move(to: from); lines.addLine(to: sp.point(model.xyz[n])) }
                    ctx.stroke(lines, with: .color(accent.opacity(0.85)), lineWidth: 1)
                    for n in nbrs {
                        let q = sp.point(model.xyz[n])
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)), with: .color(accent))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: from.x - 5, y: from.y - 5, width: 10, height: 10)), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: CGRect(x: from.x - 9, y: from.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { selected = nearest(to: $0, size: geo.size) }
            .gesture(DragGesture(minimumDistance: 6)
                .updating($dragging) { v, state, _ in state = v.translation }
                .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height })
            .simultaneousGesture(MagnifyGesture()
                .updating($pinching) { v, state, _ in state = v.magnification }
                .onEnded { v in zoom = max(0.4, min(80, zoom * v.magnification)) })
        }
        .onChange(of: resetTick) { zoom = 1; pan = .zero }
    }

    /// The nearest visible point within a fingertip of the tap; nil on empty space (which clears the selection).
    private func nearest(to p: CGPoint, size: CGSize) -> Int? {
        let sp = space(size)
        var best = -1, bd = CGFloat.infinity
        for kind in PhoneStyle.kinds where !hidden.contains(kind) {
            for i in model.rowsOfKind[kind] ?? [] {
                let q = sp.point(model.xyz[i])
                let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                if d < bd { bd = d; best = i }
            }
        }
        return best >= 0 && bd < 26 * 26 ? best : nil
    }
}

/// The RealityKit side of the Map (iOS 26: instanced dots): one instanced mesh per kind and chunk, the selection drawn as a
/// larger point with its neighbours and lines to them, picking on the CPU by projecting every point (pixelCast never sees instances).
@available(iOS 26, *)
@MainActor
final class PhoneMapScene {
    private let root = Entity()
    private var chunks: [(kind: String, entity: ModelEntity, rows: [Int])] = []
    private var glow: [Entity] = []
    private var content: RealityViewCameraContent?
    private var model: PhoneMapModel?
    private var accent: Color = .blue
    private var selectedRow: Int?
    /// How far the camera stands from the middle of the map: at zoom 1 the body of the cloud fills a portrait iPhone's width.
    static let distance: Float = 4.6
    /// Instances per mesh. The iOS simulator drew none of an entity with 512 instances or more (32 KB of transforms) and
    /// all of one with 384, so a chunk is 256; -mapChunk <n> (tests) tries another.
    static let chunk = max(16, UserDefaults.standard.integer(forKey: "mapChunk") == 0 ? 256 : UserDefaults.standard.integer(forKey: "mapChunk"))
    static let scale: Float = 3.2

    /// The map this scene shows (nil until it is built).
    var stamp: UUID? { model?.stamp }

    /// false when RealityKit would not make the instanced dots here — the page then shows the flat map.
    func build(into content: inout RealityViewCameraContent, model: PhoneMapModel, accent: Color) -> Bool {
        root.scale = SIMD3(repeating: Self.scale)
        guard fill(model: model, accent: accent) else { return false }
        content.add(root)
        let camera = PerspectiveCamera()
        camera.position = [0, 0, Self.distance]
        content.add(camera)
        self.content = content
        return true
    }

    /// The dots of a map under `root`: one instanced mesh per kind and chunk. false when there is none.
    private func fill(model: PhoneMapModel, accent: Color) -> Bool {
        self.model = model; self.accent = accent
        let sphere = Self.dot(radius: 0.0046)
        var made = 0
        for kind in PhoneStyle.kinds {
            let mat = UnlitMaterial(color: PhoneStyle.kindColor(kind, accent: accent))   // the colour as it is, no lighting
            let rows = model.rowsOfKind[kind] ?? []
            for start in stride(from: 0, to: rows.count, by: Self.chunk) {
                let slice = Array(rows[start..<min(start + Self.chunk, rows.count)])
                if let e = Self.instanced(slice, xyz: model.xyz, mesh: sphere, material: mat) { chunks.append((kind, e, slice)); root.addChild(e); made += 1 }
            }
        }
        return made > 0
    }

    /// Another map in this same scene (the Mac laid the memory out again): the old dots and the selection go, the new dots
    /// come, the camera and the turn stay. Never a second RealityView beside this one, not even for the moment of the swap:
    /// two of them held two sets of render targets and the iPad simulator ran out of drawables ("nextDrawable returning nil
    /// because allocation failed"), after which every frame took a second and the render thread then crashed.
    /// false when RealityKit made no dots for it — the page then shows the flat map.
    func replace(model: PhoneMapModel, accent: Color) -> Bool {
        guard content != nil else { return true }   // build() has not run: it takes the model it is given
        glow.forEach { $0.removeFromParent() }; glow = []
        chunks.forEach { $0.entity.removeFromParent() }; chunks = []
        selectedRow = nil
        return fill(model: model, accent: accent)
    }

    /// The map as the fingers left it: turned, and scaled between a third and 6× (the camera never moves, so the cloud
    /// cannot be lost behind it — the orbit control's own pinch has no stop).
    func pose(turn: simd_quatf, zoom: Float) {
        root.orientation = turn
        root.scale = SIMD3(repeating: Self.scale * min(6, max(0.3, zoom)))
    }

    /// A point: a 20-triangle icosahedron. An instanced sphere costs hundreds of triangles a point and a point is a few
    /// pixels — a phone draws tens of thousands of them.
    static func dot(radius: Float) -> MeshResource {
        let t = (1 + Float(5).squareRoot()) / 2
        let corners: [SIMD3<Float>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                                       [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { simd_normalize($0) }
        let faces: [UInt32] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                               3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        var d = MeshDescriptor(name: "dot")
        d.positions = MeshBuffers.Positions(corners.map { $0 * radius })
        d.normals = MeshBuffers.Normals(corners)
        d.primitives = .triangles(faces)
        return (try? MeshResource.generate(from: [d])) ?? MeshResource.generateSphere(radius: radius)
    }

    static func instanced(_ rows: [Int], xyz: [SIMD3<Float>], mesh: MeshResource, material: RealityKit.Material) -> ModelEntity? {
        guard !rows.isEmpty, let data = try? LowLevelInstanceData(instanceCount: rows.count) else { return nil }
        data.replaceMutableTransforms { buf in for (i, r) in rows.enumerated() { buf[i] = Transform(translation: xyz[r]).matrix } }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for r in rows { lo = min(lo, xyz[r]); hi = max(hi, xyz[r]) }
        guard let inst = try? MeshInstancesComponent(mesh: mesh, instances: data, bounds: BoundingBox(min: lo - 0.01, max: hi + 0.01)) else { return nil }
        let e = ModelEntity(mesh: mesh, materials: [material])
        e.components.set(inst)
        return e
    }

    /// A kind switched off in the legend: its chunks are disabled, nothing is rebuilt.
    func show(hidden: Set<String>) { for c in chunks { c.entity.isEnabled = !hidden.contains(c.kind) } }

    func select(_ row: Int?) {
        guard row != selectedRow else { return }
        selectedRow = row
        glow.forEach { $0.removeFromParent() }; glow = []
        guard let row, let model, model.isDrawn(row) else { return }
        let nbrs = model.neighbours(of: row)
        if let e = Self.instanced([row], xyz: model.xyz, mesh: Self.dot(radius: 0.0095), material: UnlitMaterial(color: .white)) { root.addChild(e); glow.append(e) }
        if let e = Self.instanced(nbrs, xyz: model.xyz, mesh: Self.dot(radius: 0.0064), material: UnlitMaterial(color: UIColor(accent))) { root.addChild(e); glow.append(e) }
        if let l = lines(from: row, to: nbrs) { root.addChild(l); glow.append(l) }
    }

    /// One line mesh from the selected point to each neighbour.
    private func lines(from row: Int, to nbrs: [Int]) -> ModelEntity? {
        guard let model, !nbrs.isEmpty else { return nil }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = nbrs.count * 2; desc.indexCapacity = nbrs.count * 2
        desc.vertexAttributes = [.init(semantic: .position, format: .float3, offset: 0)]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return nil }
        let p0 = model.xyz[row]
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.bindMemory(to: SIMD3<Float>.self)
            for (i, n) in nbrs.enumerated() { p[2 * i] = p0; p[2 * i + 1] = model.xyz[n] }
        }
        mesh.withUnsafeMutableIndices { raw in let p = raw.bindMemory(to: UInt32.self); for i in 0..<(nbrs.count * 2) { p[i] = UInt32(i) } }
        mesh.parts.replaceAll([.init(indexCount: nbrs.count * 2, topology: .line, bounds: BoundingBox(min: p0 - 1, max: p0 + 1))])
        guard let res = try? MeshResource(from: mesh) else { return nil }
        var m = UnlitMaterial(color: UIColor(accent).withAlphaComponent(0.9)); m.blending = .transparent(opacity: 0.9)
        return ModelEntity(mesh: res, materials: [m])
    }

    /// The nearest visible point to a tap, by projecting every point onto the view; nil on empty space. Only the rows that are
    /// drawn (a legend kind that is switched on): a point that is not there on screen is not there to pick.
    func pick(at p: CGPoint, hidden: Set<String>) -> Int? {
        guard let content, let model else { return nil }
        var best = -1, bd = CGFloat.infinity
        for kind in PhoneStyle.kinds where !hidden.contains(kind) {
            for i in model.rowsOfKind[kind] ?? [] {
                guard let q = content.project(point: root.convert(position: model.xyz[i], to: nil), to: .local) else { continue }
                let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                if d < bd { bd = d; best = i }
            }
        }
        return best >= 0 && bd < 28 * 28 ? best : nil
    }
}

/// The 3-D Map: drag to turn, pinch to zoom, tap a point for its panel. The turn and the zoom are made here, not by the
/// orbit control: its pinch moves the camera without limit, and one pinch too many leaves an empty screen.
@available(iOS 26, *)
struct PhoneMapReality: View {
    let model: PhoneMapModel
    let accent: Color
    let hidden: Set<String>
    @Binding var selected: Int?
    let resetTick: Int
    let failed: () -> Void
    @State private var scene = PhoneMapScene()
    @State private var turn = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))   // the turn so far
    @State private var zoom: Float = 1                                           // the zoom so far
    @GestureState private var dragging: CGSize = .zero
    @GestureState private var pinching: CGFloat = 1

    /// A drag of a point turns the map by 0.006 rad: right is about the vertical axis, down about the horizontal one.
    private func turned(by d: CGSize, from q: simd_quatf) -> simd_quatf {
        simd_normalize(simd_quatf(angle: Float(d.width) * 0.006, axis: [0, 1, 0]) * simd_quatf(angle: Float(d.height) * 0.006, axis: [1, 0, 0]) * q)
    }
    private func apply() { scene.pose(turn: turned(by: dragging, from: turn), zoom: zoom * Float(pinching)) }

    var body: some View {
        RealityView { content in
            if scene.build(into: &content, model: model, accent: accent) { scene.show(hidden: hidden); scene.select(selected); apply() }
            else { failed() }
        } update: { _ in
            // The page holds another map than the one this scene was built from: swap the dots, in this scene (see replace).
            if scene.stamp != model.stamp, !scene.replace(model: model, accent: accent) { DispatchQueue.main.async { failed() } }
            scene.show(hidden: hidden); scene.select(selected); apply()
        }
        .gesture(SpatialTapGesture().onEnded { selected = scene.pick(at: $0.location, hidden: hidden) })
        .gesture(DragGesture(minimumDistance: 6)
            .updating($dragging) { v, state, _ in state = v.translation }
            .onEnded { v in turn = turned(by: v.translation, from: turn) })
        .simultaneousGesture(MagnifyGesture()
            .updating($pinching) { v, state, _ in state = v.magnification }
            .onEnded { v in zoom = min(6, max(0.3, zoom * Float(v.magnification))) })
        .onChange(of: resetTick) { turn = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)); zoom = 1 }
    }
}

#endif
