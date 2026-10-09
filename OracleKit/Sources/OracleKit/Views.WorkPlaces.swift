#if os(macOS)
import SwiftUI

/// Work page strip (#116): the herdr sessions that hold this oracle's spaces, shown when one of them is stopped
/// (after a reboot only `default` comes back). Running ones by name; stopped ones with when they stopped, what they
/// saved, and Start. A saved agent already live in another pane is named, and Start asks first: herdr would resume
/// it, and one conversation would run in two panes.
struct WorkPlaces: View {
    @ObservedObject var store: OracleStore
    @State private var asking: SessionPlace?
    @State private var stopping: SessionPlace?
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        if !store.places.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WorkFormat.header("LIVES IN", store.places.count, note: "herdr sessions with this repo's spaces")
                ForEach(store.places) { row($0) }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            }
            .confirmationDialog("Start \(asking?.session ?? "")?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible) {
                Button("Start anyway — opens \(asking?.alreadyLive.count ?? 0) conversation(s) twice", role: .destructive) {
                    if let p = asking { start(p) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Self.liveWarning(asking))
            }
            .confirmationDialog("Stop \(stopping?.session ?? "")?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                                titleVisibility: .visible) {
                Button("Stop — every pane in it ends", role: .destructive) {
                    if let p = stopping { run(p, "Stopping…") { await HerdrControl.stopSession(p.session) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(stopping?.spaces.count ?? 0) space(s) of this repo and every other pane in \(stopping?.session ?? "") end. "
                     + "Start brings back the agents it saves. If you are talking to an agent in it, that conversation stops mid-reply.")
            }
        }
    }

    private func row(_ p: SessionPlace) -> some View {
        // Two short lines, never one long one (Nat 2026-10-09, a narrow window: "ui is messy?"): line 1 the dot, the name,
        // the state and the button; line 2, small and grey, what it holds — truncated in the middle, never wrapped.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(p.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(p.session).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Self.state(p)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if !p.running {
                    Button(busy == p.session ? "Starting…" : "Start \(p.session)") {
                        if p.alreadyLive.isEmpty { start(p) } else { asking = p }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                    .help("herdr --session \(p.session) server — herdr resumes the agents it saved")
                } else {
                    Button(busy == p.session ? "Stopping…" : "Stop") { stopping = p }
                        .buttonStyle(.bordered).controlSize(.small).disabled(busy != nil)
                        .help("herdr session stop \(p.session) — asks first")
                }
            }
            Text(Self.holds(p)).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).padding(.leading, 15)
                .help(p.spaces.joined(separator: "\n"))
            if !p.running, !p.alreadyLive.isEmpty {
                Text("! " + Self.shortWarning(p)).font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.tail).padding(.leading, 15)
                    .help(Self.liveWarning(p))
            }
        }
        .padding(.vertical, 2)
    }

    private func start(_ p: SessionPlace) { run(p, "Starting…") { await HerdrPlaces.start(p.session) } }

    private func run(_ p: SessionPlace, _ label: String, _ f: @escaping () async -> String?) {
        busy = p.session; error = nil
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

    /// Line 2: its spaces, then how many agents.
    static func holds(_ p: SessionPlace) -> String {
        p.spaces.joined(separator: " · ") + (p.agents.isEmpty ? "" : " · \(p.agents.count) agent\(p.agents.count == 1 ? "" : "s")")
    }

    /// One line for the row; the full sentence stays in the tooltip and the Start dialog.
    static func shortWarning(_ p: SessionPlace) -> String {
        let who = p.alreadyLive.map { $0.name.isEmpty ? String($0.sessionId.prefix(8)) : $0.name }.joined(separator: ", ")
        return "\(who) is live elsewhere: Start would open it twice"
    }

    static func liveWarning(_ p: SessionPlace?) -> String {
        guard let p, !p.alreadyLive.isEmpty else { return "" }
        let who = p.alreadyLive.map { $0.name.isEmpty ? String($0.sessionId.prefix(8)) : $0.name }.joined(separator: ", ")
        return "\(who) already live in another pane: starting \(p.session) resumes it a second time"
    }
}
#endif
