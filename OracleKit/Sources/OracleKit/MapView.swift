#if os(macOS)
import SwiftUI
import RealityKit
import simd

/// The Map page (issue #34): an oracle's memory as one 3-D space — every session piece, ψ note, issue and PR a point
/// at its layout position (MapLayout), related things close together. Orbit with the mouse, scroll to zoom, hover
/// for the title and the point's neighbours, click to open; a search lights its hits and the camera turns to them.
/// RealityKit, instanced (the spike: 49k points at 59 fps); picking is on the CPU (pixelCast never sees instances).
@available(macOS 26, *)
public struct MapView: View {
    let name: String
    let accent: Color
    @ObservedObject var index: GHIndex
    @ObservedObject var layout: MapLayout
    @StateObject private var scene: MapScene
    @State private var query = ""
    @State private var who = "all"
    @State private var flat = false
    @FocusState private var focused: Bool
    private static var actionDone = false

    public init(name: String, accent: Color, index: GHIndex) {
        self.name = name; self.accent = accent; self.index = index; self.layout = index.layout
        _scene = StateObject(wrappedValue: MapScene(accent: accent))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MAP").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(name)'s map").font(.custom("Avenir Next", size: 34).weight(.bold))
                    Spacer()
                    Text(status).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(grouped(layout.xyz.count)) memories in one space — close means related. Drag to turn, scroll to zoom, hover for a title, click to open.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 10)
            ZStack(alignment: .bottomLeading) {
                if layout.xyz.isEmpty { empty } else {
                    RealityView { content in
                        var content = content
                        scene.build(into: &content, layout: layout, docs: index.docs)
                        _ = content.subscribe(to: SceneEvents.Update.self) { _ in scene.frame() }
                    } update: { _ in }
                    .realityViewCameraControls(.orbit)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let p) = phase { scene.pointer = p } else { scene.pointer = nil; scene.hoverDoc = nil }
                    }
                    .onTapGesture { scene.click() }
                    .background(Color(red: 0.03, green: 0.03, blue: 0.05))
                    .onAppear { scene.installScrollZoom() }
                    .onDisappear { scene.removeScrollZoom() }
                }
                controls.padding(14)
                if let d = scene.hoverDoc.flatMap({ $0 < index.docs.count ? index.docs[$0] : nil }) { hoverCard(d).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, 28)
            searchField.padding(.horizontal, 28).padding(.vertical, 12)
        }
        .onChange(of: layout.xyz.count) { scene.needsRebuild = true }
        .onChange(of: who) { scene.show(kinds: who) }
        .onChange(of: flat) { scene.flatten(flat) }
        .task {
            if layout.xyz.isEmpty, layout.staleReason(docs: index.docs, space: index.space) != nil, !layout.running {
                await layout.fit(docs: index.docs, space: index.space, why: "Map page opened with no layout")
            } else if let why = layout.staleReason(docs: index.docs, space: index.space), !layout.running {
                await layout.fit(docs: index.docs, space: index.space, why: why)
            }
            if !Self.actionDone, let q = UserDefaults.standard.string(forKey: "mapQuery"), !q.isEmpty {   // -mapQuery <text> (tests)
                Self.actionDone = true
                for _ in 0..<600 where layout.xyz.isEmpty || scene.built == 0 { try? await Task.sleep(for: .milliseconds(100)) }
                query = q; await search()
            }
        }
    }

    private var status: String {
        if layout.running { return layout.progress.isEmpty ? "laying out…" : layout.progress }
        if scene.fps > 0 { return String(format: "%.0f fps · %@ shown · %d lit", scene.fps, grouped(scene.shown), scene.lit.count) }
        return layout.meta.map { String(format: "fitted in %.1f s", $0.seconds) } ?? ""
    }

    private var empty: some View {
        VStack(spacing: 8) {
            if layout.running {
                ProgressView().controlSize(.small)
                Text(layout.progress.isEmpty ? "laying out \(grouped(index.docs.count)) memories…" : layout.progress).font(.callout).foregroundStyle(.secondary)
            } else if let p = layout.problem {
                Text(p).font(.callout).foregroundStyle(.orange)
            } else if index.docs.isEmpty {
                Text("nothing embedded yet — Memory page: Scan, then Run batch").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(MapLayout.engine == nil ? "this app has no layout engine" : "no map yet").font(.callout).foregroundStyle(.secondary)
                Button("Lay out \(grouped(index.docs.count)) memories") { Task { await layout.fit(docs: index.docs, space: index.space, why: "Map page button") } }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(MapLayout.engine == nil).handCursor()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.03, blue: 0.05))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $who) {
                Text("All").tag("all"); Text("Sessions").tag("history"); Text("ψ notes").tag("note"); Text("Issues & PRs").tag("gh")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("2D", isOn: $flat).toggleStyle(.switch).controlSize(.mini)
            if !scene.lit.isEmpty {
                Button { scene.light([]); query = "" } label: { Label("\(scene.lit.count) lit", systemImage: "xmark.circle.fill") }
                    .buttonStyle(.bordered).controlSize(.small).handCursor().help("Clear the lit hits (esc)")
            }
        }
        .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func hoverCard(_ d: IndexDoc) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(d.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(d.kind == "note" ? "ψ/\(d.state)" : d.kind == "history" ? "session · \(d.state == "user" ? "you asked" : "\(name) answered") · \(String(d.updated.prefix(10)))" : "\(d.kind) \(d.repo)#\(d.number) · \(d.state.lowercased())")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(d.kind == "history" ? "click: copy the command that reopens it" : "click: open").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10).frame(maxWidth: 320, alignment: .leading)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.5)))
        .allowsHitTesting(false)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField("Light up what is about…", text: $query).textFieldStyle(.plain).font(.custom("Avenir Next", size: 16)).focused($focused)
                .onSubmit { Task { await search() } }
            if index.searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? accent : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
        .shadow(color: focused ? accent.opacity(0.45) : .clear, radius: 14)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { scene.light([]); return }
        guard let hits = await index.query(q, limit: 25, source: "map") else { return }
        scene.light(hits.compactMap { layout.row(of: $0.doc.id) })
    }
}

