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

    public init(title: String, accent: Color, indexes: [GHIndex]) { self.title = title; self.accent = accent; self.indexes = indexes }

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
                card("Trace", "list.bullet.rectangle", .green) { traceCard }
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
                HStack(spacing: 10) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.filePath)]) }
                    Button("Check engine") { Task { await i.checkEngine() } }
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
        VStack(alignment: .leading, spacing: 4) {
            SearchCloud(accent: accent).padding(.bottom, 8)
            HStack {
                Text("\(trace.entries.count) queries since launch").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open the query log") { NSWorkspace.shared.open(TraceLog.file) }.controlSize(.small).buttonStyle(.borderless).handCursor()
                    .help(TraceLog.file.path)
            }
            if trace.entries.isEmpty {
                Text("no query yet — search a page, or ask over MCP").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(trace.entries.suffix(30).reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(HubLog.clock(e.at)).foregroundStyle(.tertiary)
                        Text(e.source.uppercased()).foregroundStyle(e.source == "mcp" ? Color.orange : accent).frame(width: 40, alignment: .leading)
                        Text("\"\(e.query)\"").lineLimit(1)
                        Text(e.filter).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f + %.1f ms · %@ ranked", e.embedMs, e.rankMs, grouped(e.pool))).foregroundStyle(.secondary)
                    }
                    if let top = e.top.first {
                        Text(String(format: "   best %.0f%% · %@", Double(top.score) * 100, top.title)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    // MARK: parts

    private func card<Content: View>(_ title: String, _ symbol: String, _ tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint).padding(.bottom, 8)
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
