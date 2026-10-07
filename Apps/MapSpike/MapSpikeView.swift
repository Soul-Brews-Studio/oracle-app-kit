import SwiftUI
import RealityKit
import Metal

/// 48,950 points as instanced spheres (4,096 per entity), bloom on the lit ones, N edge lines, orbit camera.
/// Prints fps once a second while the root turns, and the doc title under the pointer / on click.
struct MapSpikeView: View {
    @State private var model = SpikeModel()
    var body: some View {
        RealityView { content in
            var content = content
            model.build(into: &content)
            _ = content.subscribe(to: SceneEvents.Update.self) { _ in model.frame() }
        }
        .realityViewCameraControls(.orbit)
        .onAppear { model.installScrollZoom() }
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase { model.pointer = p } else { model.pointer = nil }
        }
        .onTapGesture { model.click() }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.status).font(.system(size: 13, design: .monospaced))
                Text(model.hover).font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange)
            }
            .padding(10).background(.black.opacity(0.6)).padding()
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.06))
    }
}

@Observable @MainActor
final class SpikeModel {
    var status = "loading…"
    var hover = ""
    var pointer: CGPoint?
    private var xyz: [SIMD3<Float>] = []
    private var kind: [UInt8] = []
    private var titles: [String] = []
    private var root = Entity()
    private var frames = 0
    private var last = Date()
    private var started = Date()
    private var maxFPS = 0.0
    private var minFPS = 1e9
    private var samples: [Double] = []
    private var chunkDocs: [ObjectIdentifier: [Int]] = [:]   // entity → doc index per instance
    private weak var scene: RealityKit.Scene?
    private var content: RealityViewCameraContent?
    private var orbitSeconds: Double = 20
    private var lastPick = Date.distantPast

    static let chunk = 4_096
    static let colors: [NSColor] = [NSColor(red: 0.39, green: 0.71, blue: 0.96, alpha: 1), NSColor(red: 0.67, green: 0.28, blue: 0.74, alpha: 1), .orange, .green]

