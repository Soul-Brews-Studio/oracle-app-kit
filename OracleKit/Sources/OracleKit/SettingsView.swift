#if os(macOS)
import SwiftUI

/// Settings, one page per app: the embedding engine (ANE / GPU), the vector indexes and the shared cache, the MCP
/// server, and the trace of every query — each with what it logged.
public struct SettingsView: View {
    let title: String
    let accent: Color
    let indexes: [GHIndex]
    @ObservedObject private var load = ModelLoad.shared
    @ObservedObject private var mcp = MCPServer.shared
    @ObservedObject private var trace = TraceLog.shared
    @AppStorage("mcp.enabled") private var mcpEnabled = true
    @State private var cache: (count: Int, mb: Double) = (0, 0)
    @State private var copied = false
    @State private var who = "all"
    /// opens the Trace page (under Memory in the sidebar) — the Trace card's title is its button
    let openTrace: (() -> Void)?

    public init(title: String, accent: Color, indexes: [GHIndex], openTrace: (() -> Void)? = nil) {
        self.title = title; self.accent = accent; self.indexes = indexes; self.openTrace = openTrace
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("SETTINGS").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(title) settings").font(.custom("Avenir Next", size: 34).weight(.bold))
                    Text(AppVersion.calver).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("The engine that embeds, the indexes it fills, the MCP server agents ask, and every query asked.")
                    .font(.callout).foregroundStyle(.secondary)
                card("Engine", "cpu", .cyan) { engine }
                card("Vector search", "sparkle.magnifyingglass", accent) { vectors }
                card("MCP", "point.3.connected.trianglepath.dotted", .orange) { mcpCard }
                card("Trace", "list.bullet.rectangle", .green, open: openTrace) { traceCard }
                DebugLogView()
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
        .task {
            if let i = indexes.first { GHIndex.active = i; await i.checkEngine() }
            await refreshCache()
        }
        .onChange(of: load.finished) { Task { for i in indexes { await i.checkEngine() } } }   // the model loaded meanwhile (an MCP call, another page)
    }

    // MARK: sections

    private var engine: some View {
        VStack(alignment: .leading, spacing: 0) {
            EngineRow(name: "Engine", value: indexes.first?.engine.map { $0.ok ? $0.kind : "not answering" } ?? "checking…")
            if load.loading || load.failed != nil || load.absent { ModelLoadRow(load: load, fallback: false) }
            if indexes.first?.engine?.kind.hasPrefix("bundled") == true { NeuralEngineRow() }
            if !load.absent { EnginePicker(load: load) }
            EngineRow(name: "Model", value: GHIndex.model)
            EngineRow(name: "Loaded from", value: load.root.isEmpty ? "not loaded yet — it loads when a page or an MCP call needs it" : load.root)
            if let f = load.finished, let s = load.started {
                EngineRow(name: "Load", value: String(format: "ready in %.1f s · %d parts · %d compiled, %d from the cache", f.timeIntervalSince(s),
                                                      load.steps.count, load.steps.filter { $0.seconds >= 2 }.count, load.steps.filter { $0.seconds < 2 }.count))
            }
            if load.failed != nil, let retry = load.retry {
                Button("Retry loading") { retry() }.controlSize(.small).handCursor().padding(.top, 6)
            }
        }
    }