/// The RealityKit side of the Map page: chunks of instanced spheres per kind, a lit set drawn emissive under bloom,
/// hover lines to the kNN neighbours, CPU picking, zoom by scaling the root, fps for the status line.
@available(macOS 26, *)
@MainActor
final class MapScene: ObservableObject {
    @Published var hoverDoc: Int?          // row in the layout = index into docs when the ids match (they do after reconcile)
    @Published var fps = 0.0
    @Published var lit: [Int] = []
    @Published var shown = 0
    var pointer: CGPoint?
    var needsRebuild = false
    private(set) var built = 0
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
    private var last = Date()
    private var lastPick = Date.distantPast
    private var scroll: Any?
    private var flat = false
    private var target: SIMD3<Float>?
    static let chunk = 4_096
    static let scale: Float = 3.2

    init(accent: Color) { self.accent = accent }

    static func color(_ kind: String, accent: Color) -> NSColor {
        switch kind {
        case "note": NSColor(red: 0.67, green: 0.28, blue: 0.74, alpha: 1)
        case "issue": .orange
        case "pr": NSColor(red: 0.4, green: 0.78, blue: 0.4, alpha: 1)
        default: NSColor(accent)
        }
    }

    func build(into content: inout RealityViewCameraContent, layout: MapLayout, docs: [IndexDoc]) {
        self.content = content; self.layout = layout
        root = Entity()
        root.scale = SIMD3(repeating: Self.scale)
        xyz = layout.xyz
        let byId = Dictionary(docs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        rowToDoc = layout.ids.map { byId[$0] ?? -1 }
        rowKind = rowToDoc.map { $0 >= 0 ? docs[$0].kind : "" }
        chunks = []
        let sphere = MeshResource.generateSphere(radius: 0.0022)
        for kind in ["history", "note", "issue", "pr"] {
            var mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: .black)
            mat.emissiveColor = .init(color: Self.color(kind, accent: accent))
            mat.emissiveIntensity = kind == "history" ? 0.55 : 0.85   // under the bloom threshold: only lit points glow
            mat.roughness = .init(floatLiteral: 1)
            let rows = xyz.indices.filter { rowKind[$0] == kind }
            for start in stride(from: 0, to: rows.count, by: Self.chunk) {
                let slice = Array(rows[start..<min(start + Self.chunk, rows.count)])
                if let e = Self.instanced(slice, xyz: xyz, mesh: sphere, material: mat) { chunks.append((kind, e, slice)); root.addChild(e) }
            }
        }
        content.add(root)
        content.cameraTarget = root
        if #available(macOS 27, *) {
            root.components.set(BloomComponent(scope: .unbounded))
            var o = BloomOptionsComponent(); o.strength = 1.2; o.threshold = 1.0; o.blurRadius = 10
            root.components.set(o)
        }
        built += 1; shown = xyz.count; needsRebuild = false
        HubLog.shared.add(.info, "map: \(xyz.count) points in \(chunks.count) chunks")
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

