#if os(macOS)
import SwiftUI

// MARK: - ⌘K: jump to an oracle or a session by name (Nat, 2026-10-09: "cmd k oracle name, cmd f issues / pr")

/// One row of the switcher: a herdr session, or an oracle (its session when it runs, else its app).
enum HubJump: Hashable, Identifiable {
    case session(name: String, running: Bool)
    case oracle(name: String, repo: String, session: String?, appKey: String)
    var id: String {
        switch self { case .session(let n, _): "s:" + n; case .oracle(_, let r, _, _): "o:" + r }
    }

    /// Oracles first, then sessions; a name that starts with the query before one that only contains it.
    static func matches(_ query: String, sessions: [HubSession], oracles: [HubOracle], limit: Int = 12) -> [HubJump] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func rank(_ s: String) -> Int? {
            let s = s.lowercased()
            if q.isEmpty { return 1 }
            return s.hasPrefix(q) ? 0 : s.contains(q) ? 1 : nil
        }
        let o = oracles.compactMap { o -> (Int, HubJump)? in
            guard let r = [rank(o.name), rank(o.repo)].compactMap({ $0 }).min() else { return nil }
            return (r, .oracle(name: o.name, repo: o.repo, session: o.spaces.first?.session, appKey: o.appKey))
        }
        let s = sessions.compactMap { s -> (Int, HubJump)? in
            rank(s.name).map { ($0, .session(name: s.name, running: s.running)) }
        }
        let ranked: [(Int, HubJump)] = o.sorted { $0.0 < $1.0 } + s.sorted { $0.0 < $1.0 }
        return Array(ranked.prefix(limit)).map { $0.1 }
    }
}

struct HubJumpPalette: View {
    @ObservedObject var store: HubStore
    let go: (HubJump) -> Void
    @State private var keys: Any?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool
    private var rows: [HubJump] { HubJump.matches(query, sessions: store.sessions, oracles: store.oracles) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Oracle or session…   ↩ page · ⌘↩ WezTerm · ⌘F searches issues, PRs", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { pick(cursor) }
                    .onChange(of: query) { cursor = 0 }
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        row(r).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(i == cursor ? HubStyle.accent.opacity(0.22) : .clear))
                            .contentShape(Rectangle()).onTapGesture { pick(i) }
                    }
                    if rows.isEmpty { Text("no oracle or session named like that").foregroundStyle(.secondary).padding(14) }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 520)
        .onAppear {
            focused = true
            // ⌘⏎: straight into WezTerm — the session attached in its window (Nat: "cmd enter to open wezterm, that nsm session")
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.keyCode == 36, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return e }
                wezterm(cursor); return nil
            }
        }
        .onDisappear { if let k = keys { NSEvent.removeMonitor(k); keys = nil } }
        .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(rows.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    @ViewBuilder private func row(_ r: HubJump) -> some View {
        switch r {
        case .oracle(let name, let repo, let session, _):
            HStack {
                Image(systemName: "sparkles").foregroundStyle(HubStyle.accent)
                Text(name).font(.body.weight(.semibold))
                Text(repo).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Text(session.map { "in \($0)" } ?? "open app").font(.caption).foregroundStyle(.secondary)
            }
        case .session(let name, let running):
            HStack {
                Circle().fill(running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(name).font(.body.weight(.semibold))
                Spacer()
                Text(running ? "session" : "session · off").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func wezterm(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        switch rows[i] {
        case .session(let name, _): store.openSession(name)
        case .oracle(_, _, let session, let key): if let session { store.openSession(session) } else { store.openApp(key) }
        }
        dismiss()
    }

    private func pick(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        go(rows[i]); dismiss()
    }
}
#endif
