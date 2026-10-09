#if os(macOS)
import SwiftUI
import AppKit

struct HubSidebar: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @Binding var menuBar: Bool
    @State private var deleting: HubSession?              // right-click → Delete session…, waiting for the answer
    @State private var deletingHolds: HubStore.SessionContents?
    @State private var deleteError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(HubStyle.accent.gradient).frame(width: 30, height: 30)
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                Text("ARRA Oracles").font(.custom("Avenir Next", size: 20).weight(.semibold)).tracking(-0.4).lineLimit(1)
                Spacer(minLength: 4)
                SidebarIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refresh(remotes: true) } }
            }
            .padding(.horizontal, 18).frame(height: 70)
            NavRow(symbol: "square.grid.2x2", title: "All oracles", badge: "\(store.oracles.count)",
                   on: pick == .all, accent: HubStyle.accent) { pick = .all }
                .padding(.horizontal, 12)
            NavRow(symbol: "sparkle.magnifyingglass", title: "Search issues & PRs", badge: "⌘F",
                   on: pick == .search, accent: HubStyle.accent) { pick = .search }
                .padding(.horizontal, 12)
            NavRow(symbol: "list.bullet.rectangle", title: "Trace", badge: nil, on: pick == .trace, accent: HubStyle.accent, sub: true) { pick = .trace }
                .padding(.horizontal, 12)
                .help("Every query asked of the hub's index — search and MCP — and a cloud of what is searched")
            NavRow(symbol: "circle.hexagongrid", title: "Map", badge: nil, on: pick == .map, accent: HubStyle.accent, sub: true) { pick = .map }
                .padding(.horizontal, 12)
                .help("Every oracle's memory in one space — a query to any oracle lights it up")
            NavRow(symbol: "display", title: "Screens", badge: nil, on: pick == .screens, accent: HubStyle.accent, sub: true) { pick = .screens }
                .padding(.horizontal, 12)
                .help("Your displays as macOS arranges them: where the hub is, and each herdr session's window")
            NavRow(symbol: "network", title: "Network", badge: store.remotes.isEmpty ? nil : "\(Set(store.remotes.map(\.host)).count + 1)",
                   on: pick == .network, accent: HubStyle.accent, sub: true) { pick = .network }
                .padding(.horizontal, 12)
                .help("Every machine with herdr: this Mac and each remote one, with every session on it")
            NavRow(symbol: "gearshape", title: "Settings", badge: nil, on: pick == .settings, accent: HubStyle.accent) { pick = .settings }
                .padding(.horizontal, 12)
            SessionsHeader(store: store, pick: $pick)
            ScrollView {
                // session first: one row per name, its machines under it when it runs on more than one
                // (Nat: "session name / machine A B C", "laris-co both m5 and white and black")
                SessionList(store: store, pick: $pick) { s, title, tag in
                    SessionRow(session: s, spaces: store.spaces.filter { $0.session == s.name },
                               on: pick == .session(s.name), store: store, title: title, tag: tag,
                               onDelete: { deleteError = nil; deletingHolds = HubStore.contents(of: s); deleting = s }) { pick = .session(s.name) }
                }
                .padding(.horizontal, 12)
            }
            if let e = deleteError {
                Text(e).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.vertical, 6)
            }
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Delete the herdr session \(deleting?.name ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete \(deleting?.name ?? "")", role: .destructive) {
                guard let s = deleting else { return }
                Task {
                    deleteError = await store.deleteSession(s)
                    if deleteError == nil, pick == .session(s.name) { pick = .all }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteMessage(deletingHolds))
        }
    }

    /// What the confirmation says the session holds, and where its copy goes.
    static func deleteMessage(_ c: HubStore.SessionContents?) -> String {
        guard let c else { return "" }
        let spaces = c.spaces.isEmpty ? "No saved spaces" : "\(c.spaces.count) saved space\(c.spaces.count == 1 ? "" : "s"): " + c.spaces.prefix(6).joined(separator: ", ") + (c.spaces.count > 6 ? "…" : "")
        let size = ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
        return "\(spaces). \(c.files) file\(c.files == 1 ? "" : "s"), \(size). herdr session delete removes its folder; a copy is kept first in ~/Library/Application Support/ARRA Oracles/deleted-sessions."
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(store.problems.isEmpty ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(store.problems.isEmpty ? "Live on this Mac" : "Needs a look").font(.custom("Avenir Next", size: 13).weight(.semibold))
            }
            if let t = store.lastRefresh {
                Text("herdr · maw — updated \(t.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(AppVersion.calver).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .help("This build — CalVer, Bangkok time at build")
            ForEach(store.problems, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            Toggle("Show in menu bar", isOn: $menuBar).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

struct SessionRow: View {
    let session: HubSession
    let spaces: [HubSpace]
    let on: Bool
    var store: HubStore? = nil
    /// the row's text when it is not the session's name: the machine, under a name that runs on several
    var title: String? = nil
    /// the machine, small before the count, on a name that runs only here
    var tag: String? = nil
    var onDelete: (() -> Void)? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let urgent = spaces.map(\.status).min { HubParse.rank($0) < HubParse.rank($1) }
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(session.running ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                Text(title ?? session.name).font(.custom("Avenir Next", size: 14).weight(on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let tag { Text(tag).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                if let u = urgent, HubParse.rank(u) <= 2 { HubGlyph(status: u) }
                Text(session.running ? "\(spaces.count)" : "off").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            .foregroundStyle(on ? HubStyle.accent : (session.running ? Color.primary.opacity(0.85) : Color.secondary))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? HubStyle.accent.opacity(0.16) : (hover ? Color.primary.opacity(0.06) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .contextMenu {
            if let store { Button("Open in WezTerm") { store.openSession(session.name) } }
            if session.isDefault {
                Button("The default session cannot be deleted here") {}.disabled(true)
            } else if session.running {
                Button("Delete session… (stop it first)") {}.disabled(true)
            } else if let onDelete {
                Button("Delete session…", role: .destructive, action: onDelete)
            }
        }
    }
}

/// "Sessions ↗  +": the ↗ opens the Network page; + starts a new session on this Mac or saves a machine in herdr.
struct SessionsHeader: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @State private var adding = false
    @State private var target = ""
    @State private var session = ""
    @State private var addError: String?
    @AppStorage("hub.sessionsBy") private var by = "session"
    @State private var remote = false     // + : false = a new session on this Mac (Nat: "i can not new session from the app?")
    @State private var newName = ""
    @State private var starting = false
    var body: some View {
        HStack {
            Button { pick = .network } label: {
                HStack(spacing: 4) {
                    Text("Sessions").font(.custom("Avenir Next", size: 13).weight(.medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(pick == .network ? HubStyle.accent : Color.secondary)
            }
            .buttonStyle(.plain).handCursor().help("The Network page: every machine, full size")
            Spacer()
            Picker("", selection: $by) {   // 2 views: by session name, or by machine (Nat, 2026-10-09)
                Image(systemName: "rectangle.stack").tag("session").help("By session name")
                Image(systemName: "desktopcomputer").tag("machine").help("By machine")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 64).controlSize(.mini)
            .help("Sessions by name, or by machine (⌃⇥ switches)")
            .background {   // ⌃⇥ flips the two views (Nat: "ctrl tab to switch")
                Button("") { by = by == "machine" ? "session" : "machine" }
                    .keyboardShortcut(.tab, modifiers: .control).opacity(0).allowsHitTesting(false)
            }
            Button { addError = nil; adding = true } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help("New session on this Mac (herdr --session <name> server), or save a machine in herdr")
                .popover(isPresented: $adding, arrowEdge: .trailing) { form }
        }
        .padding(.leading, 26).padding(.trailing, 26).padding(.top, 18).padding(.bottom, 4)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $remote) { Text("This Mac").tag(false); Text("Another machine").tag(true) }
                .pickerStyle(.segmented).frame(width: 300).labelsHidden()
            if remote { machineForm } else { localForm }
        }
        .padding(16)
    }

    /// A new herdr session here: started in the background (no window), then its page opens.
    private var localForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New session on this Mac").font(.headline)
            Text("Starts herdr --session <name> server in the background. Open its page to add spaces, or move an oracle in with herdr-move <oracle> --to <name>.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            TextField("name — e.g. maeon-craft", text: $newName).textFieldStyle(.roundedBorder).frame(width: 300)
                .onSubmit(startNew)
            if let e = addError ?? HubStore.newSessionProblem(newName, existing: store.sessions.map(\.name)) , !newName.isEmpty {
                Text(e).font(.caption).foregroundStyle(.orange).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { adding = false }
                Button(starting ? "Starting…" : "Start session", action: startNew).buttonStyle(.borderedProminent)
                    .disabled(starting || newName.isEmpty || HubStore.newSessionProblem(newName, existing: store.sessions.map(\.name)) != nil)
            }
        }
    }

    private func startNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard HubStore.newSessionProblem(name, existing: store.sessions.map(\.name)) == nil else { return }
        starting = true; addError = nil
        Task {
            addError = await store.startSession(name)
            starting = false
            if addError == nil { adding = false; newName = ""; pick = .session(name) }
        }
    }

    private var machineForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save a machine in herdr").font(.headline)
            Text("Opens WezTerm with herdr machine add: it may ask before it installs or starts herdr there. One saved machine is one remote session.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            TextField("target — user@host", text: $target).textFieldStyle(.roundedBorder).frame(width: 300)
            TextField("session — default", text: $session).textFieldStyle(.roundedBorder).frame(width: 300)
            if let e = addError { Text(e).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { adding = false }
                Button("Save in herdr…") {
                    addError = store.saveMachine(target: target, session: session.isEmpty ? "default" : session, label: "")
                    if addError == nil { adding = false; target = ""; session = "" }
                }.buttonStyle(.borderedProminent).disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Every herdr session by name, wherever it runs (Nat: "laris-co both m5 and white and black it should show? how?").
/// A name on one machine is one row, the machine small at its right. A name on several is a heading — "laris-co
/// 3 places" — with a row per machine under it: this Mac first, then hosts. `default` is herdr's own on every
/// machine, unrelated across them, so its heading says "per machine". The Network page keeps the machine-first view.
struct SessionList<LocalRow: View>: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @ViewBuilder let localRow: (HubSession, _ title: String?, _ tag: String?) -> LocalRow
    @AppStorage("hub.sessionsFolded") private var foldedList = ""   // names folded shut, comma-separated
    @AppStorage("hub.sessionsBy") private var by = "session"         // "session" (by name) or "machine" — SessionsHeader's toggle
    private var folded: Set<String> { Set(foldedList.split(separator: ",").map(String.init)) }
    var body: some View {
        if by == "machine" { machineView } else { sessionView }
    }

    /// Each machine, its sessions under it; the machine's name opens the Network page, the chevron folds it.
    private var machineView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RemoteParse.byMachine(local: store.localSessions, remotes: store.remotes, localName: NetworkPage.localHost),
                    id: \.machine) { g in
                let key = "machine:" + g.machine
                Button { pick = .network } label: {
                    HStack(spacing: 7) {
                        Image(systemName: folded.contains(key) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                var f = folded; if f.contains(key) { f.remove(key) } else { f.insert(key) }
                                foldedList = f.sorted().joined(separator: ",")
                            }
                        Text(g.machine).font(.custom("Avenir Next", size: 14).weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(g.places.filter(running).count) of \(g.places.count) running").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor().help("\(g.machine): every herdr session on it — click for the Network page")
                if !folded.contains(key) {
                    ForEach(g.places, id: \.self) { p in row(p, title: p.name, tag: nil).padding(.leading, 14) }
                }
            }
        }
    }

    private var sessionView: some View {
        let groups = RemoteParse.byName(local: store.localSessions, remotes: store.remotes, running: running)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.name) { g in
                if g.places.count == 1, let p = g.places.first {
                    row(p, title: nil, tag: machine(p))
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        header(g.name, places: g.places)
                        if !folded.contains(g.name) {
                            ForEach(g.places, id: \.self) { p in row(p, title: machine(p), tag: nil).padding(.leading, 14) }
                        }
                    }
                    // its page is open: the whole group is highlighted, heading and rows (Nat: "should around this whole")
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(pick == .group(g.name) ? HubStyle.accent.opacity(0.14) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(pick == .group(g.name) ? HubStyle.accent.opacity(0.45) : .clear, lineWidth: 1))
                    .padding(.horizontal, 6)
                }
            }
            if store.remotes.isEmpty {
                Text("No saved herdr machines yet: +, or herdr machine add").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.top, 8)
            }
        }
    }

    private func running(_ p: RemoteParse.Place) -> Bool {
        switch p { case .local(let s): return s.running; case .remote(let r): return store.remoteState[r.id]?.running == true }
    }

    private func machine(_ p: RemoteParse.Place) -> String {
        switch p { case .local: return NetworkPage.localHost; case .remote(let r): return RemoteParse.machineLabel(r, among: store.remotes) }
    }

    @ViewBuilder private func row(_ p: RemoteParse.Place, title: String?, tag: String?) -> some View {
        switch p {
        case .local(let s): localRow(s, title, tag)
        case .remote(let r):
            RemoteRow(remote: r, state: store.remoteState[r.id], attached: store.attachedRemotes.contains(r.id), store: store,
                      subtitle: "", title: title, tag: tag, onOpen: { pick = .remote(r) })
        }
    }

    private func header(_ name: String, places: [RemoteParse.Place]) -> some View {
        let on = places.filter(running).count
        let machines = places.map(machine)
        return Button { pick = .group(name) } label: {   // the name: its machines as cards; the chevron folds the rows
            HStack(spacing: 7) {
                Image(systemName: folded.contains(name) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        var f = folded; if f.contains(name) { f.remove(name) } else { f.insert(name) }
                        foldedList = f.sorted().joined(separator: ",")
                    }
                Text(name).font(.custom("Avenir Next", size: 14).weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(name == "default" ? "per machine" : "\(places.count) places").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(on > 0 ? Color.primary.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .help(name == "default"
              ? "herdr's default session on each machine — separate sessions that share the name"
              : "\(name) runs on \(machines.joined(separator: ", ")) — \(on) of \(places.count) running. Each is its own herdr session; same name only.")
    }
}

struct RemoteRow: View {
    let remote: RemoteSession
    let state: RemoteState?
    let attached: Bool
    @ObservedObject var store: HubStore
    var subtitle: String? = nil
    var title: String? = nil
    var tag: String? = nil
    /// a click opens the session's page in the hub (Nat: "same as local?"); without it, WezTerm as before
    var onOpen: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        Button { if let onOpen { onOpen() } else { store.openRemote(remote) } } label: {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? remote.session).font(.custom("Avenir Next", size: 14)).lineLimit(1)
                    let sub = subtitle ?? remote.label ?? remote.shortTarget
                    if !sub.isEmpty { Text(sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if let tag { Text(tag).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                if attached { Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary).help("This Mac is attached to it now") }
                if let s = state, s.needsYou > 0 { HubGlyph(status: "done") }
                Text(count).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            .foregroundStyle(state?.running == true ? Color.primary.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.primary.opacity(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .help(help)
        .contextMenu {
            Button("Open in WezTerm") { store.openRemote(remote) }
            Button("Copy \(remote.command)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(remote.command, forType: .string) }
            Divider()
            Button("Remove saved machine (herdr machine remove)") { Task { _ = await store.removeMachine(remote) } }
        }
    }

    private var dot: Color {
        guard let s = state else { return Color.secondary.opacity(0.35) }
        if s.problem != nil { return .orange }
        return s.running ? (s.working > 0 ? .green : Color.green.opacity(0.6)) : Color.secondary.opacity(0.35)
    }

    private var count: String {
        guard let s = state else { return "…" }
        if s.problem != nil { return "?" }
        return s.running ? "\(s.agents)" : "off"
    }

    private var help: String {
        var lines = [remote.command]
        if let s = state {
            if let p = s.problem { lines.append(p) }
            else if s.running { lines.append("\(s.agents) agent\(s.agents == 1 ? "" : "s") · \(s.working) working · \(s.needsYou) need you · herdr \(s.version ?? "?")") }
            else { lines.append("not running there — Open starts it (herdr --remote starts the remote server)") }
            lines.append("checked \(s.checked.formatted(date: .omitted, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }
}

/// herdr's marks: ◐ working · ✓ needs you (done) · ! blocked · ○ idle · \u{00B7} no agent (drawn small).
struct HubGlyph: View {
    let status: String
    var body: some View {
        let look: (String, Color) = {
            switch status {
            case "working": return ("circle.lefthalf.filled", HubStyle.accent)
            case "done": return ("checkmark.circle.fill", .green)
            case "blocked": return ("exclamationmark.circle.fill", .orange)
            case "idle": return ("circle", .secondary)
            case "resumable": return ("arrow.uturn.backward", .secondary)
            default: return ("circle.fill", Color.secondary.opacity(0.6))   // herdr's "·": no agent in it
            }
        }()
        Image(systemName: look.0).font(.system(size: 10, weight: .bold)).foregroundStyle(look.1)
            .scaleEffect(look.0 == "circle.fill" ? 0.4 : 1)   // a dot, as small as herdr's "·"
    }
}
#endif