    /// The kind filter: a hidden kind's chunks shrink to nothing — no rebuild.
    func show(kinds: String) {
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
        root.orientation = on ? simd_quatf(angle: 0, axis: [0, 1, 0]) : root.orientation
        relight()
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
        glow.emissiveColor = .init(color: .white); glow.emissiveIntensity = 5; glow.baseColor = .init(tint: .white)
        let pts = flat ? xyz.map { SIMD3($0.x, $0.y, 0) } : xyz
        if let e = Self.instanced(lit, xyz: pts, mesh: MeshResource.generateSphere(radius: 0.0045), material: glow) { litEntity = e; root.addChild(e) }
    }

    /// Lines from a row to its kNN neighbours (the graph the layout built).
    private func drawLines(from row: Int?) {
        lines?.removeFromParent(); lines = nil
        guard let row, let layout, row < xyz.count else { return }
        let nbrs = layout.neighbours(of: row).filter { $0 < xyz.count }
        guard !nbrs.isEmpty else { return }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = nbrs.count * 2; desc.indexCapacity = nbrs.count * 2
        desc.vertexAttributes = [.init(semantic: .position, format: .float3, offset: 0)]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return }
        let p0 = flat ? SIMD3(xyz[row].x, xyz[row].y, 0) : xyz[row]
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.bindMemory(to: SIMD3<Float>.self)
            for (i, n) in nbrs.enumerated() { p[2 * i] = p0; p[2 * i + 1] = flat ? SIMD3(xyz[n].x, xyz[n].y, 0) : xyz[n] }
        }
        mesh.withUnsafeMutableIndices { raw in let p = raw.bindMemory(to: UInt32.self); for i in 0..<(nbrs.count * 2) { p[i] = UInt32(i) } }
        mesh.parts.replaceAll([.init(indexCount: nbrs.count * 2, topology: .line, bounds: BoundingBox(min: p0 - 1, max: p0 + 1))])
        guard let res = try? MeshResource(from: mesh) else { return }
        var m = UnlitMaterial(color: NSColor(accent).withAlphaComponent(0.6)); m.blending = .transparent(opacity: 0.6)
        let e = ModelEntity(mesh: res, materials: [m]); lines = e; root.addChild(e)
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
    func removeScrollZoom() { if let s = scroll { NSEvent.removeMonitor(s); scroll = nil } }

    /// Once per frame: fps, the slow turn towards a lit target, and a CPU pick under the pointer at most 10× a second.
    func frame() {
        frames += 1
        let now = Date()
        if now.timeIntervalSince(last) >= 1 { fps = Double(frames) / now.timeIntervalSince(last); frames = 0; last = now }
        if let t = target {   // turn the map so the lit centroid faces the camera (a slow ease), then stop
            let want = simd_quatf(from: simd_normalize(t == .zero ? SIMD3(0, 0, 1) : t), to: SIMD3(0, 0, 1))
            root.orientation = simd_slerp(root.orientation, want, 0.08)
            if abs(simd_dot(root.orientation.vector, want.vector)) > 0.9995 { target = nil }
        }
        if let p = pointer, now.timeIntervalSince(lastPick) > 0.1 { lastPick = now; pick(at: p) }
    }

    private func pick(at p: CGPoint) {
        guard let content, !xyz.isEmpty else { return }
        var best = -1; var bd = CGFloat.infinity
        for i in 0..<xyz.count where rowKind[i].isEmpty == false {
            let v = flat ? SIMD3(xyz[i].x, xyz[i].y, 0) : xyz[i]
            if let q = content.project(point: root.convert(position: v, to: nil), to: .local) {
                let dd = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y); if dd < bd { bd = dd; best = i }
            }
        }
        let hit = best >= 0 && bd < 14 * 14 ? best : nil
        if hit != hoverDoc.flatMap({ d in rowToDoc.firstIndex(of: d) }) { drawLines(from: hit) }
        hoverDoc = hit.map { rowToDoc[$0] }.flatMap { $0 >= 0 ? $0 : nil }
    }

    func click() {
        guard let d = hoverDoc, let layout, let docs = layoutDocs, d < docs.count else { return }
        _ = layout
        let doc = docs[d]
        if doc.kind == "history" { WorkFormat.copy(doc.url) } else if let u = URL(string: doc.url) { WorkFormat.open(u) }
        HubLog.shared.add(.info, "map: click \(doc.kind) \(doc.title.prefix(60))")
    }
    var layoutDocs: [IndexDoc]? { (GHIndex.active ?? GHIndex.shared).docs }
}
#endif
