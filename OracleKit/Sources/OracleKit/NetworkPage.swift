#if os(macOS)
import SwiftUI
import AppKit

/// Every machine with herdr, on one page, the way All oracles shows the oracles (Nat, 2026-10-08: "can we have like
/// landing network, full page on the right? love like this"): this Mac first, then each remote machine, a card each
/// with every session on it. A click on a session opens it: here, its page; on another machine, in WezTerm as
/// `herdr --remote <target> --session <s>`.
struct NetworkPage: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @State private var target = ""
    @State private var session = ""
    @State private var label = ""
    @State private var addError: String?
    @State private var showSave = false   // folded until asked for (Nat tried open-by-default, then "back to collapse")

    var body: some View {
        // one card per machine; inside it, a section per login (Nat: "machine name and user", nat@white + nm@white)
        let machines = Dictionary(grouping: store.remotes, by: \.host).sorted { $0.key < $1.key }
        let remoteRunning = store.remotes.filter { store.remoteState[$0.id]?.running == true }
        let localRunning = store.localSessions.filter(\.running)
        let agents = remoteRunning.reduce(0) { $0 + (store.remoteState[$1.id]?.agents ?? 0) }
        let need = remoteRunning.reduce(0) { $0 + (store.remoteState[$1.id]?.needsYou ?? 0) }
            + store.spaces.filter { $0.status == "done" || $0.status == "blocked" }.count
        let logins = Set(store.remotes.map(\.target)).count
        let checked = store.remoteMachines.values.map(\.checked).max()
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(need > 0 ? "\(need) need you" : "\(localRunning.count + remoteRunning.count) sessions running")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(HubStyle.accent)
                    Text("\(machines.count + 1) machines · \(logins) login\(logins == 1 ? "" : "s") · "
                         + "\(localRunning.count + remoteRunning.count) sessions running · \(agents) agent\(agents == 1 ? "" : "s")"
                         + (checked.map { " · probed \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                         + " · click a session to open it")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    // every machine the same: its name, then a box per login on it (Nat: "group white and show box
                    // nm@white and nat@white and god@white", then "prep for m5 and black … it will same?")
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            groupHeader(icon: "laptopcomputer", name: Self.localHost, facts: "this Mac")
                            MachineGrid(minWidth: 330, spacing: 14) {
                                LocalMachineCard(store: store, pick: $pick, title: NSUserName() + "@" + Self.localHost)
                            }
                        }
                        ForEach(machines, id: \.key) { m in machineGroup(m.key, m.value) }
                    }
                }
                saveSection
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Network")
        .task { await store.probeRemotes() }   // fresh when the page opens
    }

    static let localHost = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "this Mac"

    /// A machine's name line above its login boxes. Totals only when several boxes share it; one box says them itself.
    private func groupHeader(icon: String, name: String, facts: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(HubStyle.accent)
            Text(name).font(.custom("Avenir Next", size: 17).weight(.semibold))
            Text(facts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    /// A remote machine: its name, then a box per login (user@host), each with its sessions.
    @ViewBuilder private func machineGroup(_ host: String, _ sessions: [RemoteSession]) -> some View {
        let logins = RemoteParse.groups(sessions, running: { store.remoteState[$0.id]?.running == true })
        let running = sessions.filter { store.remoteState[$0.id]?.running == true }
        let agents = running.reduce(0) { $0 + (store.remoteState[$1.id]?.agents ?? 0) }
        VStack(alignment: .leading, spacing: 8) {
            groupHeader(icon: "server.rack", name: host,
                        facts: logins.count == 1 ? "1 login"
                            : "\(logins.count) logins · \(running.count) of \(sessions.count) running · \(agents) agent\(agents == 1 ? "" : "s")")
            MachineGrid(minWidth: 330, spacing: 14) {
                ForEach(logins, id: \.key) { l in
                    MachineCard(store: store, host: host, sessions: l.sessions, title: l.key,
                                subtitle: Array(Set(l.sessions.compactMap(\.label).filter { $0 != host })).sorted().joined(separator: ", "),
                                onOpen: { pick = .remote($0) })
                }
            }
        }
    }

    /// One line until asked for: "Save a machine", and how many open `herdr --remote` windows here are not saved yet.
    /// Open, it lists those windows (each fills the form) and the form. Saving is herdr's own `herdr machine add`, in a
    /// WezTerm window: it may ask before it installs or starts herdr on the other machine, which the hub never answers.
    private var saveSection: some View {
        let unsaved = store.unsavedAttached
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.2)) { showSave.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSave ? "chevron.down" : "chevron.right").font(.caption2.bold())
                    Text("Save a machine").font(.callout.weight(.medium))
                    if !unsaved.isEmpty {
                        Text("· \(unsaved.count) open window\(unsaved.count == 1 ? "" : "s") here \(unsaved.count == 1 ? "isn’t" : "aren’t") saved")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
            if showSave {
                ForEach(unsaved) { r in
                    HStack(spacing: 10) {
                        Text(r.session).font(.callout.weight(.medium))
                        Text(r.shortTarget).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Fill the form") { target = r.target; session = r.session; label = r.host }
                            .buttonStyle(.link).handCursor()
                    }
                    .padding(.leading, 18)
                }
                addForm.padding(.leading, 18)
                Text("Saved machines are herdr's own (herdr machine list), one per remote session, asked every 45 s or on refresh.")
                    .font(.caption).foregroundStyle(.tertiary).padding(.leading, 18).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("target — user@host", text: $target).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                TextField("session — default", text: $session).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                TextField("label — the host", text: $label).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                Button("Save in herdr…") {
                    addError = store.saveMachine(target: target, session: session.isEmpty ? "default" : session, label: label)
                    if addError == nil { target = ""; session = ""; label = "" }
                }
                .buttonStyle(.borderedProminent).disabled(target.trimmingCharacters(in: .whitespaces).isEmpty).handCursor()
            }
            if let e = addError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }
}

