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
            NavRow(symbol: "sparkle.magnifyingglass", title: "Search issues & PRs", badge: "⌘K",
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
            Text("Sessions").font(.custom("Avenir Next", size: 13).weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.localSessions.sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }) { s in
                        SessionRow(session: s, spaces: store.spaces.filter { $0.session == s.name },
                                   on: pick == .session(s.name), store: store,
                                   onDelete: { deleteError = nil; deletingHolds = HubStore.contents(of: s); deleting = s }) { pick = .session(s.name) }
                    }
                    RemoteSection(store: store, pick: $pick)
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
    var onDelete: (() -> Void)? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let urgent = spaces.map(\.status).min { HubParse.rank($0) < HubParse.rank($1) }
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(session.running ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                Text(session.name).font(.custom("Avenir Next", size: 14).weight(on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
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

/// Remote herdr sessions (Nat: "can we list the remote? if not machine, like this?" — `herdr --remote <target>
/// --session <s>`): what this Mac is attached to now, saved herdr machines, ones the hub remembers or read back from
/// the traces a remote attach leaves. A click opens it in WezTerm, the way Nat types it.
struct RemoteSection: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @State private var adding = false
    @State private var target = ""
    @State private var session = ""
    @State private var addError: String?
    @AppStorage("hub.remoteFolded") private var foldedList = ""   // machines folded shut, comma-separated
    private var folded: Set<String> { Set(foldedList.split(separator: ",").map(String.init)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { pick = .network } label: {
                    HStack(spacing: 4) {
                        Text("Remote").font(.custom("Avenir Next", size: 13).weight(.medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(pick == .network ? HubStyle.accent : Color.secondary)
                }
                .buttonStyle(.plain).handCursor().help("The Network page: every machine, full size")
                Spacer()
                Button { addError = nil; adding = true } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help("Save a machine in herdr: herdr machine add <target> --label <name> --remote-session <session>")
                    .popover(isPresented: $adding, arrowEdge: .trailing) { form }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            if store.remotes.isEmpty {
                Text("No saved herdr machines yet: +, or herdr machine add").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 14)
            }
            // one group per login, named as the Network page's cards name it ("nm@white", Nat: "why the left not
            // nm@white"): how many of its sessions run, then every session — the ones attached or remembered
            ForEach(RemoteParse.groups(store.remotes, running: { store.remoteState[$0.id]?.running == true }), id: \.key) { g in
                machineHeader(g.key, g.host, g.sessions)
                if !folded.contains(g.key) {
                    ForEach(g.sessions) { r in
                        RemoteRow(remote: r, state: store.remoteState[r.id], attached: store.attachedRemotes.contains(r.id), store: store,
                                  subtitle: r.label ?? r.user ?? "", onOpen: { pick = .remote(r) })
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder private func machineHeader(_ key: String, _ host: String, _ sessions: [RemoteSession]) -> some View {
        let running = sessions.filter { store.remoteState[$0.id]?.running == true }.count
        let problems = Set(sessions.map(\.target)).compactMap { store.remoteMachines[$0]?.problem }
        let herdr = Set(sessions.map(\.target)).compactMap { t in store.remoteMachines[t]?.version.map { (RemoteSession(target: t, session: "x").user ?? t) + " " + $0 } }.sorted()
        Button {
            var f = folded; if f.contains(key) { f.remove(key) } else { f.insert(key) }
            foldedList = f.sorted().joined(separator: ",")
        } label: {
            HStack(spacing: 7) {
                Image(systemName: folded.contains(key) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(problems.isEmpty ? Color.secondary : Color.orange)
                Text(key).font(.custom("Avenir Next", size: 14).weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(running)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .help(([key + " on " + host + " — \(running) of \(sessions.count) sessions running"] + herdr.map { "herdr " + $0 } + problems).joined(separator: "\n"))
        .contextMenu {
            ForEach(sessions) { r in
                Button("Remove saved machine \(r.label ?? r.session) (herdr machine remove)") { Task { _ = await store.removeMachine(r) } }
            }
        }
    }

    private var form: some View {
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
        .padding(16)
    }
}

struct RemoteRow: View {
    let remote: RemoteSession
    let state: RemoteState?
    let attached: Bool
    @ObservedObject var store: HubStore
    var subtitle: String? = nil
    /// a click opens the session's page in the hub (Nat: "same as local?"); without it, WezTerm as before
    var onOpen: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        Button { if let onOpen { onOpen() } else { store.openRemote(remote) } } label: {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(remote.session).font(.custom("Avenir Next", size: 14)).lineLimit(1)
                    let sub = subtitle ?? remote.label ?? remote.shortTarget
                    if !sub.isEmpty { Text(sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 4)
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
