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

    var body: some View {
        let groups = RemoteParse.groups(store.remotes, running: { store.remoteState[$0.id]?.running == true })
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
                    Text("\(groups.count + 1) machines · this Mac and \(logins) remote login\(logins == 1 ? "" : "s") · "
                         + "\(localRunning.count + remoteRunning.count) sessions running · \(agents) remote agents"
                         + (checked.map { " · probed \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    WorkFormat.header("MACHINES", groups.count + 1, note: "click a session to open it")
                    MachineGrid(minWidth: 330, spacing: 14) {
                        LocalMachineCard(store: store, pick: $pick)
                        ForEach(groups, id: \.host) { g in MachineCard(store: store, host: g.host, sessions: g.sessions) }
                    }
                }
                if !store.unsavedAttached.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        WorkFormat.header("ATTACHED, NOT SAVED", store.unsavedAttached.count,
                                          note: "this Mac has a herdr --remote window on these; save one to list its machine")
                        ForEach(store.unsavedAttached) { r in
                            HStack(spacing: 10) {
                                Text(r.session).font(.callout.weight(.medium))
                                Text(r.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Button("save as herdr machine") { target = r.target; session = r.session; label = r.host }
                                    .buttonStyle(.link).handCursor()
                            }
                        }
                    }
                }
                addForm
                Text("Machines are herdr's saved machines (herdr machine list), one per remote session. Each is asked with "
                     + "herdr --machine <id> status server and agent list, at most every 45 s, or now with refresh. The link "
                     + "icon marks a herdr --remote window open on this Mac.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Network")
        .task { await store.probeRemotes() }   // fresh when the page opens
    }

    /// Saving is herdr's own `herdr machine add`, in a WezTerm window: it may ask before it installs or starts herdr
    /// on the other machine, which the hub never answers for you.
    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SAVE A MACHINE").font(.caption.weight(.semibold)).tracking(1.4)
                Text("herdr machine add <target> --label <name> --remote-session <session>, in a WezTerm window").font(.caption)
            }
            .foregroundStyle(.secondary)
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
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle().fill(running ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 4)
                if attached { Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary).help("This Mac is attached to it now") }
                if needsYou { HubGlyph(status: "done") }
                Text(count).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .foregroundStyle(running ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
    }
}

/// This Mac: its own herdr sessions; a click opens a session's page.
private struct LocalMachineCard: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @State private var showStopped = false
    var body: some View {
        let local = store.localSessions.sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
        let running = local.filter(\.running)
        let stopped = local.filter { !$0.running }
        MachineShell(icon: "laptopcomputer", title: ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "this Mac", users: "this Mac",
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
    @State private var pendingStop: [RemoteSession] = []
    @State private var confirmStop = false
    @State private var checked = false                       // the resume check came back (resume nil then = ssh failed)
    @State private var resume: [String: ResumeCheck]?
    @State private var stopping = false
    @State private var stopError: String?
    var body: some View {
        let targets = Array(Set(sessions.map(\.target))).sorted()
        let users = Array(Set(sessions.compactMap(\.user))).sorted()
        let running = sessions.filter { store.remoteState[$0.id]?.running == true }
        let agents = running.reduce(0) { $0 + (store.remoteState[$1.id]?.agents ?? 0) }
        let versions = Set(targets.compactMap { store.remoteMachines[$0]?.version }).sorted()
        let problem = targets.compactMap { store.remoteMachines[$0]?.problem }.first
        let probed = targets.compactMap { store.remoteMachines[$0]?.checked }.min()   // the card's oldest answer (#98)
        let labels = Array(Set(sessions.compactMap(\.label))).sorted()
        MachineShell(icon: "server.rack", title: host, users: (["herdr machine"] + (labels == [host] ? [] : labels) + users).joined(separator: " · "),
                     line: (versions.isEmpty ? "herdr ?" : "herdr " + versions.joined(separator: ", "))
                        + " · \(running.count) of \(sessions.count) running · \(agents) agent\(agents == 1 ? "" : "s")"
                        + (stopping ? " · stopping…" : probed.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? ""),
                     problem: stopError ?? problem) {
            ForEach(sessions) { r in
                let st = store.remoteState[r.id]
                SessionLine(name: r.session, detail: users.count > 1 ? (r.user ?? "") : "",
                            count: st.map { $0.running ? "\($0.agents) agent\($0.agents == 1 ? "" : "s")" : "off" } ?? "…",
                            running: st?.running == true, needsYou: (st?.needsYou ?? 0) > 0,
                            attached: store.attachedRemotes.contains(r.id)) { store.openRemote(r) }
                    .help(r.command)
                    .contextMenu {
                        Button("Open in WezTerm") { store.openRemote(r) }
                        Button("Copy \(r.command)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.command, forType: .string) }
                        if store.attachedRemotes.contains(r.id) {
                            Button("Detach this Mac (\(r.session) keeps running)") { Task { stopError = await store.detachRemote(r) } }
                        }
                        if st?.running == true {
                            Divider()
                            Button("Stop \(r.session)…", role: .destructive) { ask([r]) }.disabled(stopping)
                        }
                    }
            }
        }
        .contextMenu {
            if !running.isEmpty {
                Button("Stop all \(running.count) on \(host)…", role: .destructive) { ask(running) }.disabled(stopping)
            }
            ForEach(sessions) { r in
                Button("Remove saved machine \(r.label ?? r.session) (herdr machine remove; \(r.session) keeps running)") {
                    Task { stopError = await store.removeMachine(r) }
                }
            }
        }
        .confirmationDialog(pendingStop.count == 1 ? "Stop \(pendingStop[0].session) on \(host)?" : "Stop \(pendingStop.count) sessions on \(host)?",
                            isPresented: $confirmStop, titleVisibility: .visible) {
            Button(pendingStop.count == 1 ? "Stop \(pendingStop[0].session)" : "Stop all \(pendingStop.count)", role: .destructive) {
                let list = pendingStop
                stopping = true; stopError = nil
                Task { stopError = await store.stopRemote(list); stopping = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopWarning)
        }
    }

    private func ask(_ list: [RemoteSession]) {
        pendingStop = list; checked = false; resume = nil; confirmStop = true
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
