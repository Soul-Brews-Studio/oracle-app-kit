#if os(macOS)
import SwiftUI

/// Work page strip (#116): the herdr sessions that hold this oracle's spaces. Two short lines per session.
///
/// The button is about THIS oracle, not the session (Nat, 2026-10-09: "if not started show button, if started hide"):
///  - a stopped session whose saved agents of this repo are not live anywhere → "Resume <Oracle> · N": only those
///    conversations come back, each exactly its own, into the running session — not the session's other oracles;
///  - once every one of them runs again → no button ("all running elsewhere");
///  - a running session → no button. Stop lives in the right-click menu, and Start the whole session there too
///    (it skips any conversation already live: its pane comes back as a shell).
struct WorkPlaces: View {
    @ObservedObject var store: OracleStore
    @State private var starting: SessionPlace?
    @State private var stopping: SessionPlace?
    @State private var busy: String?
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        if !store.places.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WorkFormat.header("LIVES IN", store.places.count, note: "herdr sessions with this repo's spaces")
                ForEach(store.places) { row($0) }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            }
            .confirmationDialog("Start all of \(starting?.session ?? "")?",
                                isPresented: Binding(get: { starting != nil }, set: { if !$0 { starting = nil } }), titleVisibility: .visible) {
                Button("Start the whole session") { if let p = starting { startWhole(p) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every space and agent \(starting?.session ?? "") saved comes back, for every oracle in it — not only "
                     + "\(store.config.name). A conversation already live elsewhere is skipped: its pane comes back as a shell.")
            }
            .confirmationDialog("Stop \(stopping?.session ?? "")?",
                                isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
                Button("Stop — every pane in it ends", role: .destructive) {
                    if let p = stopping { run(p) { await HerdrControl.stopSession(p.session) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(stopping?.spaces.count ?? 0) space(s) of this repo and every other pane in \(stopping?.session ?? "") end. "
                     + "Starting it later brings back the agents it saves. If you are talking to an agent in it, that conversation stops mid-reply.")
            }
        }
    }

    private func row(_ p: SessionPlace) -> some View {
        let back = HerdrPlaces.toResume(p)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(p.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(p.session).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Self.state(p)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if !back.isEmpty {
                    Button(busy == p.session ? "Resuming…" : "Resume \(store.config.name) · \(back.count)") { resume(p, back) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                        .help("Bring back only \(store.config.name)'s \(back.count) conversation(s), each exactly its own, "
                              + "into \(HerdrPlaces.resumeTarget(store.places)) — not \(p.session)'s other oracles")
                }
            }
            Text(Self.holds(p)).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).padding(.leading, 15)
                .help(p.spaces.joined(separator: "\n"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            if p.running {
                Button("Stop \(p.session)…") { stopping = p }
            } else {
                Button("Start the whole session \(p.session)…") { starting = p }
            }
        }
    }

    private func resume(_ p: SessionPlace, _ agents: [SavedAgent]) {
        let target = HerdrPlaces.resumeTarget(store.places)
        busy = p.session; error = nil; note = nil
        Task {
            error = await HerdrControl.resume(agents, repo: store.config.localPath, into: target)
            if error == nil { note = "\(agents.count) conversation(s) resumed in \(target)" }
            busy = nil
            await store.refresh()
        }
    }

    private func startWhole(_ p: SessionPlace) {
        busy = p.session; error = nil; note = nil
        Task {
            let r = await HerdrPlaces.startSkippingLive(name: p.session, dir: p.dir)
            error = r.error
            note = HerdrPlaces.skippedNote(p.session, r.skipped, backup: r.backup)
            busy = nil
            await store.refresh()
        }
    }

    private func run(_ p: SessionPlace, _ f: @escaping () async -> String?) {
        busy = p.session; error = nil; note = nil
        Task {
            error = await f()
            busy = nil
            await store.refresh()
        }
    }

    /// "running", "stopped 07:25", "stopped Oct 5" — short enough never to wrap.
    static func state(_ p: SessionPlace) -> String {
        p.running ? "running" : HerdrPlaces.stoppedSince(p.savedAt).replacingOccurrences(of: "stopped since ", with: "stopped ")
    }

    /// Line 2: its spaces, how many agents, and — stopped — how many of them already run elsewhere.
    static func holds(_ p: SessionPlace) -> String {
        var s = p.spaces.joined(separator: " · ")
        if !p.agents.isEmpty { s += " · \(p.agents.count) agent\(p.agents.count == 1 ? "" : "s")" }
        if !p.running, !p.alreadyLive.isEmpty {
            s += p.alreadyLive.count == p.agents.count ? " · all running elsewhere" : " · \(p.alreadyLive.count) running elsewhere"
        }
        return s
    }
}
#endif
