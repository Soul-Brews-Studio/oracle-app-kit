#if os(macOS)
import SwiftUI

/// One herdr session on another machine, as a page: the same shape as a local session's (Nat, "when click remote
/// session it should go the same? … same as local?"). Its name and where it runs, Stop / Restart (or Start), Open in
/// WezTerm, then its workspaces, each with Show in herdr — focus it there, then raise this Mac's window on it.
struct RemoteSessionPage: View {
    @ObservedObject var store: HubStore
    /// the session as it was clicked; the page reads the live one (its saved-machine id and label) from the store
    let clicked: RemoteSession
    @State private var error: String?
    @State private var confirmBack: RemoteWorkspace?   // Bring back asked, not yet confirmed
    @State private var bringing: String?               // the workspace coming home now
    @State private var ferry: FerryRun?                // what the last bring-back printed

    init(store: HubStore, remote: RemoteSession) { self.store = store; self.clicked = remote }

    private var remote: RemoteSession { store.remotes.first { $0.id == clicked.id } ?? clicked }

    var body: some View {
        let st = store.remoteState[remote.id]
        let spaces = st?.workspaces ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(remote.session).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("on \(remote.label ?? remote.host) · \(remote.shortTarget)").font(.callout).foregroundStyle(.secondary)
                    Text(stateLine(st, spaces: spaces.count)).font(.callout).foregroundStyle(.secondary)
                    if store.attachedRemotes.contains(remote.id) {
                        Text("attached here").font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(Color.green)
                            .help("This Mac has a herdr --remote window on it now")
                    }
                    Spacer()
                    if let st, st.problem == nil {
                        SessionControls(store: store, ref: .remote(remote), running: st.running,
                                        ends: { "Every pane of \(remote.session) on \(remote.label ?? remote.host) ends, \(st.agents) agent\(st.agents == 1 ? "" : "s") included." },
                                        error: $error)
                    }
                    Button("Open in WezTerm") { store.openRemote(remote) }.controlSize(.small).handCursor()
                }
                Text(facts(st)).font(.caption).foregroundStyle(.tertiary)
                if let e = error ?? st?.problem {
                    Text(e).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if st?.running == true {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(spaces) { w in row(w) }
                    }
                    if spaces.isEmpty {
                        Text("No workspaces reported yet — refresh, or open it in WezTerm.").font(.callout).foregroundStyle(.secondary)
                    }
                } else if st != nil, st?.problem == nil {
                    Text("This session is not running. Start it here, or from a terminal:").foregroundStyle(.secondary)
                    Text("ssh \(remote.target) 'herdr --session \(remote.session) server'").font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(remote.session)
        .task(id: remote.id) { await store.probeRemotes() }   // fresh when the page opens
        .confirmationDialog(confirmBack.map { "Bring \($0.label) back to this Mac?" } ?? "",
                            isPresented: Binding(get: { confirmBack != nil }, set: { if !$0 { confirmBack = nil } }),
                            titleVisibility: .visible) {
            Button("Bring back") {
                guard let w = confirmBack else { return }
                bringing = w.id
                Task { ferry = await store.bringBack(remote, workspace: w.id, label: w.label); bringing = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its agent on \(remote.label ?? remote.host) stops and that space closes. Its conversation, with every turn it had there, resumes here in the folder it was sent from; the agent running there now stops first.")
        }
        .sheet(item: $ferry) { FerryLog(run: $0) }
    }

    /// A workspace row, like a local space's: its state, its label, its panes, and Show in herdr.
    private func row(_ w: RemoteWorkspace) -> some View {
        HStack(spacing: 10) {
            if ["working", "blocked", "done"].contains(w.status) { HubGlyph(status: w.status) }
            else { Circle().strokeBorder(Color.secondary.opacity(0.6)).frame(width: 9, height: 9).frame(width: 14) }
            Text(w.label).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(1)
            ForEach(store.params(of: remote, workspace: w.id), id: \.self) { ParamChip(param: $0) }
            Spacer(minLength: 8)
            Text("\(w.panes) pane\(w.panes == 1 ? "" : "s") · \(HubParse.word(w.status))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if store.agentFolder(remote, workspace: w.id) != nil {
                Button(bringing == w.id ? "Bringing…" : "Bring back") { confirmBack = w }
                    .controlSize(.small).tint(HubStyle.accent).disabled(bringing != nil).handCursor()
                    .help("Its Claude agent comes home: it stops there, and this Mac resumes its conversation with every turn it had there")
            }
            Button("Show in herdr") { Task { error = await store.showRemoteWorkspace(remote, w.id) } }
                .controlSize(.small).handCursor()
                .help("herdr workspace focus \(w.id) on \(remote.label ?? remote.host), then this Mac's window on \(remote.session)")
        }
        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, launchLine(w) == nil ? 7 : 2)
        .overlay(alignment: .bottomLeading) {
            // how its agent was started: what Start / Restart runs again (Nat: "the important thing is …")
            if let l = launchLine(w) {
                Text("starts with  " + l).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).padding(.leading, 34).offset(y: 12)
            }
        }
        .padding(.bottom, launchLine(w) == nil ? 0 : 14)
        .contentShape(Rectangle())
        // rest on the row: its pane's screen, read from the machine (Nat: "hover show tty? preview")
        .peekOnHover(w.label, workspace: w.id, run: { [r = remote, via = store.remoteState[remote.id]?.viaSSH == true] args in
            let out = await HubStore.remoteHerdr(r, args, viaSSH: via)
            return out?.status == 0 ? out?.out : nil
        })
    }

    /// The remembered command of the agent in this workspace (matched by its folder), if any.
    private func launchLine(_ w: RemoteWorkspace) -> String? {
        let cwds = Set((store.remoteState[remote.id]?.agentList ?? []).filter { $0.workspace == w.id }.map(\.cwd))
        return store.launches[remote.id]?.first { cwds.contains($0.cwd) }?.command
    }

    private func stateLine(_ st: RemoteState?, spaces: Int) -> String {
        guard let st else { return "asking…" }
        if st.problem != nil { return "not readable" }
        guard st.running else { return "stopped" }
        return "running · \(spaces) space\(spaces == 1 ? "" : "s") · \(st.agents) agent\(st.agents == 1 ? "" : "s")"
    }

    /// herdr's version there, how the hub reads it, and when it last answered.
    private func facts(_ st: RemoteState?) -> String {
        guard let st else { return "" }
        return ([st.version.map { "herdr " + $0 }, st.viaSSH ? "read over ssh (its herdr has no --machine bridge)" : "read with herdr --machine",
                 "probed " + st.checked.formatted(date: .omitted, time: .shortened)].compactMap { $0 }).joined(separator: " · ")
    }
}
#endif