/// The machine cards in columns at least `minWidth` wide, wrapping like the adaptive grid it replaces, with every card
/// in a row as tall as the row's tallest. Cards start level (Nat: "we should top") and now end level too (#93, Nat:
/// "what if one column same height?"); a card fills the height it is offered and keeps its sessions at the top.
struct MachineGrid: Layout {
    var minWidth: CGFloat = 330
    var spacing: CGFloat = 14

    /// How many columns at least `minWidth` wide fit `width`; one when none does.
    static func columns(_ width: CGFloat, minWidth: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minWidth + spacing)))
    }
    /// Each row's height: the tallest of its cards.
    static func rows(_ heights: [CGFloat], columns: Int) -> [CGFloat] {
        stride(from: 0, to: heights.count, by: columns).map { heights[$0..<min($0 + columns, heights.count)].max() ?? 0 }
    }

    /// Columns that fit `width`, each column's width, and each row's height at that width.
    private func shape(_ subviews: Subviews, width: CGFloat) -> (columns: Int, column: CGFloat, rows: [CGFloat]) {
        let columns = Self.columns(width, minWidth: minWidth, spacing: spacing)
        let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
        return (columns, column, Self.rows(heights, columns: columns))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // no finite width offered (an ideal-size pass): every card side by side at its narrowest
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? max(0, (minWidth + spacing) * CGFloat(subviews.count) - spacing)
        let rows = shape(subviews, width: width).rows
        return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = shape(subviews, width: bounds.width)
        var y = bounds.minY
        for (r, height) in s.rows.enumerated() {
            for c in 0..<s.columns where r * s.columns + c < subviews.count {
                subviews[r * s.columns + c].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (s.column + spacing), y: y),
                                                  proposal: ProposedViewSize(width: s.column, height: height))
            }
            y += height + spacing
        }
    }
}

