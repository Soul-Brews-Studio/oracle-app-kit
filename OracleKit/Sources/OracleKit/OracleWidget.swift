#if canImport(WidgetKit)
import SwiftUI
import WidgetKit

public struct OracleEntry: TimelineEntry {
    public let date: Date
    public let snap: OracleSnapshot
    public let stale: Bool
}

public struct OracleProvider: TimelineProvider {
    let config: OracleConfig
    public init(config: OracleConfig) { self.config = config }
    public func placeholder(in context: Context) -> OracleEntry { OracleEntry(date: Date(), snap: .placeholder(config), stale: false) }
    public func getSnapshot(in context: Context, completion: @escaping (OracleEntry) -> Void) { completion(entry()) }
    public func getTimeline(in context: Context, completion: @escaping (Timeline<OracleEntry>) -> Void) {
        // the app pushes reloads after each refresh; this is only the fallback poll
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(300))))
    }
    func entry() -> OracleEntry {
        if let s = SnapshotStore.read(group: config.widgetGroup) {
            return OracleEntry(date: Date(), snap: s, stale: Date().timeIntervalSince(s.updated) > 600)
        }
        var p = OracleSnapshot.placeholder(config); p.working = 0; p.panes = 0; p.prs = 0; p.issues = 0; p.inbox = 0; p.topPR = "open the \(config.name) app once"
        return OracleEntry(date: Date(), snap: p, stale: true)
    }
}

public struct OracleWidgetView: View {
    let e: OracleEntry
    @Environment(\.widgetFamily) private var family
    public init(entry: OracleEntry) { e = entry }
    private var c: Color { Color(hex: e.snap.colorHex) }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(c.gradient).frame(width: 26, height: 26)
                    Image(systemName: e.snap.symbol).font(.caption.bold()).foregroundStyle(.white)
                }
                Text(e.snap.name).font(.headline)
                Spacer()
                Circle().fill(e.snap.working > 0 ? c : .gray).frame(width: 8, height: 8)
            }
            Text(e.snap.working > 0 ? "\(e.snap.working) working · \(e.snap.panes) panes" : "idle · \(e.snap.panes) panes")
                .font(.caption.bold()).foregroundStyle(e.snap.working > 0 ? c : .secondary)
            HStack(spacing: 10) {
                stat("arrow.triangle.pull", e.snap.prs)
                stat("exclamationmark.circle", e.snap.issues)
                stat("tray.full", e.snap.inbox)
            }
            if family != .systemSmall, let t = e.snap.topPR { Text(t).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Text(e.stale ? "stale · \(e.snap.updated.formatted(date: .omitted, time: .shortened))"
                         : "updated \(e.snap.updated.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(e.stale ? .orange : .secondary)
        }
        .containerBackground(for: .widget) { Color(red: 0.04, green: 0.04, blue: 0.06) }
        .widgetURL(URL(string: "oracle-\(e.snap.name.lowercased())://open"))
    }
    private func stat(_ sym: String, _ n: Int) -> some View {
        Label("\(n)", systemImage: sym).font(.caption.monospacedDigit()).labelStyle(.titleAndIcon)
    }
}

/// One status widget for an oracle; the per-oracle widget target is three lines that call this.
public enum OracleWidgetKit {
    public static func configuration(_ config: OracleConfig) -> some WidgetConfiguration {
        StaticConfiguration(kind: "oracle.status.\(config.name.lowercased())", provider: OracleProvider(config: config)) {
            OracleWidgetView(entry: $0)
        }
        .configurationDisplayName("\(config.name) status")
        .description("\(config.name): working panes, open PRs, issues and inbox.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
#endif
