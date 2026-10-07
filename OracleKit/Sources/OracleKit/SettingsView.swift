#if os(macOS)
import SwiftUI

/// Settings, one page per app: the MCP server and the trace of every query, with the debug log. The engine and the
/// indexes are memory settings: they live on the Memory page (the hub: its search page), not here twice.
public struct SettingsView: View {
    let title: String
    let accent: Color
    let indexes: [GHIndex]
    @ObservedObject private var mcp = MCPServer.shared
    @ObservedObject private var trace = TraceLog.shared
    @AppStorage("mcp.enabled") private var mcpEnabled = true
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
                Text("The MCP server agents ask, and every query asked. The engine and the indexes are on the memory page.")
                    .font(.callout).foregroundStyle(.secondary)
                card("MCP", "point.3.connected.trianglepath.dotted", .orange) { mcpCard }
                card("Trace", "list.bullet.rectangle", .green) { traceCard }
                DebugLogView()
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
        .task { if let i = indexes.first { GHIndex.active = i } }
    }

    // MARK: sections

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
}

/// Where an index lives and what the shared vector cache holds — a row of the memory page's engine card.
struct StorageRow: View {
    let index: GHIndex
    @State private var cache: (count: Int, mb: Double) = (0, 0)
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Storage").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text("\(Self.mb(index.filePath)) MB text + \(Self.mb(index.vectorsFilePath)) MB vectors · cache \(grouped(cache.count)) vectors, \(String(format: "%.0f", cache.mb)) MB")
                .lineLimit(1).truncationMode(.middle)
                .help("The shared vector cache: every app on this Mac reuses a vector once it is computed")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: index.filePath), VectorCache.shared.path]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).handCursor().help("Show the index and the vector cache in Finder")
            Spacer(minLength: 0)
        }
        .font(.callout).padding(.vertical, 3)
        .task { await refresh() }
        .onChange(of: index.built) { Task { await refresh() } }
    }
    static func mb(_ path: String) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        return String(format: "%.1f", Double(size) / 1e6)
    }
    private func refresh() async {
        let path = VectorCache.shared.path.path
        cache = await Task.detached(priority: .utility) { () -> (Int, Double) in
            let fm = FileManager.default
            let size = [path, path + "-wal"].reduce(0) { $0 + (((try? fm.attributesOfItem(atPath: $1))?[.size] as? Int) ?? 0) }
            return (VectorCache.shared.count, Double(size) / 1e6)
        }.value
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