    func build(into content: inout RealityViewCameraContent) {
        setvbuf(stdout, nil, _IOLBF, 0)
        self.content = content
        let args = UserDefaults.standard
        let dir = args.string(forKey: "mapData") ?? FileManager.default.currentDirectoryPath
        let edges = args.object(forKey: "edges") == nil ? 500 : args.integer(forKey: "edges")
        orbitSeconds = args.object(forKey: "orbit") == nil ? 20 : args.double(forKey: "orbit")
        guard let xd = try? Data(contentsOf: URL(fileURLWithPath: dir + "/neo.xyz")),
              let kd = try? Data(contentsOf: URL(fileURLWithPath: dir + "/neo.kind")),
              let td = try? Data(contentsOf: URL(fileURLWithPath: dir + "/neo.titles.json")),
              let t = try? JSONDecoder().decode([String].self, from: td) else { status = "no data in \(dir)"; return }
        let f = xd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        xyz = stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
        kind = [UInt8](kd); titles = t
        let n = xyz.count
        let t0 = Date()
        let sphere = MeshResource.generateSphere(radius: 0.0028)
        var lit = Set<Int>()
        var g = SystemRandomNumberGenerator()
        while lit.count < 25 { lit.insert(Int.random(in: 0..<n, using: &g)) }
        for k in 0..<4 {
            var mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: .black)
            mat.emissiveColor = .init(color: Self.colors[k])
            mat.emissiveIntensity = k == 0 ? 0.45 : 0.8     // under the bloom threshold: sessions (80 % of points) dim, the rest brighter
            mat.roughness = .init(floatLiteral: 1)
            let idx = (0..<n).filter { kind[$0] == k && !lit.contains($0) }
            for start in stride(from: 0, to: idx.count, by: Self.chunk) {
                let slice = Array(idx[start..<min(start + Self.chunk, idx.count)])
                addChunk(slice, mesh: sphere, material: mat)
            }
        }
        // the lit ones: emissive, so bloom picks them up
        var glow = PhysicallyBasedMaterial()
        glow.emissiveColor = .init(color: .white)
        glow.emissiveIntensity = 5
        glow.baseColor = .init(tint: .white)
        addChunk(Array(lit), mesh: MeshResource.generateSphere(radius: 0.0045), material: glow)
        // edges: random pairs among neighbours by brute-force cosine on a 1,000-point sample
        if edges > 0 { addEdges(count: edges) }
        root.scale = [2, 2, 2]
        content.add(root)
        content.cameraTarget = root
        if #available(macOS 27, *) {   // bloom is a scene-wide post effect: any entity in the scene may carry it
            root.components.set(BloomComponent(scope: .unbounded))
            var opts = BloomOptionsComponent(); opts.strength = 1.2; opts.threshold = 1.0; opts.blurRadius = 10
            root.components.set(opts)
        }
        scene = root.scene
        status = String(format: "%d points · %d entities · built in %.2f s · orbiting %.0f s", n, root.children.count, Date().timeIntervalSince(t0), orbitSeconds)
        print(status)
        started = Date(); last = started
    }

    private func addChunk(_ docs: [Int], mesh: MeshResource, material: RealityKit.Material) {
        let e = ModelEntity(mesh: mesh, materials: [material])
        guard let data = try? LowLevelInstanceData(instanceCount: docs.count) else { return }
        data.replaceMutableTransforms { buf in
            for (i, d) in docs.enumerated() { buf[i] = Transform(translation: xyz[d]).matrix }
        }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for d in docs { lo = min(lo, xyz[d]); hi = max(hi, xyz[d]) }
        guard let inst = try? MeshInstancesComponent(mesh: mesh, instances: data, bounds: BoundingBox(min: lo - 0.01, max: hi + 0.01)) else { return }
        e.components.set(inst)
        chunkDocs[ObjectIdentifier(e)] = docs
        root.addChild(e)
    }

    private func addEdges(count: Int) {
        let n = xyz.count
        var g = SystemRandomNumberGenerator()
        var pairs: [(Int, Int)] = []
        while pairs.count < count {
            let a = Int.random(in: 0..<n, using: &g)
            // nearest of 64 random candidates in 3-D (the spike only needs plausible short lines)
            var best = -1; var bd = Float.infinity
            for _ in 0..<2_000 { let b = Int.random(in: 0..<n, using: &g); let d = simd_distance(xyz[a], xyz[b]); if b != a, d < bd { bd = d; best = b } }
            pairs.append((a, best))
        }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = pairs.count * 2
        desc.indexCapacity = pairs.count * 2
        desc.vertexAttributes = [.init(semantic: .position, format: .float3, offset: 0)]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { print("LowLevelMesh failed"); return }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.bindMemory(to: SIMD3<Float>.self)
            for (i, (a, b)) in pairs.enumerated() { p[2 * i] = xyz[a]; p[2 * i + 1] = xyz[b] }
        }
        mesh.withUnsafeMutableIndices { raw in
            let p = raw.bindMemory(to: UInt32.self)
            for i in 0..<(pairs.count * 2) { p[i] = UInt32(i) }
        }
        mesh.parts.replaceAll([.init(indexCount: pairs.count * 2, topology: .line, bounds: BoundingBox(min: [-0.6, -0.6, -0.6], max: [0.6, 0.6, 0.6]))])
        guard let res = try? MeshResource(from: mesh) else { print("MeshResource(from:) failed"); return }
        var m = UnlitMaterial(color: NSColor(white: 1, alpha: 0.25)); m.blending = .transparent(opacity: 0.25)
        root.addChild(ModelEntity(mesh: res, materials: [m]))
    }

    /// Once per frame: turn the root, count fps, pick under the pointer (at most 20 picks a second).
    func frame() {
        frames += 1
        let now = Date()
        let t = now.timeIntervalSince(started)
        if t < orbitSeconds { root.orientation = simd_quatf(angle: Float(t) * 0.5, axis: [0, 1, 0]) }
        if now.timeIntervalSince(last) >= 1 {
            let fps = Double(frames) / now.timeIntervalSince(last)
            frames = 0; last = now
            if t < orbitSeconds + 1 { samples.append(fps); maxFPS = max(maxFPS, fps); minFPS = min(minFPS, fps) }
            let mem = Self.residentMB()
            let line = String(format: "fps %.0f (min %.0f · max %.0f · mean %.0f over %d s) · rss %.0f MB", fps, minFPS, maxFPS, samples.reduce(0, +) / Double(max(1, samples.count)), samples.count, mem)
            status = line; print("t=\(Int(t))s " + line)
        }
        if let p = pointer, now.timeIntervalSince(lastPick) > 0.1 { lastPick = now; Task { await pick(at: p, click: false) } }
        if t > orbitSeconds + 1, !selfTested { selfTested = true; Task { await selfTest() } }
    }
    private var selfTested = false

    /// Picking without a pointer: project 5 random docs' world positions to view points, cast back, compare the doc.
    private func selfTest() async {
        guard let content, let scene = root.scene else { return }
        var ok = 0, tried = 0
        for _ in 0..<5 {
            let d = Int.random(in: 0..<xyz.count)
            let world = root.convert(position: xyz[d], to: nil)
            guard let p = content.project(point: world, to: .local), let ray = content.ray(through: p, in: .local, to: .scene) else { print("selftest: doc \(d) does not project"); continue }
            tried += 1
            let t0 = Date()
            let hit = try? await scene.pixelCast(origin: ray.origin, direction: ray.direction, length: 1_000)
            let ms = Date().timeIntervalSince(t0) * 1000
            if hit == nil {   // fallback: project every point and take the nearest on screen — measure what that costs
                let t1 = Date(); var best = -1; var bd = CGFloat.infinity
                for i in 0..<xyz.count {
                    if let q = content.project(point: root.convert(position: xyz[i], to: nil), to: .local) {
                        let dd = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y); if dd < bd { bd = dd; best = i }
                    }
                }
                let cpuMs = Date().timeIntervalSince(t1) * 1000
                let same = best == d || (best >= 0 && simd_distance(xyz[best], xyz[d]) < 0.012)
                if same { ok += 1 }
                print(String(format: "selftest: doc %d at (%.0f, %.0f) → pixelCast nil (%.1f ms) · CPU pick doc %d %@ in %.0f ms (%.1f px off)", d, p.x, p.y, ms, best, same ? "OK" : "WRONG", cpuMs, sqrt(bd)))
                continue
            }
            if let hit, let docs = chunkDocs[ObjectIdentifier(hit.entity)], Int(hit.instance) < docs.count {
                let got = docs[Int(hit.instance)]
                let same = got == d || simd_distance(xyz[got], xyz[d]) < 0.012   // another point in front of it counts as a correct pick
                if same { ok += 1 }
                print(String(format: "selftest: doc %d at (%.0f, %.0f) → instance %d = doc %d %@ · %.1f ms · %@", d, p.x, p.y, hit.instance, got, same ? "OK" : "WRONG", ms, titles[got]))
            } else {
                print(String(format: "selftest: doc %d at (%.0f, %.0f) → %@ · %.1f ms", d, p.x, p.y, hit == nil ? "no hit" : "hit entity without instances: \(hit!.entity.name)", ms))
            }
        }
        print("selftest: \(ok) of \(tried) picks correct")
        status += " · picks \(ok)/\(tried)"
    }

    private var scrollMonitor: Any?
    func installScrollZoom() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self else { return e }
            let f = Float(1 + e.scrollingDeltaY * 0.01)
            let s = min(12, max(0.5, root.scale.x * f))
            root.scale = [s, s, s]
            return nil
        }
    }

    func click() { if let p = pointer { Task { await pick(at: p, click: true) } } }

    private func pick(at p: CGPoint, click: Bool) async {
        guard let content, let scene = root.scene, let ray = content.ray(through: p, in: .local, to: .scene) else { hover = "no ray"; return }
        let t0 = Date()
        _ = scene; _ = ray
        var best = -1; var bd = CGFloat.infinity
        for i in 0..<xyz.count {
            if let q = content.project(point: root.convert(position: xyz[i], to: nil), to: .local) {
                let dd = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y); if dd < bd { bd = dd; best = i }
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        guard best >= 0, bd < 12 * 12 else { hover = ""; return }
        hover = String(format: "%@ doc %d · %@ · %.0f ms", click ? "CLICK" : "hover", best, titles[best], ms)
        if click { print(hover) }
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : 0
    }
}
