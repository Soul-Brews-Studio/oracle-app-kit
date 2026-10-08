#if os(macOS)
import SwiftUI
import RealityKit
import simd

/// The RealityKit side of the Map page: chunks of instanced spheres per kind, a lit set drawn emissive under bloom,
/// hover lines to the kNN neighbours, CPU picking, zoom by scaling the root, fps for the status line.
@available(macOS 26, *)
@MainActor
final class MapScene: ObservableObject {
    @Published var hoverDoc: Int?          // the doc under the pointer (index into docs)
    @Published var hoverAt: CGPoint?       // the pointer, where the card is drawn
    @Published var selectedRow: Int?       // the clicked point (layout row): the panel shows it, its relatives, its group
    /// Where each region's name sits on screen (projected from the region's centre every few frames); empty when
    /// zoomed in, where the leaves are named instead.
    @Published var labelAt: [Int: CGPoint] = [:]
    /// Zoomed in: where each leaf on screen has its name.
    @Published var leafAt: [Int: CGPoint] = [:]
    /// The map's size on screen: leaf names outside it are not placed.
    var viewSize: CGSize = .zero
    private var hoverRow: Int?
    var hovered: Int? { hoverRow }
    private var leafCentre: [Int: SIMD3<Float>] = [:]
    private var leafOf: [Int] = []
    private(set) var docs: [IndexDoc] = []
    private var groupCentre: [Int: SIMD3<Float>] = [:]
    private var groupOf: [Int] = []
    private var hand = false
    /// The pointing hand while the pointer is on a point (clickable), the arrow elsewhere.
    func setHand(_ on: Bool) {
        guard on != hand else { return }
        hand = on
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
    @Published var fps = 0.0
    @Published var lit: [Int] = []
    @Published var shown = 0
    var pointer: CGPoint?
    var needsRebuild = false
    @Published private(set) var built = 0
    private let accent: Color
    private var root = Entity()
    private var chunks: [(kind: String, entity: ModelEntity, rows: [Int])] = []
    private var litEntity: ModelEntity?
    private var lines: ModelEntity?
    private var xyz: [SIMD3<Float>] = []
    private var rowKind: [String] = []
    private var rowToDoc: [Int] = []
    private var layout: MapLayout?
    private var content: RealityViewCameraContent?
    private var frames = 0
    private var builtIds: [String] = []
    private var pendingZoom: Float?
    private var builtAt = Date()
    private var fpsSeconds = 0
    private var last = Date()
    private var lastPick = Date.distantPast
    private var scroll: Any?
    private var flat = false
    private var target: SIMD3<Float>?
    static let chunk = 4_096
    static let scale: Float = 3.2

    private let fleet: FleetMap?
    private var byKind = false
    init(accent: Color, fleet: FleetMap? = nil) { self.accent = accent; self.fleet = fleet }

    static func color(_ kind: String, accent: Color) -> NSColor {
        switch kind {
        case "note": NSColor(red: 0.67, green: 0.28, blue: 0.74, alpha: 1)
        case "issue": .orange
        case "pr": NSColor(red: 0.4, green: 0.78, blue: 0.4, alpha: 1)
        default: NSColor(accent)
        }
    }

    func build(into content: inout RealityViewCameraContent, layout: MapLayout, docs: [IndexDoc]) {
        self.content = content; self.layout = layout; builtIds = layout.ids
        // a rebuild (new layout): what pointed at rows of the old one goes
        selectedRow = nil; hoverRow = nil; hoverDoc = nil; lit = []; firings = []; fireEntities = []; target = nil
        litEntity = nil; lines = nil; hoverGlow = nil; selGlow = nil; selLines = nil; pulseEntity = nil; webEntity = nil
        groupOf = []; leafOf = []; groupCentre = [:]; leafCentre = [:]; labelAt = [:]; leafAt = [:]
        root = Entity()
        root.scale = SIMD3(repeating: Self.scale)
        let zoom = UserDefaults.standard.double(forKey: "mapZoom")   // -mapZoom 2.4 (tests: the leaves' names), once the camera has framed
        pendingZoom = zoom > 0 ? Float(zoom) : nil
        // outliers pulled onto a shell at 0.8 so the camera frames the cloud, not three strays (picking uses the same)
        xyz = layout.xyz.map { p in let r = simd_length(p); return r > 0.8 ? p * (0.8 / r) : p }
        let byId = Dictionary(docs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        rowToDoc = layout.ids.map { byId[$0] ?? -1 }
        rowKind = rowToDoc.map { $0 >= 0 ? docs[$0].kind : "" }
        self.docs = docs
        buildChunks()
        web()
        content.add(root)
        // the camera frames its target's bounds as a sphere around their box, so the whole root (the web's box, a few
        // outliers at the 0.8 shell) left half the points in a dot in the middle. A sphere at the 80th-percentile radius
        // frames out to ~1.7× that: about 98 % of the points, filling the view
        let r80 = xyz.map { simd_length($0) }.sorted().dropFirst(xyz.count * 8 / 10).first ?? 0.4
        var clear = UnlitMaterial(color: .clear); clear.blending = .transparent(opacity: .init(floatLiteral: 0))
        let frameEntity = ModelEntity(mesh: .generateSphere(radius: max(0.05, r80)), materials: [clear])
        root.addChild(frameEntity)
        content.cameraTarget = frameEntity
        if #available(macOS 27, *), UserDefaults.standard.object(forKey: "mapBloom") as? Bool ?? true {   // -mapBloom NO (tests: its memory)
            root.components.set(BloomComponent(scope: .unbounded))
            var o = BloomOptionsComponent(); o.strength = 1.2; o.threshold = 1.0; o.blurRadius = 10
            root.components.set(o)
        }
        show(kinds: shownKinds)          // a rebuild keeps the kind filter and 2D the page has
        if flat { flatten(true) }
        built += 1; needsRebuild = false; builtAt = Date()
        HubLog.shared.add(.info, "map: \(xyz.count) points in \(chunks.count) chunks")
    }

    /// The points, in chunks of one kind and one colour: by kind on an oracle's map; by oracle on the fleet's (#37),
    /// or by kind there too when asked.
    private func buildChunks() {
        chunks.forEach { $0.entity.removeFromParent() }; chunks = []
        let sphere = MapDot.mesh(radius: 0.0032)
        let oracle: [String] = fleet != nil && !byKind ? rowToDoc.map { $0 >= 0 ? fleet?.oracleOf[docs[$0].id] ?? "Fleet" : "" } : []
        for kind in ["history", "note", "issue", "pr"] {
            var byColor: [String: [Int]] = [:]
            for r in xyz.indices where rowKind[r] == kind { byColor[oracle.isEmpty ? kind : oracle[r], default: []].append(r) }
            for (key, rows) in byColor.sorted(by: { $0.key < $1.key }) {
                // unlit: the colour as it is, no lighting falloff; below the bloom threshold, so only lit hits glow
                let mat = UnlitMaterial(color: oracle.isEmpty ? Self.color(kind, accent: accent) : FleetMap.color(key))
                for start in stride(from: 0, to: rows.count, by: Self.chunk) {
                    let slice = Array(rows[start..<min(start + Self.chunk, rows.count)])
                    if let e = Self.instanced(slice, xyz: xyz, mesh: sphere, material: mat) { chunks.append((kind, e, slice)); root.addChild(e) }
                }
            }
        }
    }

    /// The fleet map's colour switch: the same points, chunked again by kind or by oracle.
    func recolor(byKind on: Bool) {
        guard on != byKind else { return }
        byKind = on                      // kept even with no points yet: build() chunks by it
        guard !xyz.isEmpty else { return }
        buildChunks()
        show(kinds: shownKinds)
        if flat { flatten(true) }
        HubLog.shared.add(.info, "map: coloured by \(on ? "kind" : "oracle")")
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

    /// The neuron web: every point to its 3 nearest neighbours (the layout's kNN graph), one faint line mesh.
    /// Short links only: a long one is a scratch across the map, not a synapse.
    private func web() {
        guard let layout else { return }
        var segs: [(Int, Int)] = []
        segs.reserveCapacity(xyz.count * 2)
        for i in 0..<xyz.count { for n in layout.neighbours(of: i).prefix(3) where n > i && n < xyz.count && simd_distance(xyz[i], xyz[n]) < 0.05 { segs.append((i, n)) } }
        guard !segs.isEmpty else { return }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = segs.count * 2; desc.indexCapacity = segs.count * 2
        desc.vertexAttributes = [.init(semantic: .position, format: .float3, offset: 0)]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.bindMemory(to: SIMD3<Float>.self)
            for (k, (a, b)) in segs.enumerated() { p[2 * k] = xyz[a]; p[2 * k + 1] = xyz[b] }
        }
        mesh.withUnsafeMutableIndices { raw in let p = raw.bindMemory(to: UInt32.self); for i in 0..<(segs.count * 2) { p[i] = UInt32(i) } }
        mesh.parts.replaceAll([.init(indexCount: segs.count * 2, topology: .line, bounds: BoundingBox(min: [-0.85, -0.85, -0.85], max: [0.85, 0.85, 0.85]))])
        guard let res = try? MeshResource(from: mesh) else { return }
        // the fleet map's web is neutral and fainter, so the oracles' colours read through it
        let a: Float = fleet == nil ? 0.22 : 0.12
        var m = UnlitMaterial(color: (fleet == nil ? NSColor(accent) : .white).withAlphaComponent(CGFloat(a))); m.blending = .transparent(opacity: .init(floatLiteral: a))
        webEntity = ModelEntity(mesh: res, materials: [m])
        root.addChild(webEntity!)
        HubLog.shared.add(.info, "map: neuron web of \(segs.count) links")
    }
    private var webEntity: ModelEntity?
    private var shownKinds = "all"
    private func shown(_ kind: String) -> Bool {
        shownKinds == "all" || kind == shownKinds || (shownKinds == "gh" && (kind == "issue" || kind == "pr"))
    }

    /// The kind filter: a hidden kind's chunks shrink to nothing — no rebuild.
    func show(kinds: String) {
        shownKinds = kinds
        var n = 0
        for c in chunks {
            let on = kinds == "all" || c.kind == kinds || (kinds == "gh" && (c.kind == "issue" || c.kind == "pr"))
            c.entity.isEnabled = on; if on { n += c.rows.count }
        }
        shown = n
    }

    /// 2D: every z to 0 (the same positions, so the clusters match the 3-D view) and the camera above.
    func flatten(_ on: Bool) {
        flat = on
        for c in chunks {
            guard var inst = c.entity.components[MeshInstancesComponent.self], let part = inst[partIndex: 0] else { continue }
            part.data.replaceMutableTransforms { buf in
                for (i, r) in c.rows.enumerated() { var p = xyz[r]; if on { p.z = 0 }; buf[i] = Transform(translation: p).matrix }
            }
            inst[partIndex: 0] = part
            c.entity.components.set(inst)
        }
        webEntity?.isEnabled = !on   // the web is 3-D; in 2D it would only scribble
        root.orientation = on ? simd_quatf(angle: 0, axis: [0, 1, 0]) : root.orientation
        relight()
        if let r = selectedRow { select(r) }
    }

    /// Search hits: a separate emissive entity above the bloom threshold, plus lines from the top hit to its neighbours.
    func light(_ rows: [Int]) {
        lit = rows.filter { $0 < xyz.count }
        relight()
        if let first = lit.first { target = xyz[first] }
    }
    private func relight() {
        litEntity?.removeFromParent(); litEntity = nil
        guard !lit.isEmpty else { return }
        var glow = PhysicallyBasedMaterial()
        glow.emissiveColor = .init(color: .white); glow.emissiveIntensity = 6; glow.baseColor = .init(tint: .white)
        let pts = flat ? xyz.map { SIMD3($0.x, $0.y, 0) } : xyz
        if let e = Self.instanced(lit, xyz: pts, mesh: MapDot.mesh(radius: 0.006), material: glow) { litEntity = e; root.addChild(e) }
    }

    /// The pointer lights what it touches (the point + its nearest neighbours, with lines to them), like a small
    /// firing that follows the mouse. A click keeps that firing, brighter, until another click or esc.
    private var hoverGlow: ModelEntity?
    private var selGlow: ModelEntity?
    private var selLines: ModelEntity?
    private func drawLines(from row: Int?) {
        lines?.removeFromParent(); lines = nil
        hoverGlow?.removeFromParent(); hoverGlow = nil
        guard let row else { return }
        (hoverGlow, lines) = firing(at: row, glow: 4, lineAlpha: 0.6, radius: 0.0048)
    }
    func select(_ row: Int?) {
        if row != nil, row == selectedRow, selGlow != nil { target = row.map { xyz[$0] }; return }   // a second click on the same point
        selGlow?.removeFromParent(); selGlow = nil; selLines?.removeFromParent(); selLines = nil
        selectedRow = row
        guard let row, row < xyz.count else { return }
        (selGlow, selLines) = firing(at: row, glow: 8, lineAlpha: 0.9, radius: 0.0062)
        target = xyz[row]
        HubLog.shared.add(.info, "map: selected \(rowKind[row]) \(rowToDoc[row] >= 0 ? docs[rowToDoc[row]].title.prefix(60) : "")")
    }
    /// The doc of a layout row (nil when the doc left the index since the layout).
    func doc(row: Int) -> IndexDoc? { row < rowToDoc.count && rowToDoc[row] >= 0 ? docs[rowToDoc[row]] : nil }
    func row(ofDoc id: String) -> Int? { layout?.row(of: id) }

    func neighbours(of row: Int) -> [Int] { layout?.neighbours(of: row).filter { $0 < xyz.count } ?? [] }
    func group(of row: Int) -> Int? { row < groupOf.count ? groupOf[row] : nil }
    func leaf(of row: Int) -> Int? { row < leafOf.count ? leafOf[row] : nil }
    func members(of g: Int) -> [Int] { groupOf.indices.filter { groupOf[$0] == g } }

    /// A group from its name or the list: its members light up and the map turns to its centre.
    func focus(group g: Int, leaf: Bool) {
        let rows = (leaf ? leafOf : groupOf).indices.filter { (leaf ? leafOf : groupOf)[$0] == g }
        light(Array(rows.prefix(600)))
        if let c = (leaf ? leafCentre : groupCentre)[g] { target = c }
    }

    // MARK: firing (#36)

    struct Firing: Identifiable { let id = UUID(); let rows: [Int]; let color: NSColor; let start: Date; let label: String }
    @Published var recentFirings: [Firing] = []
    private var firings: [Firing] = []
    private var fireEntities: [ModelEntity] = []
    private var pulseEntity: ModelEntity?
    static let fireSeconds = 2.4, pulseSeconds = 0.9

    /// The caller's colour: an oracle's own accent when another oracle asked over MCP, the app's accent for "you".
    static func callerColor(_ caller: String?, source: String, accent: Color) -> NSColor {
        guard source == "mcp" else { return NSColor(accent) }
        let name = caller?.components(separatedBy: " · ").first ?? ""
        return ["neo", "pulse", "nexus", "athena"].contains(name.lowercased()) ? FleetMap.color(name) : .white   // one colour table
    }

    /// A query's hits flash, and pulses run from the best hit to its neighbours (1 hop), then everything decays.
    /// Many queries at once (an agent in a loop) are kept to the last 6 firings, so the map never stalls.
    func fire(rows: [Int], color: NSColor, label: String) {
        let r = rows.filter { $0 < xyz.count }
        guard !r.isEmpty else { return }
        let f = Firing(rows: r, color: color, start: Date(), label: label)
        firings.append(f); if firings.count > 6 { firings.removeFirst(firings.count - 6) }
        recentFirings.insert(f, at: 0); if recentFirings.count > 5 { recentFirings.removeLast() }
        HubLog.shared.add(.info, "map: fire \(r.count) hits — \(label)")
    }

    /// Per frame: the firings' glow (rebuilt only when the set changes or every 4th frame as it decays) and the
    /// pulses' positions along their edges.
    private func animateFirings(_ now: Date) {
        firings.removeAll { now.timeIntervalSince($0.start) > Self.fireSeconds }
        if frames % 4 == 0 || fireEntities.count != firings.count {
            fireEntities.forEach { $0.removeFromParent() }; fireEntities = []
            for f in firings {
                let k = Float(max(0, 1 - now.timeIntervalSince(f.start) / Self.fireSeconds))   // 1 → 0
                var m = PhysicallyBasedMaterial()
                m.emissiveColor = .init(color: f.color); m.emissiveIntensity = 2 + 8 * k; m.baseColor = .init(tint: f.color)
                let pts = flat ? xyz.map { SIMD3($0.x, $0.y, 0) } : xyz
                if let e = Self.instanced(f.rows, xyz: pts, mesh: MapDot.mesh(radius: 0.004 + 0.004 * k), material: m) {
                    root.addChild(e); fireEntities.append(e)
                }
            }
        }
        pulseEntity?.removeFromParent(); pulseEntity = nil
        var pos: [SIMD3<Float>] = []
        for f in firings {
            let t = Float(now.timeIntervalSince(f.start) / Self.pulseSeconds)
            guard t < 1, let a = f.rows.first else { continue }
            for b in neighbours(of: a).prefix(10) { pos.append(simd_mix(xyz[a], xyz[b], SIMD3(repeating: t))) }
            for a2 in f.rows.dropFirst().prefix(4) { for b in neighbours(of: a2).prefix(3) { pos.append(simd_mix(xyz[a2], xyz[b], SIMD3(repeating: t))) } }
        }
        guard !pos.isEmpty else { return }
        var m = PhysicallyBasedMaterial()
        m.emissiveColor = .init(color: .white); m.emissiveIntensity = 9; m.baseColor = .init(tint: .white)
        let pts = flat ? pos.map { SIMD3($0.x, $0.y, 0) } : pos
        if let e = Self.instanced(Array(pts.indices), xyz: pts, mesh: MapDot.mesh(radius: 0.0028), material: m) { root.addChild(e); pulseEntity = e }
    }

    /// Groups from MapClusters: each region's and each leaf's centre on the map, for their floating names — only when
    /// they were made for the rows this scene shows (after a re-fit the scene is rebuilt first, then they match).
    func setGroups(_ labels: [Int], leaves: [Int], ids: [String]) {
        guard labels.count == xyz.count, ids == builtIds else { return }
        groupOf = labels; groupCentre = Self.centres(labels, xyz)
        leafOf = leaves.count == xyz.count ? leaves : []; leafCentre = Self.centres(leafOf, xyz)
    }
    static func centres(_ labels: [Int], _ xyz: [SIMD3<Float>]) -> [Int: SIMD3<Float>] {
        var sum: [Int: SIMD3<Float>] = [:], n: [Int: Int] = [:]
        for (i, g) in labels.enumerated() { sum[g, default: .zero] += xyz[i]; n[g, default: 0] += 1 }
        return sum.reduce(into: [:]) { r, kv in r[kv.key] = kv.value / Float(n[kv.key] ?? 1) }
    }
    /// Zoomed in past 1.8× the leaves are named instead of the regions.
    var zoomedIn: Bool { root.scale.x > Self.scale * 1.8 && !leafCentre.isEmpty }

    private func firing(at row: Int, glow: Float, lineAlpha: CGFloat, radius: Float) -> (ModelEntity?, ModelEntity?) {
        guard let layout, row < xyz.count else { return (nil, nil) }
        var g = PhysicallyBasedMaterial()
        g.emissiveColor = .init(color: NSColor(accent)); g.emissiveIntensity = glow; g.baseColor = .init(tint: NSColor(accent))
        let nbrs = layout.neighbours(of: row).filter { $0 < xyz.count }
        let pts = flat ? xyz.map { SIMD3($0.x, $0.y, 0) } : xyz
        let glowE = Self.instanced([row] + nbrs, xyz: pts, mesh: MapDot.mesh(radius: radius), material: g)
        if let glowE { root.addChild(glowE) }
        guard !nbrs.isEmpty else { return (glowE, nil) }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = nbrs.count * 2; desc.indexCapacity = nbrs.count * 2
        desc.vertexAttributes = [.init(semantic: .position, format: .float3, offset: 0)]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return (glowE, nil) }
        let p0 = flat ? SIMD3(xyz[row].x, xyz[row].y, 0) : xyz[row]
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.bindMemory(to: SIMD3<Float>.self)
            for (i, n) in nbrs.enumerated() { p[2 * i] = p0; p[2 * i + 1] = flat ? SIMD3(xyz[n].x, xyz[n].y, 0) : xyz[n] }
        }
        mesh.withUnsafeMutableIndices { raw in let p = raw.bindMemory(to: UInt32.self); for i in 0..<(nbrs.count * 2) { p[i] = UInt32(i) } }
        mesh.parts.replaceAll([.init(indexCount: nbrs.count * 2, topology: .line, bounds: BoundingBox(min: p0 - 1, max: p0 + 1))])
        guard let res = try? MeshResource(from: mesh) else { return (glowE, nil) }
        var m = UnlitMaterial(color: NSColor(accent).withAlphaComponent(lineAlpha)); m.blending = .transparent(opacity: .init(floatLiteral: Float(lineAlpha)))
        let e = ModelEntity(mesh: res, materials: [m]); root.addChild(e)
        return (glowE, e)
    }

    func installScrollZoom() {
        scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, pointer != nil else { return e }   // only while the pointer is over the map
            let f = Float(1 + e.scrollingDeltaY * 0.01)
            let s = min(Self.scale * 6, max(Self.scale * 0.3, root.scale.x * f))
            root.scale = SIMD3(repeating: s)
            return nil
        }
    }
    func removeScrollZoom() { if let s = scroll { NSEvent.removeMonitor(s); scroll = nil }; setHand(false) }

    /// Once per frame: fps, the slow turn towards a lit target, and a CPU pick under the pointer at most 10× a second.
    func frame() {
        frames += 1
        let now = Date()
        if let z = pendingZoom, now.timeIntervalSince(builtAt) > 0.6 { root.scale = SIMD3(repeating: Self.scale * z); pendingZoom = nil }
        if now.timeIntervalSince(last) >= 1 {
            fps = Double(frames) / now.timeIntervalSince(last); frames = 0; last = now
            fpsSeconds += 1
            if fpsSeconds == 5 || fpsSeconds % 60 == 0 { HubLog.shared.add(.info, String(format: "map: %@ points at %.0f fps", grouped(xyz.count), fps)) }
        }
        if let t = target {   // turn the map so the lit centroid faces the camera (a slow ease), then stop
            let want = simd_quatf(from: simd_normalize(t == .zero ? SIMD3(0, 0, 1) : t), to: SIMD3(0, 0, 1))
            root.orientation = simd_slerp(root.orientation, want, 0.08)
            if abs(simd_dot(root.orientation.vector, want.vector)) > 0.9995 { target = nil }
        }
        if !firings.isEmpty || pulseEntity != nil || !fireEntities.isEmpty { animateFirings(now) }
        if let p = pointer, now.timeIntervalSince(lastPick) > (xyz.count > 15_000 ? 0.1 : 0.05) { lastPick = now; pick(at: p) }   // a pick projects every point: ~22 ms at 49k
        if frames % 6 == 0, let content, !groupCentre.isEmpty {
            var at: [Int: CGPoint] = [:]
            let zoomed = zoomedIn
            let bounds = CGRect(origin: .zero, size: viewSize).insetBy(dx: -40, dy: -20)
            for (g, c) in zoomed ? leafCentre : groupCentre {
                if let q = content.project(point: root.convert(position: flat ? SIMD3(c.x, c.y, 0) : c, to: nil), to: .local),
                   !zoomed || viewSize == .zero || bounds.contains(q) { at[g] = q }
            }
            if zoomed { leafAt = at; if !labelAt.isEmpty { labelAt = [:] } } else { labelAt = at; if !leafAt.isEmpty { leafAt = [:] } }
        }
    }

    /// The point under the pointer: the one closest in angle to the pointer's ray (no projection per point — 72k
    /// points in well under a millisecond), then checked in pixels. A hidden kind is not picked.
    private func pick(at p: CGPoint) {
        guard let content, !xyz.isEmpty else { return }
        var best = -1; var bd = CGFloat.infinity
        if let ray = content.ray(through: p, in: .local, to: .scene) {
            let o = root.convert(position: ray.origin, from: nil), d = simd_normalize(root.convert(direction: ray.direction, from: nil))
            var ba = Float.infinity
            for i in 0..<xyz.count where !rowKind[i].isEmpty && shown(rowKind[i]) {
                let w = (flat ? SIMD3(xyz[i].x, xyz[i].y, 0) : xyz[i]) - o
                let t = simd_dot(w, d)
                guard t > 0 else { continue }
                let a = (simd_length_squared(w) - t * t) / (t * t)   // tan² of the angle off the ray ~ distance on screen
                if a < ba { ba = a; best = i }
            }
            if best >= 0, let q = content.project(point: root.convert(position: flat ? SIMD3(xyz[best].x, xyz[best].y, 0) : xyz[best], to: nil), to: .local) {
                bd = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
            }
        }
        let hit = best >= 0 && bd < 14 * 14 ? best : nil
        if hit != hoverRow { drawLines(from: hit); hoverRow = hit }
        hoverDoc = hit.map { rowToDoc[$0] }.flatMap { $0 >= 0 ? $0 : nil }
        hoverAt = hoverDoc == nil ? nil : p
        setHand(hoverDoc != nil)
    }

    /// A click selects (the panel opens with its relatives and its group); a click on empty space clears.
    func click() { select(hoverRow) }

    /// Open a doc the way a search result does: a session copies its resume command, the rest open.
    static func open(_ doc: IndexDoc) {
        if doc.kind == "history" { WorkFormat.copy(doc.url) } else if let u = URL(string: doc.url) { WorkFormat.open(u) }
        HubLog.shared.add(.info, "map: open \(doc.kind) \(doc.title.prefix(60))")
    }
}
#endif
