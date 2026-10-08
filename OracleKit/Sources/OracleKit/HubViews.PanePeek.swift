#if os(macOS)
import SwiftUI

/// The last lines of a space's busiest pane, shown when the pointer rests on its row (Nat: "hover show tty? preview").
/// Read once per hover: `herdr pane list --workspace <id>` (the agent pane first: working, then waiting, then idle,
/// shells last), then `herdr pane read <pane> --source recent`. The same view serves a local session and a remote one;
/// `run` says where `herdr <args>` goes.
struct PanePeek: View {
    let title: String
    let workspace: String
    let run: ([String]) async -> String?
    @State private var text: String?
    @State private var pane: String?
    static let lines = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pane.map { "\(title) · \($0)" } ?? title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text ?? "reading…")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.86))
                .lineLimit(Self.lines).truncationMode(.tail)
                .frame(width: 520, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .task { await load() }
    }

    private func load() async {
        guard let list = await run(["pane", "list", "--workspace", workspace]),
              let o = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any],
              let panes = (o["result"] as? [String: Any])?["panes"] as? [[String: Any]], !panes.isEmpty else {
            text = "no panes to read"; return
        }
        let rank: ([String: Any]) -> Int = { p in
            let status = p["agent_status"] as? String ?? ""
            return (p["agent"] as? String) == nil ? 3 : status == "working" ? 0 : status == "blocked" || status == "done" ? 1 : 2
        }
        guard let id = panes.sorted(by: { rank($0) < rank($1) }).first?["pane_id"] as? String else { text = "no panes to read"; return }
        pane = id
        guard let out = await run(["pane", "read", id, "--source", "recent", "--lines", String(Self.lines)]) else {
            text = "can't read \(id) — herdr pane read \(id)"; return
        }
        let shown = out.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = shown.isEmpty ? "(an empty screen)" : shown
    }
}

/// Rest the pointer on a row and its pane's screen opens beside the pointer (Nat: "can we close to mouse"): anchored a
/// little below-right of where it stopped, so the popover never lands under the cursor and closes itself. Moving
/// restarts the wait; leaving the row closes it.
struct PeekOnHover: ViewModifier {
    let title: String
    let workspace: String
    let run: ([String]) async -> String?
    @State private var shown = false
    @State private var point = CGPoint.zero
    @State private var wait: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    guard !shown else { return }   // open: stay where it opened
                    point = p
                    wait?.cancel()
                    wait = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { shown = true } }
                case .ended:
                    wait?.cancel(); shown = false
                }
            }
            .popover(isPresented: $shown,
                     attachmentAnchor: .rect(.rect(CGRect(x: point.x + 14, y: point.y + 10, width: 1, height: 1))),
                     arrowEdge: .bottom) { PanePeek(title: title, workspace: workspace, run: run) }
    }
}

extension View {
    /// The pane preview for a space row: local spaces ask this Mac's herdr, remote ones their machine's.
    func peekOnHover(_ title: String, workspace: String, run: @escaping ([String]) async -> String?) -> some View {
        modifier(PeekOnHover(title: title, workspace: workspace, run: run))
    }
}
#endif