/// One card per machine: its name, who logs in, its herdr, and a row per session.
private struct MachineShell<Rows: View>: View {
    let icon: String
    let title: String
    let users: String
    let line: String
    let problem: String?
    @ViewBuilder let rows: () -> Rows
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubStyle.accent.opacity(0.18)).frame(width: 36, height: 36)
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(problem == nil ? HubStyle.accent : Color.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.custom("Avenir Next", size: 17).weight(.semibold)).lineLimit(1)
                        Text(users).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            if let problem { Text(problem).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 2) { rows() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // as tall as MachineGrid's row
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A session row inside a machine card.
private struct SessionLine: View {
    let name: String
    let detail: String
    let count: String
    let running: Bool
    let needsYou: Bool
    let attached: Bool
    var controls: AnyView? = nil   // Stop / Restart / Start (SessionControls), beside the row, not inside its button
    var params: [LaunchParam] = []  // what its agents were started with: discord, skip perms … (their command line)
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle().fill(running ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                Text(name).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                ForEach(params, id: \.self) { ParamChip(param: $0) }
                Spacer(minLength: 4)
                if attached { Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary).help("This Mac is attached to it now") }
                if needsYou { HubGlyph(status: "done") }
                Text(count).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .foregroundStyle(running ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        // Stop / Restart float over the row's end on hover — they take no width, so the chips keep theirs; a stopped
        // row keeps Start in view, where "off" was
        .overlay(alignment: .trailing) {
            if let controls, hover || !running {
                controls.padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                    .padding(.trailing, 4)
            }
        }
        .onHover { hover = $0 }
    }
}

/// One parameter of an agent's command as a small chip: a channel ("discord", accent), its model, a permission bypass
/// ("skip perms", orange), the conversation it picked.
struct ParamChip: View {
    let param: LaunchParam
    var body: some View {
        let tint: Color = switch param.kind {
        case .channel: HubStyle.accent
        case .danger: .orange
        case .model, .conversation: .secondary
        }
        HStack(spacing: 3) {
            if param.kind == .channel { Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 8)) }
            Text(param.text).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .fixedSize()   // a chip keeps its width: "discord", never a column of letters
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.15)))
        .help(param.kind == .channel ? "Its Claude Code listens on the \(param.text) channel (--channels)" : "From the command it was started with")
    }
}

