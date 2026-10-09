#if os(macOS)
import SwiftUI

// MARK: - A session name across machines: one card per machine, its spaces inside (Nat, 2026-10-09: "in session we
// have multiple machines (but same name grouped) each machine have multi workspace", the herdr board's card look)

/// One space row in a machine card, local or remote alike.
struct GroupSpace: Identifiable, Hashable {
    let id: String
    let label: String
    let status: String
    let panes: Int
    var agents: Int? = nil
    var branch: String? = nil
    var linked = false

    /// "2 spaces · 1 live" for a card's header: live = a space where an agent is not idle/unknown or which has agents.
    static func facts(_ spaces: [GroupSpace]) -> String {
        let live = spaces.filter { ($0.agents ?? 0) > 0 || !["", "unknown", "idle"].contains($0.status) }.count
        return "\(spaces.count) space\(spaces.count == 1 ? "" : "s") · \(live) live"
    }
}

struct SessionGroupPage: View {
    @ObservedObject var store: HubStore
    let name: String
    @Binding var pick: HubPick
    @State private var shut: Set<String> = []

    private var places: [RemoteParse.Place] {
        RemoteParse.byName(local: store.localSessions, remotes: store.remotes, running: { _ in true })
            .first { $0.name == name }?.places ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(name).font(.custom("Avenir Next", size: 34).weight(.bold))
                    Text(name == "default" ? "herdr's own on every machine — unrelated across them"
                                           : "\(places.count) place\(places.count == 1 ? "" : "s") · \(places.map(spaces).joined().count) spaces")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(places, id: \.self) { card($0) }
                if places.isEmpty { Text("No machine runs a session named \(name) now.").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .task { await store.probeRemotes() }
    }

    private func key(_ p: RemoteParse.Place) -> String {
        switch p { case .local: "local"; case .remote(let r): r.id }
    }

    private func machine(_ p: RemoteParse.Place) -> (title: String, login: String?, icon: String) {
        switch p {
        case .local: (NetworkPage.localHost, "this Mac", "laptopcomputer")
        case .remote(let r): (RemoteParse.machineLabel(r, among: store.remotes), r.shortTarget, "server.rack")
        }
    }

    private func spaces(_ p: RemoteParse.Place) -> [GroupSpace] {
        switch p {
        case .local:
            return store.spaces.filter { $0.session == name }.sorted { store.listNumber($0) < store.listNumber($1) }
                .map { GroupSpace(id: $0.id, label: $0.label, status: $0.status, panes: $0.panes, agents: $0.agents,
                                  branch: $0.branch, linked: $0.linked) }
        case .remote(let r):
            return (store.remoteState[r.id]?.workspaces ?? [])
                .map { GroupSpace(id: r.id + ":" + $0.id, label: $0.label, status: $0.status, panes: $0.panes) }
        }
    }

    private func open(_ p: RemoteParse.Place) {
        switch p { case .local: pick = .session(name); case .remote(let r): pick = .remote(r) }
    }

    @ViewBuilder private func card(_ p: RemoteParse.Place) -> some View {
        let m = machine(p), list = spaces(p), k = key(p), isShut = shut.contains(k)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { if isShut { shut.remove(k) } else { shut.insert(k) } } label: {
                    Image(systemName: isShut ? "chevron.right" : "chevron.down").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(.secondary).handCursor()
                Text(m.title).font(.custom("Avenir Next", size: 24).weight(.bold)).foregroundStyle(HubStyle.accent)
                if let login = m.login {
                    Label(login, systemImage: m.icon).font(.callout).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                Spacer()
                Text(GroupSpace.facts(list)).font(.callout).foregroundStyle(.secondary)
                Button("Open") { open(p) }.buttonStyle(.bordered).handCursor()
                    .help("This machine's page for \(name): the full list with its buttons")
            }
            if !isShut {
                if list.isEmpty {
                    Text(running(p) ? "Empty — no space in \(name) here." : "\(name) is not running here.")
                        .font(.callout).foregroundStyle(.secondary).padding(.leading, 24)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 10) {
                        ForEach(list) { s in spaceRow(s, p) }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(HubStyle.accent.opacity(0.35), lineWidth: 1.2))
    }

    private func running(_ p: RemoteParse.Place) -> Bool {
        switch p { case .local(let s): s.running; case .remote(let r): store.remoteState[r.id]?.running == true }
    }

    private func spaceRow(_ s: GroupSpace, _ p: RemoteParse.Place) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HubGlyph(status: s.status).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text((s.linked ? "└ " : "") + s.label).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text([s.branch, s.agents.map { "\($0) agent\($0 == 1 ? "" : "s")" }, "\(s.panes) pane\(s.panes == 1 ? "" : "s")"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {   // local: show it in herdr; remote: that machine's page
            if case .local = p, let sp = store.spaces.first(where: { $0.id == s.id }) { store.showInHerdr(sp) } else { open(p) }
        }
        .help(s.label)
    }
}
#endif
