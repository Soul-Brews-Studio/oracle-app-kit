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

    /// The filter: a space shows when its name or branch holds the text (any case); empty shows all.
    static func matching(_ all: [GroupSpace], _ text: String) -> [GroupSpace] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.label.lowercased().contains(q) || ($0.branch ?? "").lowercased().contains(q) }
    }

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
    @State private var filter = ""
    @State private var cursor: String?            // the space j/k is on, across every card
    @State private var keys: Any?
    @FocusState private var filterFocused: Bool

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
                HStack(spacing: 8) {   // the same keys as one session's page (Nat: "all whole sub keys")
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter spaces — type, or press /   (⌘F)", text: $filter).textFieldStyle(.plain).focused($filterFocused)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                Text("j k move · o open · ⌘⏎ WezTerm · s show in herdr · / filter · esc clear").font(.caption).foregroundStyle(.tertiary)
                ForEach(places, id: \.self) { card($0) }
                if places.isEmpty { Text("No machine runs a session named \(name) now.").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .task { await store.probeRemotes() }
        .onAppear(perform: installKeys)
        .onDisappear { if let k = keys { NSEvent.removeMonitor(k); keys = nil } }
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
        let m = machine(p), list = visible(p), k = key(p), isShut = shut.contains(k)
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

    /// local: show it in herdr; remote: that machine's page
    private func activate(_ s: GroupSpace, _ p: RemoteParse.Place) {
        if case .local = p, let sp = store.spaces.first(where: { $0.id == s.id }) { store.showInHerdr(sp) } else { open(p) }
    }

    private func visible(_ p: RemoteParse.Place) -> [GroupSpace] { GroupSpace.matching(spaces(p), filter) }

    /// every space the keys can reach, card by card (folded cards skipped)
    private var reachable: [(GroupSpace, RemoteParse.Place)] {
        places.filter { !shut.contains(key($0)) }.flatMap { p in visible(p).map { ($0, p) } }
    }

    private func move(_ step: Int) {
        let r = reachable; guard !r.isEmpty else { return }
        let i = r.firstIndex { $0.0.id == cursor }.map { min(max($0 + step, 0), r.count - 1) } ?? (step > 0 ? 0 : r.count - 1)
        cursor = r[i].0.id
    }

    private func installKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if LiveTerminal.typing { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, e.charactersIgnoringModifiers == "f" { filterFocused = true; return nil }
            if e.keyCode == 36, mods == .command {   // ⌘⏎: open the cursor's space, else the first match — from the filter too
                if let h = reachable.first(where: { $0.0.id == cursor }) ?? reachable.first { filterFocused = false; cursor = h.0.id; activate(h.0, h.1) }
                return nil
            }
            if NSApp.keyWindow?.firstResponder is NSTextView {   // in the filter: ↓ or ⏎ leaves it for the spaces
                if filterFocused, e.keyCode == 125 || e.keyCode == 36 { filterFocused = false; if cursor == nil { move(1) }; return nil }
                if e.keyCode == 53, filterFocused { filter = ""; filterFocused = false; return nil }
                return e
            }
            let here = { reachable.first { $0.0.id == cursor } }
            switch e.keyCode {
            case 125: move(1); return nil                                         // ↓
            case 126: move(-1); return nil                                        // ↑
            case 36: if let h = here() { activate(h.0, h.1) }; return nil         // ⏎
            case 53: if !filter.isEmpty { filter = ""; return nil }; if cursor != nil { cursor = nil; return nil }; return e
            default: break
            }
            guard mods.subtracting([.shift, .capsLock]).isEmpty, let c = e.charactersIgnoringModifiers else { return e }
            switch c {
            case "/": filterFocused = true
            case "j": move(1)
            case "k": move(-1)
            case "o": if let h = here() { activate(h.0, h.1) }
            case "s": if let h = here() { if case .local = h.1, let sp = store.spaces.first(where: { $0.id == h.0.id }) { store.showInHerdr(sp) } else { open(h.1) } }
            default: return e
            }
            return nil
        }
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
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(cursor == s.id ? HubStyle.accent.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { cursor = s.id; activate(s, p) }
        .help(s.label)
    }
}
#endif
