#if os(macOS)
import SwiftUI
import NaturalLanguage

/// What is being searched, as a tag cloud: the words of every query (this launch and the ones before, from the query
/// log), sized by how often they are asked, colored by who asked — MCP agents orange, the page in the app's color.
/// Apple's tokenizer splits the words, so Thai queries cloud by word too.
struct SearchCloud: View {
    let accent: Color
    @Binding var who: String                     // all · mcp · page
    var selected: Binding<String?> = .constant(nil)   // a word clicked: the trace list filters by it
    var limit = 48
    var scale: CGFloat = 1
    var header = true
    var minHeight: CGFloat = 0   // the Trace page: a big square the words float in
    var center = false
    @ObservedObject private var trace = TraceLog.shared

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
        return all.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }.prefix(limit).map { $0 }
    }

    var body: some View {
        let words = cloud
        let top = Double(max(words.first?.count ?? 1, 4))   // a young cloud (a query or two) stays calm, not all huge
        VStack(alignment: .leading, spacing: 8) {
            if header {
                HStack {
                    Text("What's searched").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $who) { Text("All").tag("all"); Text("MCP").tag("mcp"); Text("Page").tag("page") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Spacer()
                    Text("\(trace.past.count + trace.entries.count) queries · every launch").font(.caption).foregroundStyle(.secondary)
                }
            }
            if words.isEmpty {
                Text("no query yet — search a page, or ask over MCP").font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Flow(spacing: center ? 14 : 8, center: center) {
                    ForEach(words.shuffledStable()) { w in
                        let share = Double(w.count) / top
                        let tint = w.mcp * 2 >= w.count ? Color.orange : accent
                        let on = selected.wrappedValue == w.id
                        Text(w.id)
                            .font(.system(size: (11 + 17 * share) * scale, weight: share > 0.6 ? .bold : share > 0.3 ? .semibold : .regular, design: .rounded))
                            .foregroundStyle(tint.opacity(on ? 1 : 0.45 + 0.55 * share))
                            .shadow(color: tint.opacity(share > 0.6 || on ? 0.6 : 0), radius: 8)
                            .padding(.horizontal, on ? 6 : 0)
                            .background(Capsule().fill(on ? tint.opacity(0.18) : .clear))
                            .onTapGesture { selected.wrappedValue = on ? nil : w.id }
                            .handCursor()
                            .help("\(w.count) quer\(w.count == 1 ? "y" : "ies") · \(w.mcp) from MCP — last: \(w.last) · click to filter")
                    }
                }
                .padding(center ? 24 : 12)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: center ? .center : .leading)
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

/// Lays children left to right, wrapping to a new line when the row is full; each child sits in the middle of its
/// row's height, and `center` centres every row (a cloud).
struct Flow: Layout {
    var spacing: CGFloat = 8
    var center = false

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var out: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { out.append([]); x = 0 }
            out[out.count - 1].append((i, size)); x += size.width + spacing
        }
        return out
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // no width offered (an ideal-size pass): one long row — never a guess that placement would disagree with
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let rs = rows(subviews, width: width)
        let height = rs.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * CGFloat(max(0, rs.count - 1))
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(subviews, width: bounds.width) {
            let h = r.map(\.1.height).max() ?? 0
            let w = r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, r.count - 1))
            var x = bounds.minX + (center ? max(0, (bounds.width - w) / 2) : 0)
            for (i, size) in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += h + spacing
        }
    }
}
#endif
