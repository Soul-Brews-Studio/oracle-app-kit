#if os(macOS)
import SwiftUI

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

    /// The source column: PAGE, MCP, PHONE (a search from the companion app — "COMPANION" would not fit the card's column).
    static func label(_ source: String) -> String { source == "companion" ? "PHONE" : source.uppercased() }

    /// Who asked, as a row shows it: "you" on a page, else the caller the MCP server measured.
    static func from(_ e: TraceLog.Entry) -> String {
        // over MCP or from the phone the caller is measured; the app's own pages (Memory, Map) are you
        e.source == "mcp" || e.source == "companion" ? (e.caller ?? "caller not recorded") : "you"
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
                Text(TraceView.label(e.source)).foregroundStyle(e.source == "mcp" ? Color.orange : accent).lineLimit(1).fixedSize()
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
#endif