/// This Mac: its own herdr sessions; a click opens a session's page.
private struct LocalMachineCard: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    /// its box in the m5 group: "beta@m5"
    var title: String? = nil
    @State private var showStopped = false  // folded by default (Nat: "back to … collapse that cool")
    var body: some View {
        let local = store.localSessions.sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
        let running = local.filter(\.running)
        let stopped = local.filter { !$0.running }
        MachineShell(icon: title == nil ? "laptopcomputer" : "person.crop.square", title: title ?? NetworkPage.localHost, users: title == nil ? "this Mac" : "",
                     line: "\(running.count) of \(local.count) sessions running · \(store.spaces.count) spaces", problem: nil) {
            ForEach(running) { s in
                let spaces = store.spaces.filter { $0.session == s.name }
                SessionLine(name: s.name, detail: "", count: "\(spaces.count) spaces", running: true,
                            needsYou: spaces.contains { $0.status == "done" || $0.status == "blocked" }, attached: false) {
                    pick = .session(s.name)
                }
            }
            if !stopped.isEmpty {
                Button { withAnimation(.snappy) { showStopped.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text("\(stopped.count) stopped").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: showStopped ? "chevron.down" : "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.top, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
                if showStopped {
                    ForEach(stopped) { s in
                        SessionLine(name: s.name, detail: "", count: "off", running: false, needsYou: false, attached: false) { pick = .session(s.name) }
                    }
                }
            }
        }
    }
}

/// A remote machine (all its ssh logins); a click opens a session in WezTerm, the way Nat types it. Its sessions stop
/// from here too, one or all, after the same resume check as a local Stop (#100).
private struct MachineCard: View {
    @ObservedObject var store: HubStore
    let host: String
    let sessions: [RemoteSession]
    /// a login's box inside its machine's group: "nm@white", and herdr's name for it ("xiaoer")
    var title: String? = nil
    var subtitle: String? = nil
    /// a click on a session: its page in the hub (Nat: "same as local?"); WezTerm stays in the right-click menu
    var onOpen: ((RemoteSession) -> Void)? = nil
    @State private var pendingStop: [RemoteSession] = []
    @State private var restartAfter = false                       // the confirmed stop is a Restart: start them again
    @State private var confirmStop = false
    @State private var checked = false                       // the resume check came back (resume nil then = ssh failed)
    @State private var resume: [String: ResumeCheck]?
    @State private var stopping = false
    @State private var stopError: String?
    @State private var pendingRemove: RemoteSession?            // the saved machine "Remove" asks about
    var body: some View {
        let targets = Array(Set(sessions.map(\.target))).sorted()
        let users = Array(Set(sessions.compactMap(\.user))).sorted()
        let running = sessions.filter { store.remoteState[$0.id]?.running == true }
        let agents = running.reduce(0) { $0 + (store.remoteState[$1.id]?.agents ?? 0) }
        let problem = targets.compactMap { store.remoteMachines[$0]?.problem }.first
        // versions and the probe time live in the help, not the card (distill): the summary line already says "probed"
        let versions = sessions.map { r in "\(r.shortTarget): herdr \(store.remoteState[r.id]?.version ?? "?")" }
        MachineShell(icon: title == nil ? "server.rack" : "person.crop.square", title: title ?? host,
                     users: subtitle ?? users.joined(separator: " · "),
                     line: "\(running.count) of \(sessions.count) running · \(agents) agent\(agents == 1 ? "" : "s")"
                        + (stopping ? " · stopping…" : ""),
                     problem: stopError ?? problem) {
            ForEach(RemoteParse.groups(sessions, running: { store.remoteState[$0.id]?.running == true }), id: \.key) { login in
            ForEach(login.sessions) { r in
                let st = store.remoteState[r.id]
                // whose login, herdr's name for it when it is not the host's, and how it is read
                // the card names the login; a row adds herdr's name only when this card holds several, and "ssh"
                let labels = Set(sessions.compactMap(\.label))
                let detail = [labels.count > 1 && r.label != host ? r.label : nil, st?.viaSSH == true ? "ssh" : nil].compactMap { $0 }
                sessionRow(r, st: st, detail: detail.joined(separator: " · "))
                    .help(r.command)
                    .contextMenu {
                        Button("Open in WezTerm") { store.openRemote(r) }
                        Button("Copy \(r.command)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.command, forType: .string) }
                        if store.attachedRemotes.contains(r.id) {
                            Button("Detach this Mac (\(r.session) keeps running)") { Task { stopError = await store.detachRemote(r) } }
                        }
                        // the row's Stop / Restart pills show on hover; here they are reachable without it
                        if st?.running == true, st?.problem == nil {
                            Divider()
                            Button("Restart \(r.session)…") { ask([r], restart: true) }.disabled(stopping)
                            Button("Stop \(r.session)…", role: .destructive) { ask([r]) }.disabled(stopping)
                        }
                    }
                // its workspaces on one line, as herdr's own sidebar lists them (Nat: "our ui can detect same?")
                if let ws = st?.workspaces, !ws.isEmpty {
                    Flow(spacing: 12) {
                        ForEach(ws) { w in
                            HStack(spacing: 4) {
                                if ["working", "blocked", "done"].contains(w.status) { HubGlyph(status: w.status) }
                                Text(w.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .help("workspace \(w.id) · \(w.status) · \(w.panes) pane\(w.panes == 1 ? "" : "s")")
                        }
                    }
                    .padding(.leading, 24).padding(.trailing, 8).padding(.bottom, 4)
                }
            }
            }
        }
        .help(versions.joined(separator: "\n"))
        .contextMenu { cardMenu(running) }
        // the same menu, visible: right-click alone hid Remove (Nat: "we should have ui to remove herdr machine?")
        .overlay(alignment: .topTrailing) {
            Menu { cardMenu(running) } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(12).handCursor()
            .help("Stop, Remove saved machine")
        }
        .confirmationDialog("Remove the saved machine \(pendingRemove?.label ?? pendingRemove?.session ?? "")?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let r = pendingRemove { Task { stopError = await store.removeMachine(r) } }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("herdr machine remove \(pendingRemove?.profileId ?? ""): herdr forgets it and the hub stops listing it. "
                 + "\(pendingRemove?.session ?? "The session") keeps running on \(host); save it again with herdr machine add.")
        }
        .confirmationDialog((restartAfter ? "Restart " : "Stop ")
                                + (pendingStop.count == 1 ? "\(pendingStop[0].session) on \(host)?" : "\(pendingStop.count) sessions on \(host)?"),
                            isPresented: $confirmStop, titleVisibility: .visible) {
            Button((restartAfter ? "Restart" : "Stop") + (pendingStop.count == 1 ? " \(pendingStop[0].session)" : " all \(pendingStop.count)"),
                   role: .destructive) {
                let list = pendingStop, again = restartAfter
                stopping = true; stopError = nil
                Task {
                    stopError = await store.stopRemote(list)
                    if again, stopError == nil { for r in list { if let e = await store.startRemote(r) { stopError = e } } }
                    stopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopWarning)
        }
    }

    /// A session's row: its count ("?" when unreadable, which is not stopped), the channel chips its agents were
    /// started with, and Stop / Restart / Start beside it. Split out: one expression was too much for Swift.
    private func sessionRow(_ r: RemoteSession, st: RemoteState?, detail: String) -> some View {
        SessionLine(name: r.session, detail: detail, count: Self.countText(st), running: st?.running == true,
                    needsYou: (st?.needsYou ?? 0) > 0, attached: store.attachedRemotes.contains(r.id),
                    controls: controls(r, st),
                    // a card row has room for the channels; the session's page shows every parameter
                    params: store.params(of: r).filter { $0.kind == .channel }) { open(r) }
    }

    static func countText(_ st: RemoteState?) -> String {
        guard let st else { return "…" }
        if st.problem != nil { return "?" }   // unreadable is not stopped: no Start, which would start a second server
        return st.running ? "\(st.agents) agent\(st.agents == 1 ? "" : "s")" : "off"
    }

    private func controls(_ r: RemoteSession, _ st: RemoteState?) -> AnyView? {
        guard let st, st.problem == nil else { return nil }
        let agents = st.agents
        return AnyView(SessionControls(store: store, ref: .remote(r), running: st.running,
                                       ends: { "herdr --machine \(r.label ?? r.host) server stop: every pane of \(r.session) ends, \(agents) agents included." },
                                       compact: true, error: $stopError))
    }

    private func open(_ r: RemoteSession) { if let onOpen { onOpen(r) } else { store.openRemote(r) } }

    @ViewBuilder private func cardMenu(_ running: [RemoteSession]) -> some View {
        if !running.isEmpty {
            Button("Stop all \(running.count) on \(host)…", role: .destructive) { ask(running) }.disabled(stopping)
            Divider()
        }
        ForEach(sessions) { r in
            Button("Remove saved machine \(r.label ?? r.session) (\(r.session))…") { pendingRemove = r }
        }
    }

    private func ask(_ list: [RemoteSession], restart: Bool = false) {
        pendingStop = list; restartAfter = restart; checked = false; resume = nil; confirmStop = true
        Task { resume = await store.remoteResume(list); checked = true }
    }

    /// What stopping ends, and what reopening brings back, read over ssh like a local Stop's.
    private var stopWarning: String {
        let agents = pendingStop.reduce(0) { $0 + (store.remoteState[$1.id]?.agents ?? 0) }
        var t = "herdr session stop on \(host): " + pendingStop.map(\.session).joined(separator: ", ")
            + ". Every pane ends, \(agents) agent\(agents == 1 ? "" : "s") included."
        guard checked else { return t + "\nChecking over ssh which agents will resume…" }
        guard let r = resume else { return t + "\nCould not read the agents over ssh: reopening may bring them back as plain shells." }
        var back: [String: Int] = [:], lost: [String] = []
        for s in pendingStop { if let c = r[s.id] { c.resumes.forEach { back[$0.key, default: 0] += $0.value }; lost += c.lost } }
        let resumes = back.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        t += "\nReopen resumes " + (resumes.isEmpty ? "no agents" : resumes) + " where they were."
        if !lost.isEmpty { t += "\nNo saved session, back as a plain shell: " + lost.joined(separator: ", ") + "." }
        if resumes.isEmpty, !lost.isEmpty, let target = pendingStop.first?.target {
            // a machine without herdr's agent integration records no agent_session at all (white, 2026-10-08)
            t += "\n\(host) records no agent sessions. Install herdr's integration there first:\n  ssh \(target) '~/.local/bin/herdr integration install claude'"
        }
        return t
    }
}
#endif
