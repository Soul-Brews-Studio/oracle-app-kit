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
    @ObservedObject var clusters: MapClusters
    @ObservedObject private var trace = TraceLog.shared
    @ObservedObject private var heard = QueryListener.shared
    /// The hub's map of every oracle (#37): points coloured by oracle, every app's queries fire it.
    let fleet: FleetMap?
    @State private var byKind = false
    @State private var dominant: [Int: String] = [:]   // a region's oracle, when it holds ≥ 80 % of it
    @State private var kindCounts: [String: Int] = [:]  // the legend's counts, counted once per change of the docs —
    @State private var oracleCounts: [(String, Int)] = []   // not on every redraw (labels move ten times a second)
    @StateObject private var scene: MapScene
    @State private var escMonitor: Any?
    @State private var query = ""
    @State private var who = "all"
    @State private var flat = false
    @State private var showGroups = false
    @State private var openRegion: Int?
    @FocusState private var focused: Bool
    private static var actionDone = false

    public init(name: String, accent: Color, index: GHIndex, fleet: FleetMap? = nil) {
        self.name = name; self.accent = accent; self.index = index; self.layout = index.layout; self.clusters = index.clusters; self.fleet = fleet
        _scene = StateObject(wrappedValue: MapScene(accent: accent, fleet: fleet))
    }

    public var body: some View {
        handlers(page).task { await prepare() }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MAP").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
                Text("\(name)'s map").font(.custom("Avenir Next", size: 34).weight(.bold))
                Text("\(grouped(layout.xyz.count)) memories in one space — close means related, lines join nearest neighbours.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                legend
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 10)
            ZStack(alignment: .bottomLeading) {
                if layout.xyz.isEmpty { empty } else {
                    RealityView { content in
                        var content = content
                        scene.build(into: &content, layout: layout, docs: index.docs)
                        _ = content.subscribe(to: SceneEvents.Update.self) { _ in scene.frame() }
                    } update: { _ in }
                    // a new layout (a re-fit, docs placed) is a new scene: rows and positions changed together
                    .id("\(layout.meta?.built.timeIntervalSince1970 ?? 0)·\(layout.xyz.count)")
                    .realityViewCameraControls(.orbit)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let p) = phase { scene.pointer = p } else { scene.pointer = nil; scene.hoverDoc = nil; scene.setHand(false) }
                    }
                    .onTapGesture { scene.click() }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.viewSize = $0 }
                    .background(Color(red: 0.03, green: 0.03, blue: 0.05))
                    .onAppear { scene.installScrollZoom() }
                    .onDisappear { scene.removeScrollZoom() }
                }
                groupLabels
                if let r = scene.selectedRow, let d = scene.doc(row: r) {
                    panel(row: r, doc: d).frame(width: 340).padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                controls.padding(14)
                VStack(alignment: .leading, spacing: 10) {
                    searchField.frame(maxWidth: 460)
                    if showGroups { groupList.frame(width: 300).transition(.move(edge: .leading).combined(with: .opacity)) }
                }
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                GeometryReader { g in
                    if let d = scene.hoverDoc.flatMap({ $0 < scene.docs.count ? scene.docs[$0] : nil }), let p = scene.hoverAt {   // the scene's docs: the ones its rows point at
                        let flipX = p.x > g.size.width - 340, flipY = p.y > g.size.height - 110
                        hoverCard(d).fixedSize(horizontal: false, vertical: true).frame(width: 320, alignment: .leading)
                            .offset(x: flipX ? p.x - 336 : p.x + 18, y: flipY ? p.y - 96 : p.y + 16)
                            .animation(.easeOut(duration: 0.08), value: p)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, 28).padding(.bottom, 14)
        }
    }

    /// What the page reacts to: the layout and the groups changing, every traced or heard query, the switches.
    private func handlers<V: View>(_ v: V) -> some View {
        switches(events(v))
            .animation(.easeOut(duration: 0.18), value: scene.selectedRow)
            .animation(.easeOut(duration: 0.18), value: showGroups)
            .onAppear { installEsc() }
            .onDisappear { if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil } }
    }

    /// The layout, the groups and every traced or heard query.
    private func events<V: View>(_ v: V) -> some View {
        v.onChange(of: layout.xyz.count) { scene.needsRebuild = true }
        // a fit that ends while the page is open (the fleet map fits in the background): the groups follow the new rows
        .onChange(of: layout.meta?.built) { Task { await clusters.refresh(layout: layout, docs: index.docs) } }
        .onChange(of: clusters.revision) { regroupScene() }
        .onChange(of: scene.built) { regroupScene() }
        // #36: every query asked of this memory — a page, the map, another oracle over MCP — fires its hits
        // keyed on the newest entry, not the count: TraceLog keeps 500, so past that the count stops changing
        .onChange(of: trace.entries.last?.id) { _, _ in fireTraced() }
        // #37: a query another oracle app answered
        .onChange(of: heard.last?.id) { _, _ in fireHeard() }
    }

    /// The page's own switches: kinds, 2D, colour by oracle or kind, the legend's counts.
    private func switches<V: View>(_ v: V) -> some View {
        v.onChange(of: who) { scene.show(kinds: who) }
        .onChange(of: flat) { scene.flatten(flat) }
        .onChange(of: byKind) { scene.recolor(byKind: byKind) }
        .onChange(of: index.docs.count, initial: true) { count() }
    }

    private func regroupScene() {
        scene.setGroups(clusters.labels, leaves: clusters.leafLabels, ids: clusters.layoutIds)
        placeOracles()
    }

    /// esc: clear the selection, then the lit hits.
    private func installEsc() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53 else { return e }
            if scene.selectedRow != nil { scene.select(nil); return nil }
            if !scene.lit.isEmpty { scene.light([]); query = ""; return nil }
            return e
        }
    }

    /// The last query traced in this app, when it was asked of this map's memory (or, on the fleet map, of any index
    /// in it): its hits fire in the caller's colour.
    private func fireTraced() {
        guard let e = trace.entries.last else { return }
        guard e.index == index.name || fleet?.members.contains(where: { $0.id == e.index }) == true else { return }
        let rows = e.top.compactMap { layout.row(of: $0.id) }
        scene.fire(rows: rows, color: MapScene.callerColor(e.caller, source: e.source, accent: accent), label: Self.who(e))
    }

    /// Fleet map: a query another oracle app answered fires in that oracle's colour (Pulse's memory lights Pulse
    /// red); the caption says who asked.
    private func fireHeard() {
        guard let fleet, let e = heard.last else { return }
        let rows: [Int] = e.hashes.compactMap { scene.row(ofHash: $0) }
        if rows.count < e.hashes.count { fleet.missed(e.hashes.count - rows.count) }   // hits newer than the union: read again
        let owner = FleetMap.oracle(ofIndex: e.index)
        let who = e.asker ?? (e.source == "mcp" ? "an agent" : "you")
        // the words are in the answering app's own query log, not in the notification
        let words = e.trace.flatMap { QueryBroadcast.query(trace: $0, app: owner) }.map { " “\($0.prefix(40))”" } ?? ""
        scene.fire(rows: rows, color: FleetMap.color(owner), label: "\(who) asked \(owner)\(words)")
    }

    /// On open: the model, the layout (fitted when missing or stale), the groups, and the test hooks.
    private func prepare() async {
        if GHIndex.loaded == nil, !ModelLoad.shared.loading, ModelLoad.shared.failed == nil, !ModelLoad.shared.absent {
            ModelLoad.shared.reload?(UserDefaults.standard.string(forKey: "hub.engineMode") ?? "gpu")
        }
        if layout.xyz.isEmpty, layout.staleReason(docs: index.docs, space: index.space) != nil, !layout.running {
            await layout.fit(docs: index.docs, space: index.space, why: "Map page opened with no layout")
        } else if let why = layout.staleReason(docs: index.docs, space: index.space), !layout.running {
            await layout.fit(docs: index.docs, space: index.space, why: why)
        }
        await clusters.refresh(layout: layout, docs: index.docs)
        scene.setGroups(clusters.labels, leaves: clusters.leafLabels, ids: clusters.layoutIds)
        placeOracles()
        if UserDefaults.standard.bool(forKey: "mapGroups") { showGroups = true }   // -mapGroups YES (tests)
        if let id = UserDefaults.standard.string(forKey: "mapSelect") {   // -mapSelect <doc id> (tests: one point's panel)
            for _ in 0..<300 where scene.built == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            if let r = layout.row(of: id) { scene.select(r) } else { HubLog.shared.add(.error, "map: -mapSelect \(id) is not on the map") }
        }
        if !Self.actionDone, let q = UserDefaults.standard.string(forKey: "mapQuery"), !q.isEmpty {   // -mapQuery <text> (tests)
            Self.actionDone = true
            for _ in 0..<600 where layout.xyz.isEmpty || scene.built == 0 || ModelLoad.shared.loading { try? await Task.sleep(for: .milliseconds(100)) }
            query = q; await search()
            if UserDefaults.standard.bool(forKey: "mapSelectFirst"), let r = scene.lit.first { scene.select(r) }   // -mapSelectFirst YES (tests)
        }
    }

    /// The colour key, with counts — the only place a colour is explained.
    private var legend: some View {
        let counts = kindCounts
        return HStack(spacing: 16) {
            if fleet != nil, !byKind {
                ForEach(oracleCounts, id: \.0) { o, n in
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: FleetMap.color(o))).frame(width: 8, height: 8)
                        Text("\(o) \(grouped(n))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
            ForEach([("history", "sessions"), ("note", "ψ notes"), ("issue", "issues"), ("pr", "PRs")], id: \.0) { k, label in
                if let n = counts[k], n > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: MapScene.color(k, accent: accent))).frame(width: 8, height: 8)
                        Text("\(grouped(n)) \(label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            }
            if fleet != nil {
                Picker("", selection: $byKind) { Text("By oracle").tag(false); Text("By kind").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            ForEach(scene.recentFirings.prefix(3), id: \.id) { f in
                HStack(spacing: 6) { Circle().fill(Color(nsColor: f.color)).frame(width: 8, height: 8).shadow(color: Color(nsColor: f.color), radius: 4)
                    Text(f.label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if !scene.lit.isEmpty {
                HStack(spacing: 6) { Circle().fill(.white).frame(width: 8, height: 8).shadow(color: .white, radius: 4)
                    Text("\(scene.lit.count) lit by the search").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// The names of the biggest groups, floating at their centres — the regions, or, zoomed in, the leaves of what is
    /// on screen. A name lights its whole group.
    private var groupLabels: some View {
        let leafLevel = !scene.leafAt.isEmpty
        let at = leafLevel ? scene.leafAt : scene.labelAt
        let all = leafLevel ? clusters.leaves : clusters.groups
        // biggest first; a name that would overlap one already placed is left out (hover its group to see it)
        var placed: [CGPoint] = []
        let shown = all.sorted { $0.count > $1.count }.filter { g in
            guard let p = at[g.id], !placed.contains(where: { abs($0.x - p.x) < 150 && abs($0.y - p.y) < 26 }) else { return false }
            placed.append(p); return true
        }.prefix(leafLevel ? 16 : 12)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown)) { g in
                if let p = at[g.id] {
                    Button { scene.focus(group: g.id, leaf: leafLevel) } label: {
                        Text(!leafLevel ? dominant[g.id].map { "\($0) · \(g.name)" } ?? g.name : g.name)
                            .font(leafLevel ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(leafLevel ? 0.75 : 0.85))
                            .padding(.horizontal, leafLevel ? 6 : 8).padding(.vertical, leafLevel ? 2 : 3)
                            .background(.black.opacity(leafLevel ? 0.45 : 0.55), in: Capsule())
                            .overlay(Capsule().strokeBorder(accent.opacity(leafLevel ? 0.22 : 0.35)))
                    }
                    .buttonStyle(.plain).handCursor().help("\(grouped(g.count)) memories — \(g.keywords.prefix(5).joined(separator: " · ")) — click to light the group")
                    .fixedSize().position(p)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every region with its count; open one for its leaves. A click lights the group and turns the map to it.
    private var groupList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("GROUPS").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                Text("\(clusters.groups.count) regions · \(clusters.leaves.count) smaller").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { showGroups = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).handCursor().help("Close")
            }
            if clusters.running { Text("grouping…").font(.caption).foregroundStyle(.secondary) }
            else if !clusters.titling.isEmpty { Text("\(clusters.titling) — Apple's on-device model names them").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(clusters.groups.sorted { $0.count > $1.count }) { g in
                        groupRow(g, leaf: false)
                        if openRegion == g.id {
                            ForEach(clusters.leaves.filter { $0.parent == g.id }.sorted { $0.count > $1.count }) { l in groupRow(l, leaf: true) }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(12)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.35)))
    }

    private func groupRow(_ g: MapClusters.Group, leaf: Bool) -> some View {
        Button {
            scene.focus(group: g.id, leaf: leaf)
            if !leaf { openRegion = openRegion == g.id ? nil : g.id }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !leaf { Image(systemName: openRegion == g.id ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary).frame(width: 10) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.name).font(leaf ? .caption : .callout.weight(.medium)).lineLimit(1)
                    if g.title != nil { Text(g.keywords.prefix(4).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(grouped(g.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.leading, leaf ? 22 : 4).padding(.trailing, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor().help(leaf ? "Light this group and turn to it" : "Light this region and turn to it; shows its smaller groups")
    }

    /// The clicked point: what it is, what is closest to it (its nearest neighbours in meaning), and its group.
    private func panel(row: Int, doc d: IndexDoc) -> some View {
        let rel = scene.neighbours(of: row).prefix(15).compactMap { r in scene.doc(row: r).map { (r, $0) } }
        let g = scene.group(of: row).flatMap { gid in clusters.groups.first { $0.id == gid } }
        let leaf = scene.leaf(of: row).flatMap { lid in clusters.leaves.first { $0.id == lid } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Circle().fill(Color(nsColor: MapScene.color(d.kind, accent: accent))).frame(width: 9, height: 9).padding(.top, 5)
                Text(d.kind == "history" && !d.snippet.isEmpty ? d.snippet : d.title).font(.callout.weight(.semibold)).lineLimit(4)
                Spacer(minLength: 4)
                Button { scene.select(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).handCursor().help("Close (esc)")
            }
            Text(meta(d)).font(.caption.monospaced()).foregroundStyle(.secondary)
            if d.kind == "history" { Text("in “\(d.title)”").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            else if !d.snippet.isEmpty { Text(d.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
            HStack {
                Button(d.kind == "history" ? "Copy the command that reopens it" : "Open") { MapScene.open(d) }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.small).handCursor()
                if let o = fleet?.oracleOf[d.id], let app = FleetMap.app(of: o) {
                    Button("Open \(o)") { NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
                        .buttonStyle(.bordered).controlSize(.small).handCursor().help("Open the \(o) app")
                }
            }
            if let g {
                Divider()
                Text("GROUP").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                Text(leaf.map { "\(g.name) › \($0.name)" } ?? g.name).font(.callout.weight(.medium)).lineLimit(2)
                Text((leaf ?? g).keywords.prefix(5).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text("\(grouped((leaf ?? g).count)) memories").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Light the group") { if let leaf { scene.focus(group: leaf.id, leaf: true) } else { scene.focus(group: g.id, leaf: false) } }
                        .buttonStyle(.bordered).controlSize(.small).handCursor()
                }
            }
            Divider()
            Text("CLOSEST IN MEANING").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rel, id: \.0) { r, n in
                        Button { scene.select(r) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Color(nsColor: MapScene.color(n.kind, accent: accent))).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.kind == "history" && !n.snippet.isEmpty ? n.snippet : n.title).font(.caption).lineLimit(2)
                                    Text(meta(n)).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).handCursor().help("Go to it on the map")
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.45)))
    }

    /// "Pulse asked" / "you asked" — the firing's caption.
    static func who(_ e: TraceLog.Entry) -> String {
        let oracle = e.source == "mcp" ? (e.caller?.components(separatedBy: " · ").first ?? "an agent") : "you"
        return "\(oracle) asked “\(e.query.prefix(40))”"
    }

    private func meta(_ d: IndexDoc) -> String {
        let o = fleet?.oracleOf[d.id]
        let base = d.kind == "note" ? "ψ/\(d.state)" : d.kind == "history" ? "session · \(d.state == "user" ? "you asked" : "\(o ?? name) answered") · \(String(d.updated.prefix(10)))" : "\(d.kind) \(d.repo)#\(d.number) · \(d.state.lowercased())"
        return o.map { "\($0) · \(base)" } ?? base
    }

    /// The legend's counts: docs per kind, and per oracle on the fleet map (biggest first).
    private func count() {
        var k: [String: Int] = [:], o: [String: Int] = [:]
        for d in index.docs { k[d.kind, default: 0] += 1; if let fleet { o[fleet.oracleOf[d.id] ?? "Fleet", default: 0] += 1 } }
        kindCounts = k
        oracleCounts = o.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
    private func placeOracles() {
        guard let fleet else { return }
        dominant = fleet.dominant(labels: clusters.labels, ids: clusters.layoutIds)
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
            Button { showGroups.toggle() } label: { Label("Groups", systemImage: "circle.hexagongrid") }
                .buttonStyle(.bordered).controlSize(.small).handCursor().disabled(clusters.groups.isEmpty)
                .help("Every group of this memory — click one to light it")
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
            Text(meta(d)).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let r = scene.hovered, let g = scene.group(of: r).flatMap({ gid in clusters.groups.first { $0.id == gid } }) {
                let leaf = scene.leaf(of: r).flatMap { lid in clusters.leaves.first { $0.id == lid } }
                Text("in \(g.name)" + (leaf.map { " › \($0.name)" } ?? "")).font(.caption).foregroundStyle(accent).lineLimit(1)
            }
            Text("click: what is related, and its group").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
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
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? accent : Color.primary.opacity(0.14), lineWidth: focused ? 1.5 : 1))
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
        rowOfHash = fleet == nil ? [:] : Dictionary(layout.ids.enumerated().map { (QueryBroadcast.hash($1), $0) }, uniquingKeysWith: { a, _ in a })
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
        let sphere = MeshResource.generateSphere(radius: 0.0032)
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
        if let e = Self.instanced(lit, xyz: pts, mesh: MeshResource.generateSphere(radius: 0.006), material: glow) { litEntity = e; root.addChild(e) }
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
    /// A broadcast hit (QueryBroadcast.hash of its id) → its row; built with the scene, on the fleet map only.
    func row(ofHash h: String) -> Int? { rowOfHash[h] }
    private var rowOfHash: [String: Int] = [:]
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
                if let e = Self.instanced(f.rows, xyz: pts, mesh: MeshResource.generateSphere(radius: 0.004 + 0.004 * k), material: m) {
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
        if let e = Self.instanced(Array(pts.indices), xyz: pts, mesh: MeshResource.generateSphere(radius: 0.0028), material: m) { root.addChild(e); pulseEntity = e }
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
        let glowE = Self.instanced([row] + nbrs, xyz: pts, mesh: MeshResource.generateSphere(radius: radius), material: g)
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
