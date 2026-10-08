#if os(macOS)
import SwiftUI

/// A herdr session the hub can start and stop: one on this Mac, or a saved machine's (Nat: "in each machine we should
/// can stop a session? and restart like same this" — one component, one set of functions, for both).
public enum SessionRef: Hashable, Sendable {
    case local(String)
    case remote(RemoteSession)

    var name: String { switch self { case .local(let n): n; case .remote(let r): r.session } }
    /// "default" here, "phd on black" there: what a dialog calls it
    var title: String { switch self { case .local(let n): n; case .remote(let r): "\(r.session) on \(r.label ?? r.host)" } }
}

extension HubStore {
    /// Start a stopped session: its server in the background (herdr has no `session start`). nil when it answers.
    public func start(_ s: SessionRef) async -> String? {
        switch s { case .local(let n): await startSession(n); case .remote(let r): await startRemote(r) }
    }

    /// Stop a session: its server and every pane in it. nil when stopped, else the command to run.
    public func stop(_ s: SessionRef) async -> String? {
        switch s { case .local(let n): await stopSession(n); case .remote(let r): await stopRemote([r]) }
    }

    /// What reopening brings back: agents with a saved session (by kind) and the ones that return as plain shells.
    public func resumeCheck(_ s: SessionRef) async -> ResumeCheck? {
        switch s { case .local(let n): await resumeCheck(n); case .remote(let r): await remoteResume([r])?[r.id] }
    }
}

/// Stop / Restart while it runs, Start while it does not, with the same confirmation everywhere: what stopping ends,
/// then which agents reopen resumes and which come back as plain shells.
struct SessionControls: View {
    @ObservedObject var store: HubStore
    let ref: SessionRef
    let running: Bool
    /// the first line of the warning: what stopping ends (spaces, panes, agents), from the caller's own counts
    var ends: () -> String = { "" }
    var compact = false
    var startLabel = "Start"
    @Binding var error: String?
    @State private var confirm = false
    @State private var restart = false
    @State private var busy: String?          // "Stopping…", "Starting…", "Restarting…"
    @State private var checked = false
    @State private var resume: ResumeCheck?

    var body: some View {
        HStack(spacing: 6) {
            if running {
                button(busy ?? "Stop", tint: .red) { ask(restart: false) }
                button("Restart", tint: .secondary) { ask(restart: true) }
            } else {
                button(busy ?? startLabel, tint: HubStyle.accent) { run { await store.start(ref) } }
            }
        }
        .disabled(busy != nil)
        .confirmationDialog((restart ? "Restart " : "Stop ") + ref.title + "?", isPresented: $confirm, titleVisibility: .visible) {
            Button(restart ? "Restart" : "Stop", role: .destructive) {
                let again = restart
                busy = again ? "Restarting…" : "Stopping…"
                Task {
                    error = await store.stop(ref)
                    if again, error == nil { error = await store.start(ref) }
                    busy = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.warning(ends: ends(), checked: checked, resume: resume, ref: ref) + againLines)
        }
    }

    /// What Start runs again on a remote session after its server is up: the commands its agents were started with.
    private var againLines: String {
        guard case .remote(let r) = ref, let l = store.launches[r.id], !l.isEmpty else { return "" }
        return "\n" + (restart ? "After it starts again" : "Start later") + ", the hub runs again:\n"
            + l.map { "  \($0.command)   (in \(($0.cwd as NSString).lastPathComponent))" }.joined(separator: "\n")
    }

    @ViewBuilder private func button(_ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        if compact {
            Button(title, action: action).buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.12))).handCursor()
        } else {
            Button(title, action: action).controlSize(.small).tint(tint).handCursor()
        }
    }

    private func ask(restart again: Bool) {
        restart = again; checked = false; resume = nil; confirm = true
        Task { resume = await store.resumeCheck(ref); checked = true }
    }

    private func run(_ work: @escaping () async -> String?) {
        busy = "Starting…"; error = nil
        Task { error = await work(); busy = nil }
    }

    /// The confirmation's text, the same for a local and a remote session.
    static func warning(ends: String, checked: Bool, resume: ResumeCheck?, ref: SessionRef) -> String {
        var t = ends.isEmpty ? "herdr session stop \(ref.name): every pane in it ends." : ends
        guard checked else { return t + "\nChecking which agents will resume…" }
        guard let r = resume else { return t + "\nCould not read its agents: reopening may bring them back as plain shells." }
        let back = r.resumes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        t += "\nReopen resumes " + (back.isEmpty ? "no agents" : back) + " where they were."
        if !r.lost.isEmpty { t += "\nNo saved session, back as a plain shell: " + r.lost.joined(separator: ", ") + "." }
        if back.isEmpty, !r.lost.isEmpty, case .remote(let m) = ref {
            // a machine without herdr's agent integration records no agent_session at all (white, 2026-10-08)
            t += "\n\(m.label ?? m.host) records no agent sessions. Install herdr's integration there first:\n  ssh \(m.target) '~/.local/bin/herdr integration install claude'"
        }
        return t
    }
}
#endif
