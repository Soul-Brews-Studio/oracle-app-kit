#if os(macOS)
import SwiftUI

/// The page of a stopped session (#116): what its session.json saved — every space, its folder (or that the folder is
/// gone), its panes, and the agent each would resume, marking one already live in another pane. Read before Start.
struct SavedSpacesTable: View {
    @ObservedObject var store: HubStore
    let dir: String?
    @State private var rows: [SavedSpace] = []
    @State private var live: Set<String> = []
    @State private var saved: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("Nothing saved in this session's session.json.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("SAVED · \(rows.count) spaces · \(rows.reduce(0) { $0 + $1.agents.count }) agents · "
                     + HerdrPlaces.stoppedSince(saved))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(r.label).font(.callout.weight(.medium)).lineLimit(1).frame(width: 240, alignment: .leading)
                        Text("\(r.panes) pane\(r.panes == 1 ? "" : "s")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        agents(r).frame(width: 220, alignment: .leading)
                        folder(r.cwd)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .task(id: dir) { await load() }
    }

    @ViewBuilder private func agents(_ r: SavedSpace) -> some View {
        if r.agents.isEmpty {
            Text("shell").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(r.agents, id: \.sessionId) { a in
                    let dup = live.contains(a.sessionId)
                    Text((a.name.isEmpty ? a.agent : "\(a.agent) \(a.name)") + (dup ? " · already live" : ""))
                        .font(.caption).foregroundStyle(dup ? Color.orange : Color.primary).lineLimit(1)
                        .help(dup ? "This conversation runs in another pane now; Start would resume it a second time" : "resumes \(a.sessionId)")
                }
            }
        }
    }

    @ViewBuilder private func folder(_ cwd: String) -> some View {
        let home = NSHomeDirectory()
        let short = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        if cwd.isEmpty || FileManager.default.fileExists(atPath: cwd) {
            Text(short).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        } else {
            Text("\(short) · folder gone").font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(1).truncationMode(.head)
                .help("This space's folder no longer exists (a removed worktree): it would come back pointing at nothing")
        }
    }

    private func load() async {
        guard let dir, let data = FileManager.default.contents(atPath: dir + "/session.json") else { rows = []; return }
        rows = HerdrPlaces.savedSpaces(sessionJSON: data)
        saved = HerdrPlaces.modified(dir + "/session.json")
        live = await HerdrPlaces.liveNow(store.sessions)
    }
}
#endif
