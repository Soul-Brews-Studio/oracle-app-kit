#if os(macOS)
import SwiftUI

/// One herdr session as a group header on the Work page (#116), over the rows it holds (WorkGroups).
///
/// The buttons are about THIS oracle, not the session (Nat, 2026-10-09: "if not started show button, if started hide"):
///  - running, with this oracle's live panes → "Stop <Oracle> · N": closes only its panes, the session keeps running
///    for everyone else; N counts live panes, the number the confirm names;
///  - stopped, with saved conversations of this repo not live anywhere → "Resume N in <target>": only those come back,
///    each exactly its own, into the running session the label names; beside it "Start <session>": the whole session
///    comes back in its own spaces, with its other oracles (a start skips any conversation already live: its pane
///    comes back as a shell);
///  - stopping a whole running session lives in the right-click menu.
struct SessionHeader: View {
    @ObservedObject var store: OracleStore
    let place: SessionPlace
    var toResume: [SavedAgent] = []
    @State private var starting = false
    @State private var stopping = false
    @State private var stoppingMine = false   // "Stop <Oracle>": only this oracle's panes in that session
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        let p = place, name = store.config.name, accent = store.config.color
        let mine = p.running ? Self.livePanes(store.activity, session: p.session) : []
        let target = HerdrPlaces.resumeTarget(store.places)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(p.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(p.session).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Self.state(p)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if !p.running, !toResume.isEmpty {
                    Button(busy ? "Resuming…" : WorkGroups.resumeLabel(toResume.count, into: target)) { resume(toResume, into: target) }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.small).disabled(busy)
                        .help("Bring back only \(name)'s \(toResume.count) conversation(s), each exactly its own, into \(target)")
                    Button(WorkGroups.startLabel(p.session) + "…") { starting = true }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                        .help("Start \(p.session) itself: they come back in their own spaces, with its other oracles")
                } else if !mine.isEmpty {
                    Button(busy ? "Stopping…" : "Stop \(name) · \(mine.count)") { stoppingMine = true }
                        .buttonStyle(.bordered).tint(accent).controlSize(.small).disabled(busy)
                        .help("Close only \(name)'s panes in \(p.session); the session keeps running for everything else")
                }
            }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if p.running { Button("Stop \(p.session)…") { stopping = true } }
            else { Button("Start the whole session \(p.session)…") { starting = true } }
        }
        .confirmationDialog("Start all of \(p.session)?", isPresented: $starting, titleVisibility: .visible) {
            Button("Start the whole session") { startWhole() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every space and agent \(p.session) saved comes back, for every oracle in it — not only "
                 + "\(name). A conversation already live elsewhere is skipped: its pane comes back as a shell.")
        }
        .confirmationDialog("Stop \(p.session)?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Stop — every pane in it ends", role: .destructive) { run { await HerdrControl.stopSession(p.session) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(p.spaces.count) space(s) of this repo and every other pane in \(p.session) end. "
                 + "Starting it later brings back the agents it saves. If you are talking to an agent in it, that conversation stops mid-reply.")
        }
        .confirmationDialog("Stop \(name) in \(p.session)?", isPresented: $stoppingMine, titleVisibility: .visible) {
            Button("Stop \(name) — close its panes", role: .destructive) { stopMine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ends \(name)'s \(mine.count) agent(s) in \(p.session): \(mine.joined(separator: ", ")). "
                 + "Then each of its spaces there that holds only idle shells closes, worktree spaces first; a space where something still runs stays. "
                 + "Their conversations stay, and Resume brings them back — here, or in the session they were saved in. "
                 + "Everything else in \(p.session) keeps running. If you are talking to one of them, that conversation stops mid-reply.")
        }
    }

    /// End this oracle's agents in one session, then close its spaces there that hold only idle shells (worktree
    /// spaces first, then the parent). The session itself keeps running.
    private func stopMine() {
        let session = place.session
        let panes = Self.livePanes(store.activity, session: session)
        let before = store.spaces.filter { $0.session == session }.count
        busy = true; error = nil; note = nil
        Task {
            var failed: [String] = []
            for place in panes { if let e = await HerdrControl.closePane(place: place) { failed.append(e) } }
            await store.refresh()   // the spaces as they are now, without those agents
            let kept = await HerdrControl.closeIdleSpaces(store.spaces, session: session, roots: store.roots)
            error = failed.isEmpty ? nil : failed.joined(separator: "\n")
            busy = false
            await store.refresh()
            let after = store.spaces.filter { $0.session == session }.count
            note = Self.stopNote(session: session, ended: panes.count - failed.count, closed: max(0, before - after), kept: kept)
        }
    }

    /// What Stop did, in one line: "Stopped 1 agent · closed 2 spaces in default", plus what stayed open.
    static func stopNote(session: String, ended: Int, closed: Int, kept: String?) -> String {
        var s = "Stopped \(ended) agent\(ended == 1 ? "" : "s")"
        if closed > 0 { s += " · closed \(closed) space\(closed == 1 ? "" : "s")" }
        s += " in \(session)"
        if let kept { s += " · " + kept }
        return s
    }

    /// This oracle's agent panes in a session ("default:wB3:p1", …): what "Stop <Oracle>" closes.
    static func livePanes(_ activity: [OracleSnapshot.Activity], session: String) -> [String] {
        activity.map(\.place).filter { $0.hasPrefix(session + ":") }
    }

    private func resume(_ agents: [SavedAgent], into target: String) {
        busy = true; error = nil; note = nil
        Task {
            error = await HerdrControl.resume(agents, repo: store.config.localPath, into: target)
            if error == nil { note = "\(agents.count) conversation(s) resumed in \(target)" }
            busy = false
            await store.refresh()
        }
    }

    private func startWhole() {
        let p = place
        busy = true; error = nil; note = nil
        Task {
            let r = await HerdrPlaces.startSkippingLive(name: p.session, dir: p.dir)
            error = r.error
            note = HerdrPlaces.skippedNote(p.session, r.skipped, backup: r.backup)
            busy = false
            await store.refresh()
        }
    }

    private func run(_ f: @escaping () async -> String?) {
        busy = true; error = nil; note = nil
        Task {
            error = await f()
            busy = false
            await store.refresh()
        }
    }

    /// "running", "stopped 07:25", "stopped Oct 5" — short enough never to wrap.
    static func state(_ p: SessionPlace) -> String {
        p.running ? "running" : HerdrPlaces.stoppedSince(p.savedAt).replacingOccurrences(of: "stopped since ", with: "stopped ")
    }
}
#endif
