#if canImport(WidgetKit)
import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct OracleEntry: TimelineEntry {
    public let date: Date
    public let snap: OracleSnapshot
    public let stale: Bool
}

public struct OracleProvider: TimelineProvider {
    let config: OracleConfig
    public init(config: OracleConfig) { self.config = config }
    public func placeholder(in context: Context) -> OracleEntry { OracleEntry(date: Date(), snap: .placeholder(config), stale: false) }
    public func getSnapshot(in context: Context, completion: @escaping (OracleEntry) -> Void) {
        completion(entries("snapshot", count: 1).first!)
    }
    public func getTimeline(in context: Context, completion: @escaping (Timeline<OracleEntry>) -> Void) {
        // One entry per 5 min for 30 min so the ages ("12m") and the stale flag stay true between app pushes.
        completion(Timeline(entries: entries("timeline", count: 7), policy: .after(Date().addingTimeInterval(1800))))
    }
    func entries(_ stage: String, count: Int) -> [OracleEntry] {
        var snap = SnapshotStore.read(config: config, stage: stage)
        if snap == nil {
            var p = OracleSnapshot.placeholder(config)
            p.working = 0; p.panes = 0; p.prs = 0; p.issues = 0; p.inbox = 0; p.needsYou = 0; p.inboxNew = 0
            p.activity = []; p.prTitles = []; p.latestHandoff = nil; p.topPR = nil
            snap = p
        }
        let now = Date()
        return (0..<count).map { i in
            let d = now.addingTimeInterval(Double(i) * 300)
            return OracleEntry(date: d, snap: snap!, stale: d.timeIntervalSince(snap!.updated) > 600)
        }
    }
}

/// The widget as WidgetKit hosts it: reads family + rendering mode, adds the background.
public struct OracleWidgetView: View {
    let e: OracleEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    public init(entry: OracleEntry) { e = entry }
    public var body: some View {
        OracleWidgetContent(snap: e.snap,
                            size: family == .systemSmall ? .small : family == .systemLarge ? .large : .medium,
                            tinted: mode != .fullColor, now: e.date, stale: e.stale, emblem: Self.bundledEmblem)
            .containerBackground(for: .widget) { OracleWidgetContent.background }
            .widgetURL(URL(string: "oracle-\(e.snap.name.lowercased())://open"))
    }
    /// "Emblem" in the widget's own asset catalog (the Codex icon), when the template put one there.
    static var bundledEmblem: Image? {
        #if os(macOS)
        NSImage(named: "Emblem").map { Image(nsImage: $0) }
        #else
        UIImage(named: "Emblem").map { Image(uiImage: $0) }
        #endif
    }
}

/// Pure SwiftUI (no WidgetKit environment), so previews can be rendered offline.
/// Spec: Pigment, 2026-10-07 — one hero per widget, the rest whispers; oracle colour only on the
/// emblem, the hero and the working dot; flat symbol instead of the glow PNG when tinted.
public struct OracleWidgetContent: View {
    public enum Size { case small, medium, large }
    let snap: OracleSnapshot, size: Size, tinted: Bool, now: Date, stale: Bool, emblem: Image?

    public init(snap: OracleSnapshot, size: Size, tinted: Bool, now: Date, stale: Bool, emblem: Image?) {
        self.snap = snap; self.size = size; self.tinted = tinted; self.now = now; self.stale = stale; self.emblem = emblem
    }

    public static var background: some View {
        LinearGradient(colors: [Color(hex: "#0a0a0f"), Color(hex: "#14141c")], startPoint: .top, endPoint: .bottom)
    }

    private var accent: Color { Color(hex: snap.colorHex) }
    private var needsYou: Int { snap.needsYou ?? 0 }
    private var heroValue: Int { needsYou > 0 ? needsYou : snap.working }
    private var heroLabel: String { needsYou > 0 ? "need you" : "working" }

    /// blocked > done > working > idle; idle only when nothing else is going on.
    private var rows: [OracleSnapshot.Activity] {
        let rank = ["blocked": 0, "done": 1, "working": 2, "idle": 3]
        return (snap.activity ?? []).sorted { (rank[$0.status] ?? 4) < (rank[$1.status] ?? 4) }
    }
    private var task: String {
        if snap.panes == 0 { return "No panes open" }
        return rows.first?.title ?? "All quiet"
    }

    /// Activities after the one the lead already names (medium/large rows never repeat it).
    private var others: [OracleSnapshot.Activity] {
        let rank = ["blocked": 0, "done": 1, "working": 2, "idle": 3]
        let all = (snap.activity ?? []).sorted { (rank[$0.status] ?? 4) < (rank[$1.status] ?? 4) }
        return Array(all.dropFirst())
    }

    public var body: some View {
        Group {
            switch size {
            case .small:
                VStack(alignment: .leading, spacing: 0) { lead; Spacer(minLength: 8); footer }
            case .medium:
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        lead.frame(width: 128, alignment: .leading)
                        paneRows(max: 3).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Spacer(minLength: 6)
                    footer
                }
            case .large:
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        lead.frame(width: 128, alignment: .leading)
                        paneRows(max: 4).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5).padding(.vertical, 14)
                    work
                    Spacer(minLength: 8)
                    footer
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // hero · label · task
    private var lead: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(heroValue)")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(accent)
                .widgetAccentable()
                .padding(.bottom, -4)
            Text(heroLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(task)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.top, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            emblemMark
            Text(snap.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if size == .medium, let u = snap.inboxUnread, u > 0 {
                Text("· \(u) unread").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(stale ? "stale · \(clock(snap.updated))" : clock(snap.updated))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(stale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
        }
    }

    @ViewBuilder private var emblemMark: some View {
        if !tinted, let emblem {
            emblem.resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: snap.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 16, height: 16)
                .widgetAccentable()
        }
    }

    private func paneRows(max n: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if others.isEmpty {
                Text(snap.panes <= 1 ? "No other panes" : "Nothing else running")
                    .font(.system(size: 13)).foregroundStyle(.tertiary).frame(height: 22)
            }
            ForEach(others.prefix(n), id: \.self) { r in
                HStack(spacing: 8) {
                    Circle().fill(dot(r.status)).frame(width: 8, height: 8).widgetAccentable()
                    Text(r.title).font(.system(size: 13)).foregroundStyle(r.status == "idle" ? .secondary : .primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(age(r)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(height: 22)
            }
        }
        .padding(.top, 8)
    }

    // large only: what changes a decision — PRs, issues, what came in
    private var work: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(snap.prs)").font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(snap.prs == 1 ? "open PR" : "open PRs").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach((snap.prTitles ?? []).prefix(2), id: \.self) { t in
                Text(t).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(snap.inboxUnread ?? 0)").font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("unread in inbox").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(snap.issues) \(snap.issues == 1 ? "issue" : "issues")")
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            ForEach((snap.unreadTitles ?? []).prefix(2), id: \.self) { t in
                Text(t).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
            }
            if (snap.unreadTitles ?? []).isEmpty, let h = snap.latestHandoff {
                Text("latest handoff: \(h)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private func dot(_ s: String) -> Color {
        switch s {
        case "blocked": return .red
        case "done": return .green
        case "working": return accent
        default: return .white.opacity(0.35)
        }
    }
    private func age(_ a: OracleSnapshot.Activity) -> String {
        guard let since = a.since else { return "" }
        let m = Int(now.timeIntervalSince(since) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        if m < 1440 { return "\(m / 60)h" }
        return "\(m / 1440)d"
    }
    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
#endif