    private var vectors: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(indexes, id: \.name) { i in
                let kinds = Dictionary(grouping: i.docs, by: \.kind).mapValues(\.count)
                EngineRow(name: "Index", value: i.name)
                EngineRow(name: "Items", value: "\(grouped(i.docs.count)) — " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \(grouped($0.value))" }.joined(separator: " · "))
                EngineRow(name: "Files", value: "\(Self.mb(i.filePath)) MB text + \(Self.mb(i.vectorsFilePath)) MB vectors · built "
                          + (i.built.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"))
                EngineRow(name: "Vector space", value: i.space ?? "—")
                MapLayoutRow(index: i)
                HStack(spacing: 10) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.filePath)]) }
                    Button("Check engine") { Task { await i.checkEngine() } }
                    Button(i.layout.running ? "Laying out…" : "Rebuild map layout") {
                        Task { await i.layout.fit(docs: i.docs, space: i.space, why: "Rebuild map layout button") }
                    }
                    .disabled(i.layout.running || i.docs.count < 10 || MapLayout.engine == nil)
                }
                .controlSize(.small).buttonStyle(.bordered).handCursor().padding(.vertical, 6)
            }
            Divider().padding(.vertical, 8)
            EngineRow(name: "Vector cache", value: "\(grouped(cache.count)) vectors · \(String(format: "%.0f", cache.mb)) MB — shared by every app; a text is embedded once")
            HStack(spacing: 10) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([VectorCache.shared.path]) }
                Button("Recount") { Task { await refreshCache() } }
            }
            .controlSize(.small).buttonStyle(.bordered).handCursor().padding(.top, 6)
        }
    }

    private var mcpCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $mcpEnabled) { Text("Serve this app's memory to agents over MCP (127.0.0.1 only)") }
                .toggleStyle(.switch).controlSize(.small).padding(.bottom, 6)
                .onChange(of: mcpEnabled) { if mcpEnabled { MCPServer.restart() } else { mcp.stop() } }
            EngineRow(name: "Status", value: mcp.running ? "listening" : (mcpEnabled ? "not listening" : "off"), good: mcp.running ? true : nil)
            if mcp.port > 0 { EngineRow(name: "URL", value: mcp.url) }
            EngineRow(name: "Tools", value: MCPServer.tools.compactMap { $0["name"] as? String }.joined(separator: " · "))
            if mcp.port > 0 {
                HStack(spacing: 8) {
                    Text(mcp.addCommand).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button(copied ? "Copied ✓" : "Copy") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mcp.addCommand, forType: .string)
                        copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                    .controlSize(.small).handCursor()
                }
                .padding(.vertical, 6)
            }
            if let p = mcp.problem { Text(p).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 4) }
            if !mcp.calls.isEmpty {
                Text("Calls").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(mcp.calls.suffix(8).reversed()) { c in
                    HStack(spacing: 8) {
                        Text(HubLog.clock(c.at)).foregroundStyle(.tertiary)
                        Text(c.method).foregroundStyle(Color.orange)
                        Text(c.detail).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text("\(Int(c.ms)) ms").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private var traceCard: some View {
        let all = trace.past + trace.entries   // every launch: the query log, then this launch
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(grouped(all.count)) queries · \(grouped(trace.entries.count)) since launch").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open the query log") { NSWorkspace.shared.open(TraceLog.file) }.controlSize(.small).buttonStyle(.borderless).handCursor()
                    .help(TraceLog.file.path)
            }
            if all.isEmpty {
                Text("no query yet — search a page, or ask over MCP").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(all.suffix(8).reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(Calendar.current.isDateInToday(e.at) ? e.at.formatted(.dateTime.hour().minute().second())
                                                                   : e.at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                        Text(e.source.uppercased()).foregroundStyle(e.source == "mcp" ? Color.orange : accent).frame(width: 40, alignment: .leading)
                        Text("\"\(e.query)\"").lineLimit(1).truncationMode(.tail)
                        Text(e.filter).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f + %.1f ms", e.embedMs, e.rankMs)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    HStack(spacing: 0) {
                        Text("   " + TraceView.from(e)).foregroundStyle(e.source == "mcp" ? Color.orange.opacity(0.85) : accent.opacity(0.85))
                        if let top = e.top.first {
                            Text(String(format: " · best %.0f%% · %@", Double(top.score) * 100, top.title)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            SearchCloud(accent: accent, who: $who).padding(.top, 10)
        }
        .task { await trace.loadPast() }
    }

    // MARK: parts

    /// A card; with `open`, its title is a button (Trace: the Trace page).
    private func card<Content: View>(_ title: String, _ symbol: String, _ tint: Color, open: (() -> Void)? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let open {
                CardTitleButton(title: title, symbol: symbol, tint: tint, trailing: "arrow.right",
                                help: "Open the Trace page — every query and a big cloud of what is searched (under Memory)",
                                action: open)
                    .padding(.bottom, 8)
            } else {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint).padding(.bottom, 8)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    static func mb(_ path: String) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        return String(format: "%.1f", Double(size) / 1e6)
    }

    private func refreshCache() async {
        let path = VectorCache.shared.path.path
        let r = await Task.detached(priority: .utility) { () -> (Int, Double) in
            let fm = FileManager.default
            let size = [path, path + "-wal"].reduce(0) { $0 + (((try? fm.attributesOfItem(atPath: $1))?[.size] as? Int) ?? 0) }
            return (VectorCache.shared.count, Double(size) / 1e6)
        }.value
        cache = r
    }
}

/// A card title that opens something: its icon and name in a pill that lights up under the pointer, so it reads as a
/// button (Nat: "icon around this?").
struct CardTitleButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let trailing: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Label(title, systemImage: symbol).font(.headline)
                Image(systemName: trailing).font(.caption.weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(hover ? 0.18 : 0.09)))
            .overlay(Capsule().strokeBorder(tint.opacity(hover ? 0.55 : 0.28)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).handCursor().onHover { hover = $0 }.help(help)
        .padding(.leading, -9)   // the icon stays in line with the other cards' icons
    }
}

/// Every query asked of this app's memory — from its pages and over MCP — on its own page, under Memory in the
/// sidebar: a big cloud of what is searched (click a word to filter), All / MCP / Page, who asked, a text filter,
/// and every query of every launch; click one for all its top hits. One scroll, and it narrows with the window
/// (a tiled window is 680 pt wide): the cloud shrinks, the filters stack, a row keeps one line.
struct TraceView: View {
    let name: String
    let accent: Color
    @ObservedObject private var trace = TraceLog.shared
    @State private var who = "all"
    @State private var text = ""
    @State private var word: String?
    @State private var open: UUID?
    @State private var asker = ""   // one caller only: "you", "Neo", "Pulse" …
    @State private var width: CGFloat = 900
    /// -traceMaxWidth 420 (tests): the page as a tiled window shows it, whatever the window manager does
    private static let testWidth = UserDefaults.standard.string(forKey: "traceMaxWidth").flatMap(Double.init).map { CGFloat($0) }

    private var narrow: Bool { width < 700 }

    /// Who asked, as a row shows it: "you" on a page, else the caller the MCP server measured.
    static func from(_ e: TraceLog.Entry) -> String {
        e.source != "mcp" ? "you" : (e.caller ?? "caller not recorded")
    }
    /// The first part of `from` — the oracle (or "you") the Who menu lists.
    static func asker(_ e: TraceLog.Entry) -> String { from(e).components(separatedBy: " · ").first ?? "" }

    private var filtered: [TraceLog.Entry] {
        (trace.past + trace.entries).filter { e in
            (who == "all" || (who == "mcp") == (e.source == "mcp"))
                && (asker.isEmpty || Self.asker(e) == asker)
                && (text.isEmpty || e.query.localizedCaseInsensitiveContains(text) || Self.from(e).localizedCaseInsensitiveContains(text))
                && (word == nil || SearchCloud.words(e.query).contains(word!))
        }
    }

    var body: some View {
        let list = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("TRACE").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
                Text(name.hasSuffix("s") ? "\(name)' trace" : "\(name)'s trace").font(.custom("Avenir Next", size: narrow ? 28 : 34).weight(.bold))
                Text("Every query asked of \(name)'s memory — from its pages and over MCP — who asked, and what came back first.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SearchCloud(accent: accent, who: $who, selected: $word, limit: narrow ? 60 : 120, scale: width < 560 ? 1.1 : narrow ? 1.35 : 1.8,
                            header: false, minHeight: narrow ? 200 : 320, center: true)
                filters(list.count)
                LazyVStack(alignment: .leading, spacing: 6) {
                    if list.isEmpty {
                        Text(trace.past.isEmpty && trace.entries.isEmpty ? "no query yet — search the Memory page, or ask over MCP" : "no query matches")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(list.reversed()) { e in row(e) }
                }
            }
            .padding(.horizontal, narrow ? 18 : 28).padding(.top, 22).padding(.bottom, 24)
        }
        .frame(maxWidth: Self.testWidth ?? .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            // hysteresis: the layout flips only past 680 / 720, so a width near the edge cannot make it flip-flop
            let next: CGFloat = narrow ? (w > 720 ? w : min(w, 699)) : (w < 680 ? w : max(w, 700))
            if (next < 700) != narrow { HubLog.shared.add(.info, "trace page: \(Int(w)) pt wide — \(next < 700 ? "narrow" : "wide") layout") }
            if abs(next - width) > 0.5 { width = next }
        }
        .task { await trace.loadPast() }
    }

    @ViewBuilder private func filters(_ shown: Int) -> some View {
        let kind = Picker("", selection: $who) { Text("All").tag("all"); Text("MCP").tag("mcp"); Text("Page").tag("page") }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        let asked = Picker("Who", selection: $asker) {
            Text("Everyone").tag("")
            ForEach(Array(Set((trace.past + trace.entries).map(Self.asker))).sorted(), id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu).fixedSize()
        .help("Who asked: you on a page, or the oracle whose agent called over MCP")
        let field = TextField("filter queries or callers", text: $text).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 300)
        let count = HStack(spacing: 10) {
            if let w = word {
                Button { word = nil } label: { Label(w, systemImage: "xmark.circle.fill") }.buttonStyle(.bordered).controlSize(.small).handCursor()
            }
            Text("\(grouped(shown)) of \(grouped(trace.past.count + trace.entries.count)) queries · every launch")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Open the query log") { NSWorkspace.shared.open(TraceLog.file) }.controlSize(.small).buttonStyle(.borderless).handCursor()
                .help(TraceLog.file.path)
        }
        if narrow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { kind; asked }
                field.frame(maxWidth: .infinity, alignment: .leading)
                count
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { kind; asked; field; Spacer(minLength: 0) }
                count
            }
        }
    }

    private func row(_ e: TraceLog.Entry) -> some View {
        let when = Calendar.current.isDateInToday(e.at) ? e.at.formatted(.dateTime.hour().minute().second())
                                                       : e.at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let cost = narrow ? String(format: "%.0f ms", e.embedMs + e.rankMs)
                          : String(format: "%.0f + %.1f ms · %@ ranked", e.embedMs, e.rankMs, grouped(e.pool))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(when).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                Text(e.source.uppercased()).foregroundStyle(e.source == "mcp" ? Color.orange : accent).lineLimit(1).fixedSize()
                Text("\"\(e.query)\"").lineLimit(1).truncationMode(.tail)
                if !narrow { Text(e.filter).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
                Spacer(minLength: 0)
                Text(cost).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Text("   " + Self.from(e)).foregroundStyle(e.source == "mcp" ? Color.orange.opacity(0.9) : accent.opacity(0.9)).lineLimit(1)
            if open == e.id {
                Text("   \(e.filter) · \(grouped(e.pool)) ranked · \(e.via) · \(e.index)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(e.top.enumerated()), id: \.offset) { i, h in
                    Text(String(format: "   %d. %.0f%%  %@", i + 1, Double(h.score) * 100, h.title)).lineLimit(1)
                }
            } else if let top = e.top.first {
                Text(String(format: "   best %.0f%% · %@", Double(top.score) * 100, top.title)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: narrow ? 11 : 12, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(open == e.id ? 0.08 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { open = open == e.id ? nil : e.id }
        .handCursor()
        .help(open == e.id ? "Click to fold" : "Click for every top hit")
    }
}


/// The 3-D layout of an index (Settings → Vector search): when it was fitted, how long it took, how many were
/// placed since, and why it is stale.
struct MapLayoutRow: View {
    @ObservedObject var index: GHIndex
    @ObservedObject var layout: MapLayout
    init(index: GHIndex) { self.index = index; self.layout = index.layout }
    var body: some View {
        let value: String = {
            if layout.running { return layout.progress.isEmpty ? "laying out…" : layout.progress }
            if let p = layout.problem { return p }
            guard let m = layout.meta else { return MapLayout.engine == nil ? "no layout engine in this app" : "not laid out yet — open the Map page, or Rebuild map layout" }
            var s = String(format: "%@ docs in 3-D · fitted %@ in %.1f s · k %d · %@", grouped(m.n), m.built.formatted(date: .abbreviated, time: .shortened), m.seconds, m.k, m.engine)
            if m.placed > 0 { s += " · \(grouped(m.placed)) placed since" }
            if let why = layout.staleReason(docs: index.docs, space: index.space) { s += " · stale: \(why)" }
            return s
        }()
        EngineRow(name: "Map layout", value: value, good: layout.problem != nil ? false : nil)
    }
}

extension MCPServer {
    /// What this app serves (set once at launch), so Settings can switch it off and on again.
    @MainActor static var launch: (name: String, port: UInt16, index: () -> GHIndex)?
    /// Starts the app's server when MCP is on (Settings → MCP; on by default).
    @MainActor public static func serve(name: String, port: UInt16, index: @escaping () -> GHIndex) {
        guard port > 0 else { return }
        launch = (name, port, index)
        if UserDefaults.standard.object(forKey: "mcp.enabled") as? Bool ?? true { shared.start(name: name, port: port, index: index) }
    }
    @MainActor static func restart() {
        if let l = launch { shared.start(name: l.name, port: l.port, index: l.index) }
    }
}
#endif
