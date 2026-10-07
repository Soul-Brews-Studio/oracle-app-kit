#if os(macOS)
import SwiftUI
import NaturalLanguage

/// What is being searched, as a tag cloud: the words of every query (this launch and the ones before, from the query
/// log), sized by how often they are asked, colored by who asked — MCP agents orange, the page in the app's color.
/// Apple's tokenizer splits the words, so Thai queries cloud by word too.
struct SearchCloud: View {
    let accent: Color
    @ObservedObject private var trace = TraceLog.shared
    @State private var who = "all"

    struct Word: Identifiable { let id: String; var count = 0; var mcp = 0; var last = "" }

    private static let stop: Set<String> = ["the", "a", "an", "of", "to", "and", "or", "in", "on", "for", "with", "is", "are", "was", "be",
        "what", "how", "why", "when", "where", "who", "did", "do", "does", "we", "i", "you", "it", "this", "that", "about", "can", "our",
        "my", "me", "from", "by", "at", "as", "into", "there", "any", "all", "has", "have", "had", "not", "no", "yes", "เรา", "ที่", "และ", "ของ",
        "ใน", "ได้", "ไหม", "มี", "ให้", "จะ", "เป็น", "การ", "ว่า", "กับ", "นี้", "อะไร", "ยังไง"]

    static func words(_ q: String) -> [String] {
        let t = NLTokenizer(unit: .word)
        t.string = q
        return t.tokens(for: q.startIndex..<q.endIndex).map { q[$0].lowercased() }
            .filter { $0.count >= 2 && !stop.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    private var cloud: [Word] {
        var all: [String: Word] = [:]
        for e in trace.past + trace.entries where who == "all" || (who == "mcp") == (e.source == "mcp") {
            for w in Set(Self.words(e.query)) {
                var x = all[w] ?? Word(id: w)
                x.count += 1; if e.source == "mcp" { x.mcp += 1 }; x.last = e.query
                all[w] = x
            }
        }
        return all.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }.prefix(48).map { $0 }
    }

    var body: some View {
        let words = cloud
        let top = Double(words.first?.count ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What's searched").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $who) { Text("All").tag("all"); Text("MCP").tag("mcp"); Text("Page").tag("page") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Spacer()
                Text("\(trace.past.count + trace.entries.count) queries · every launch").font(.caption).foregroundStyle(.secondary)
            }
            if words.isEmpty {
                Text("no query yet — search a page, or ask over MCP").font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Flow(spacing: 8) {
                    ForEach(words.shuffledStable()) { w in
                        let share = Double(w.count) / top
                        let tint = w.mcp * 2 >= w.count ? Color.orange : accent
                        Text(w.id)
                            .font(.system(size: 11 + 17 * share, weight: share > 0.6 ? .bold : share > 0.3 ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(tint.opacity(0.45 + 0.55 * share))
                            .shadow(color: tint.opacity(share > 0.6 ? 0.6 : 0), radius: 8)
                            .help("\(w.count) quer\(w.count == 1 ? "y" : "ies") · \(w.mcp) from MCP — last: \(w.last)")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
            }
        }
        .task { await trace.loadPast() }
    }
}

private extension Array where Element == SearchCloud.Word {
    /// Big and small words mixed, the same way on every render (a cloud, not a ranked list that jumps around).
    func shuffledStable() -> [Element] { sorted { $0.id.hashValue % 97 < $1.id.hashValue % 97 } }
}

/// Lays children left to right, wrapping to a new line when the row is full.
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y + (row > 0 ? 0 : 0)), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
#endif
