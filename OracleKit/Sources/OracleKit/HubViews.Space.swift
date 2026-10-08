#if os(macOS)
import SwiftUI
import AppKit

struct SpaceLine: View {
    let space: HubSpace
    let app: URL?
    let store: HubStore
    var children: [HubSpace] = []        // worktree spaces under this main space: closing it closes them too
    var fold: Binding<Bool>? = nil       // main space with worktrees: hide / show its rows
    var selected = false                 // its panes are in the drawer
    var cursor = false                   // the keyboard's row (j/k)
    var marked = false                   // picked with x, for a batch close
    var onOpen: (() -> Void)? = nil      // a click on the row (not on a button): open its panes in the drawer
    @State private var hover = false
    @State private var confirmClose = false
    @State private var agents: [String: [ClosedAgent]]?
    @State private var closeError: String?
    @State private var confirmSend: RemoteSession?   // Send asked, not yet confirmed
    @State private var sending = false
    @State private var ferry: FerryRun?              // what the last send printed
    var body: some View {
        HStack(spacing: 10) {
            if space.linked { Text("└").font(.callout.monospaced()).foregroundStyle(.tertiary) }
            if marked { Image(systemName: "checkmark.square.fill").foregroundStyle(HubStyle.accent).font(.system(size: 12)) }
            if let f = fold {   // fold the worktree rows under this main space
                Button { withAnimation(.snappy) { f.wrappedValue.toggle() } } label: {
                    Image(systemName: f.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                }.buttonStyle(.plain).handCursor().help(f.wrappedValue ? "Show its \(children.count) worktrees" : "Hide its worktrees")
            }
            HubGlyph(status: space.status)
                .contentShape(Rectangle()).onTapGesture { onOpen?() }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(space.label).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if fold?.wrappedValue == true {
                        Text("+\(children.count) \(children.count == 1 ? "worktree" : "worktrees")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // under the name: the branch, as herdr's sidebar shows it; the repo when the label does not say it
                if let sub = [space.linked || space.repo == space.label ? nil : space.repo, space.branch].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(sub).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle()).onTapGesture { onOpen?() }
            Spacer(minLength: 8)
                .contentShape(Rectangle()).onTapGesture { onOpen?() }   // the empty middle of the row opens too
            Text("\(space.panes) \(space.panes == 1 ? "pane" : "panes") · \(space.agents) \(space.agents == 1 ? "agent" : "agents")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if app != nil, let r = space.repo {
                Button("Open app") { store.openApp(HubParse.appKey(forRepo: r)) }.controlSize(.small).handCursor()
            }
            // the saved machine whose session has this one's name (m5 laris-co → white's laris-co): fork the agent there
            if space.agents > 0, space.checkout != nil, let m = store.mirror(of: space.session) {
                Button(sending ? "Sending…" : "Send to \(m.host)") { confirmSend = m }
                    .controlSize(.small).tint(HubStyle.accent).disabled(sending).handCursor()
                    .help("Fork this space's agent to \(m.shortTarget) (\(m.session)): it keeps running here, and there it resumes this conversation under a new session id")
                    .confirmationDialog(confirmSend.map { "Send \(space.label) to \($0.label ?? $0.host)?" } ?? "",
                                        isPresented: Binding(get: { confirmSend != nil }, set: { if !$0 { confirmSend = nil } }),
                                        titleVisibility: .visible) {
                        Button("Send") {
                            guard let m = confirmSend else { return }
                            sending = true
                            Task { ferry = await store.send(space, to: m); sending = false }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Its agent keeps running here. On \(m.shortTarget) it opens in \(m.session) and resumes this conversation under a new session id, with its launch flags. A Discord bot connects there only when that machine holds its bot state: keep one copy on Discord.")
                    }
            }
            Button("Show in herdr") { store.showInHerdr(space) }.controlSize(.small).tint(.secondary).handCursor()
                .help("Switches herdr to this space: in place when its WezTerm window is in front, raising it on its own screen when behind")
                .contextMenu { Button("Bring here — move its WezTerm window to the main screen") { store.bringHere(space) } }
            Button("Close") {
                agents = nil; closeError = nil; confirmClose = true
                Task {
                    var all: [String: [ClosedAgent]] = [:]
                    for sp in [space] + children { all[sp.id] = await store.agents(in: sp) ?? [] }
                    agents = all
                }
            }
                .controlSize(.small).tint(.red).handCursor().help("Close this space only; the rest of \(space.session) keeps running")
        }
        .overlay(alignment: .bottomLeading) {
            if let e = closeError { Text(e).font(.caption).foregroundStyle(.orange).textSelection(.enabled).offset(y: 14) }
        }
        .confirmationDialog(children.isEmpty ? "Close \(space.label)?" : "Close \(space.label) and its \(children.count) worktree spaces?",
                            isPresented: $confirmClose, titleVisibility: .visible) {
            Button(children.isEmpty ? "Close space" : "Close the group (\(children.count + 1) spaces)", role: .destructive) {
                let all = agents ?? [:]
                Task { closeError = await store.closeSpace(space, children: children, agents: all) }
            }.disabled(agents == nil)
            Button("Cancel", role: .cancel) {}
        } message: { Text(closeMessage) }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .padding(.leading, space.linked ? 14 : 0)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? HubStyle.accent.opacity(0.16) : marked ? HubStyle.accent.opacity(0.08) : hover ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(cursor ? HubStyle.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .onHover { h in hover = h; if onOpen != nil { if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
        // rest on the row: its pane's screen, read from this Mac's herdr (Nat: "hover show tty? preview")
        .peekOnHover(space.label, workspace: space.spaceId, run: { [s = space.session] args in
            await Shell.run("herdr", ["--session", s] + args, timeout: 4)
        })
        .help(onOpen == nil ? "" : "Click to see its panes live (esc closes)")
        .sheet(item: $ferry) { FerryLog(run: $0) }
    }

    private var closeMessage: String {
        guard let all = agents else { return "Reading the agents in this space…" }
        let a = ([space] + children).flatMap { all[$0.id] ?? [] }
        var t = children.isEmpty ? "" : "herdr closes a repo's main space only together with its worktree spaces: "
            + children.map(\.label).joined(separator: ", ") + ". The worktrees stay on disk.\n"
        if a.isEmpty { return t + "No agents here; nothing to resume." }
        let lines = a.map { "\($0.name) (\($0.kind))" + ($0.sessionId == nil ? " — no saved session, cannot resume" : "") }
        t += "Ends: " + lines.joined(separator: ", ") + ".\nSaved first, so Reopen under \"Recently closed\" brings them back resumed"
        return t + (children.isEmpty ? "." : " — the main space first, then each worktree.")
    }
}

/// A space's panes, live: chips to pick one (agent name or shell, its state), and that pane's screen read every
/// second. The panes come from `herdr --session <s> pane list --workspace <space>`.
struct SpaceDrawer: View {
    let space: HubSpace
    let accent: Color
    let close: () -> Void
    var full = false
    var toggleFull: (() -> Void)? = nil
    struct Pane: Identifiable, Hashable { let id: String; let agent: String?; let status: String; let cwd: String; let focused: Bool }
    @State private var panes: [Pane] = []
    @State private var pick: String?
    @State private var problem: String?
    @AppStorage(LiveTerminal.enabledKey) private var live = true   // ☑ Ghostty, live · ☐ the pane's text, read every second

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HubGlyph(status: space.status)
                Text(space.label).font(.callout.weight(.semibold)).foregroundStyle(accent).lineLimit(1)
                Text(space.session + " · " + space.spaceId).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(full ? (live && LiveTerminal.make != nil ? "i type · esc back" : "esc back") : "f full · esc")
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                if LiveTerminal.make != nil {
                    Toggle("Live", isOn: $live).toggleStyle(.checkbox).font(.caption).handCursor()
                        .help("Ticked: the pane itself, live (herdr's stream in Ghostty); full screen sizes the pane to the page and takes your keys. Unticked: its text, read every second, with history.")
                }
                if let toggleFull {
                    Button(action: toggleFull) {
                        Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help(full ? "Back to the list (esc)" : "Full screen (f)")
                }
                Button(action: close) { Image(systemName: "xmark").font(.callout.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help("Close (esc)")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if panes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(panes) { p in
                            Button { pick = p.id } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(p.status == "working" ? Color.green : p.status == "blocked" ? Color.red : p.status == "done" ? Color.orange : Color.secondary)
                                        .frame(width: 6, height: 6)
                                    Text(p.agent ?? "shell").font(.caption.weight(pick == p.id ? .semibold : .regular))
                                    Text(p.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(pick == p.id ? accent.opacity(0.22) : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain).handCursor().help((p.cwd as NSString).abbreviatingWithTildeInPath)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }
            }
            Divider()
            if let pick {
                if live, let make = LiveTerminal.make {
                    // Ghostty, fed by herdr's stream (as Heeler attaches): observe in the drawer, control in full screen
                    make(LiveTerminal.Spec(session: space.session, pane: pick, control: full)).id(pick)
                } else {
                    PaneScreen(place: space.session + ":" + pick).id(pick)
                }
            } else {
                Text(problem ?? "reading the panes…").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .task(id: space.id) { await load() }
    }

    /// The space's panes; the agent pane first (the one working, else the focused one), shells after.
    private func load() async {
        panes = []; pick = nil; problem = nil
        guard let out = await Shell.run("herdr", ["--session", space.session, "pane", "list", "--workspace", space.spaceId], timeout: 4),
              let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = (o["result"] as? [String: Any])?["panes"] as? [[String: Any]] else {
            problem = "can't list the panes — herdr --session \(space.session) pane list --workspace \(space.spaceId)"; return
        }
        panes = list.compactMap { p in
            (p["pane_id"] as? String).map { Pane(id: $0, agent: p["agent"] as? String, status: p["agent_status"] as? String ?? "unknown",
                                                cwd: p["cwd"] as? String ?? "", focused: p["focused"] as? Bool ?? false) }
        }
        let rank: (Pane) -> Int = { p in p.agent == nil ? 3 : p.status == "working" ? 0 : p.status == "blocked" || p.status == "done" ? 1 : 2 }
        panes.sort { rank($0) != rank($1) ? rank($0) < rank($1) : ($0.focused && !$1.focused) }
        let want = UserDefaults.standard.string(forKey: "hubOpenPane")   // -hubOpenPane <pane id> (tests)
        pick = panes.first { $0.id == want }?.id ?? panes.first?.id
        if panes.isEmpty { problem = "no panes in this space" }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
