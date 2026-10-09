#if os(macOS)
import SwiftUI
import AppKit

// MARK: one herdr session — its spaces, the way herdr's sidebar lists them

struct SessionSpaces: View {
    @ObservedObject var store: HubStore
    let session: String
    @State private var stopError: String?
    @State private var closed: [ClosedSpace] = []
    @State private var folded: Set<String> = []   // main spaces whose worktree rows are hidden; key = session:repo
    @State private var reopenError: String?
    @State private var open: HubSpace?           // the space whose panes the drawer shows
    @State private var grown: CGFloat = 0
    @State private var esc: Any?
    @AppStorage("hub.drawerWidth") private var drawerWidth: Double = 620
    var body: some View {
        // A wide window gives the drawer what the list does not use: the list's column is at most 900 pt (+ its
        // padding), so the drawer takes the rest — never less than its own width (Nat: "give the scene to the right")
        GeometryReader { geo in
            HStack(spacing: 0) {
                if !(full && open != nil) { list }
                if let sp = open {
                    if !full { Divider() }
                    SpaceDrawer(space: sp, accent: HubStyle.accent, close: { closeDrawer() }, full: full,
                                toggleFull: { withAnimation(.easeOut(duration: 0.15)) { full.toggle() } })
                        .frame(width: full ? geo.size.width : max(CGFloat(drawerWidth), geo.size.width - Self.listRoom))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .onDisappear { closeDrawer() }
        // ⌘⎋ while typing into the drawer's pane: its keys came back; now this page's esc in the same press
        .onReceive(NotificationCenter.default.publisher(for: LiveTerminal.escapeNotification)) { _ in
            guard open != nil else { return }
            if full { withAnimation(.easeOut(duration: 0.15)) { full = false } } else { closeDrawer() }
        }
        .task {   // -hubOpenSpace <label> (tests): open that space's drawer once the spaces are known; -hubFull YES: full screen
            guard let want = UserDefaults.standard.string(forKey: "hubOpenSpace") else { return }
            for _ in 0..<100 { if let sp = store.spaces.first(where: { $0.session == session && $0.label == want }) {
                                   openDrawer(sp); if UserDefaults.standard.bool(forKey: "hubFull") { full = true }; return }
                               try? await Task.sleep(for: .milliseconds(200)) }
        }
    }

    /// A click on a space row: its panes in a drawer on the right, like an oracle app's Work drawer. The window
    /// grows by the drawer's width and gives it back on close; esc closes.
    private func openDrawer(_ sp: HubSpace) {
        if open?.id == sp.id { closeDrawer(); return }
        if open == nil {
            let dx = CGFloat(drawerWidth) + 1; grown += dx
            DispatchQueue.main.async { Drawer.grow(by: dx) }
            esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if LiveTerminal.typing { return e }   // esc is the agent's while typing (⌘⎋ is this page's esc then)
                if e.keyCode == 53, open != nil, full { withAnimation(.easeOut(duration: 0.15)) { full = false }; return nil }   // full screen first
                if e.keyCode == 53, open != nil { closeDrawer(); return nil }
                return e
            }
        }
        withAnimation(.easeOut(duration: 0.18)) { open = sp }
    }
    private func closeDrawer() {
        guard open != nil || grown > 0 else { return }
        withAnimation(.easeOut(duration: 0.18)) { open = nil; full = false }
        if grown > 0 { let dx = grown; grown = 0; DispatchQueue.main.async { Drawer.grow(by: -dx) } }
        if let m = esc { NSEvent.removeMonitor(m); esc = nil }
    }

    /// What the space list needs beside the drawer: its 900 pt column and 28 pt of padding each side.
    static let listRoom: CGFloat = 900 + 56
    @State private var full = false   // the drawer fills the page (f); esc comes back to the list, like a browser
    @State private var clientWindow: WezTerm.ClientWindow?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var keys: Any?   // the page's key monitor: Gmail's keys — / or ⌘F filter, j/k move, o open, s show, x pick, esc clears
    @State private var cursor: String?          // the row j/k is on
    @State private var marks: Set<String> = []  // rows picked with x
    @State private var anchor: String?          // where a shift-click range starts: the last row picked or clicked
    @State private var confirmBatch = false
    @State private var batchAgents: [String: [ClosedAgent]]?

    /// The rows as the page shows them now: filtered, worktrees of a folded group hidden (not while filtering).
    private func visibleRows() -> [HubSpace] {
        let all = Self.treeOrder(store.spaces.filter { $0.session == session }.sorted { store.listNumber($0) < store.listNumber($1) })
        return all.filter { sp in
            shown(sp, in: all) && (!filter.isEmpty || !(sp.linked && folded.contains(sp.session + ":" + (sp.repo ?? ""))))
        }
    }

    private func move(_ step: Int) {
        let rows = visibleRows(); guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == cursor }.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        cursor = rows[i].id
    }

    /// Shift+j / Shift+k (or ⇧↓ / ⇧↑): move and pick as you go, up or down, like a shift-click range.
    private func extend(_ step: Int) {
        if let c = cursor { marks.insert(c) }
        move(step)
        if let c = cursor { marks.insert(c); anchor = c }
    }

    /// Gmail's shift-click: every row from the last one picked (or the cursor) to this one, up or down, is picked.
    private func pickRange(to id: String) {
        let rows = visibleRows().map(\.id)
        guard let to = rows.firstIndex(of: id) else { return }
        let from = (anchor ?? cursor).flatMap { rows.firstIndex(of: $0) } ?? to
        marks.formUnion(rows[min(from, to)...max(from, to)])
        cursor = id; anchor = id
    }

    /// A space shows when the filter is empty, it matches (label, branch, repo), or one of its worktrees matches.
    private func shown(_ sp: HubSpace, in all: [HubSpace]) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let hit = { (x: HubSpace) in [x.label, x.branch ?? "", x.repo ?? ""].contains { $0.lowercased().contains(q) } }
        if hit(sp) { return true }
        if !sp.linked, let r = sp.repo { return all.contains { $0.linked && $0.repo == r && hit($0) } }
        return false
    }

    private func installKeys() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if LiveTerminal.typing { return e }   // the keys belong to the pane being typed into
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let typing = NSApp.keyWindow?.firstResponder is NSTextView   // a field already has the keys
            if mods == .command, e.charactersIgnoringModifiers == "f" { filterFocused = true; return nil }
            if typing {   // in the filter: ↓ or ⏎ leaves it for the rows, like Gmail's search
                if filterFocused, e.keyCode == 125 || e.keyCode == 36 { filterFocused = false; if cursor == nil { move(1) }; return nil }
                return e
            }
            if e.keyCode == 53 {   // esc: the drawer first (its own monitor), then the picks, the filter, the cursor
                if open != nil { return e }
                if !marks.isEmpty { marks = []; anchor = nil; return nil }
                if !filter.isEmpty { filter = ""; return nil }
                if cursor != nil { cursor = nil; return nil }
                return e
            }
            let row = { visibleRows().first { $0.id == cursor } }
            if e.keyCode == 125 { if mods.contains(.shift) { extend(1) } else { move(1) }; return nil }    // ↓ (⇧: pick down)
            if e.keyCode == 126 { if mods.contains(.shift) { extend(-1) } else { move(-1) }; return nil }  // ↑ (⇧: pick up)
            if e.keyCode == 36, mods.isEmpty { if let r = row() { openDrawer(r) }; return nil }   // ⏎
            guard mods.subtracting([.shift, .capsLock]).isEmpty, let c = e.charactersIgnoringModifiers else { return e }
            switch c {
            case "/": filterFocused = true
            case "j": move(1)
            case "k": move(-1)
            case "J": extend(1)    // shift+j: pick down
            case "K": extend(-1)   // shift+k: pick up
            case "o": if let r = row() { openDrawer(r) }
            case "s": if let r = row() { store.showInHerdr(r) }
            case "f": if open != nil { withAnimation(.easeOut(duration: 0.15)) { full.toggle() } }
            case "i": if open != nil {   // type into the pane: full screen first, so the pane is sized to the page
                          if !full { withAnimation(.easeOut(duration: 0.15)) { full = true } }
                          NotificationCenter.default.post(name: LiveTerminal.focusNotification, object: nil) }
            case "x": if let id = cursor { if marks.contains(id) { marks.remove(id) } else { marks.insert(id) }; anchor = id }
            case "#": if !marks.isEmpty { batchAgents = nil; confirmBatch = true
                          Task { var a: [String: [ClosedAgent]] = [:]
                                 for sp in visibleRows() where marks.contains(sp.id) { a[sp.id] = await store.agents(in: sp) ?? [] }
                                 batchAgents = a } }
            default: return e
            }
            return nil
        }
    }

    @ViewBuilder private var list: some View {
        let s = store.sessions.first { $0.name == session }
        let byNumber = store.spaces.filter { $0.session == session }.sorted { store.listNumber($0) < store.listNumber($1) }
        let all = Self.treeOrder(byNumber)
        let spaces = all.filter { shown($0, in: all) }
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(s?.running == true ? "running · \(all.count) spaces" : "stopped").font(.callout).foregroundStyle(.secondary)
                    if s?.running == true, let w = clientWindow {
                        // where its WezTerm window is: Show in herdr switches in place when front, raises it when behind
                        Text(w.label).font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill({ if case .front = w { return Color.green.opacity(0.18) }; return Color.secondary.opacity(0.15) }()))
                            .foregroundStyle({ if case .front = w { return Color.green }; return Color.secondary }())
                            .help("The WezTerm window with this session's herdr client. Front: Show in herdr switches inside it. Behind: it rises on its own screen. No window: one opens on the main screen.")
                    }
                    Spacer()
                    if s?.running == true {
                        SessionControls(store: store, ref: .local(session), running: true, ends: { stopEnds }, error: $stopError)
                            .help("herdr session stop \(session) — ends every pane in it")
                        Button("Open in WezTerm") { store.openSession(session) }.controlSize(.small)
                    }
                }
                if let e = stopError {
                    Text(e).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if s?.running != true {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This herdr session is not running. Open it in WezTerm, or from any terminal:").foregroundStyle(.secondary)
                        Text("herdr --session \(session)").font(.callout.monospaced()).textSelection(.enabled)
                        HStack(spacing: 8) {
                            SessionControls(store: store, ref: .local(session), running: false, startLabel: "Start in background", error: $stopError)
                                .help("herdr --session \(session) server, detached — no window; agents with a saved session resume")
                            Button("Open in WezTerm") { store.openSession(session) }.controlSize(.small).handCursor()
                        }
                    }
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
                    SavedSpacesTable(store: store, dir: s?.dir)   // #116: what Start would bring back
                }
                if s?.running == true, !all.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                        TextField("Filter spaces — type, or press /   (⌘F)", text: $filter)
                            .textFieldStyle(.plain).focused($filterFocused)
                            .onExitCommand { if filter.isEmpty { filterFocused = false } else { filter = "" } }
                        if !filter.isEmpty {
                            Text("\(spaces.count) of \(all.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(filterFocused ? HubStyle.accent : Color.primary.opacity(0.08)))
                }
                if !marks.isEmpty {
                    HStack(spacing: 10) {
                        Text("\(marks.count) picked").font(.callout.weight(.semibold))
                        Button("Close picked… (#)", role: .destructive) {
                            batchAgents = nil; confirmBatch = true
                            Task { var a: [String: [ClosedAgent]] = [:]
                                   for sp in spaces where marks.contains(sp.id) { a[sp.id] = await store.agents(in: sp) ?? [] }
                                   batchAgents = a }
                        }.controlSize(.small).tint(.red)
                        Button("Clear (esc)") { marks = [] }.controlSize(.small)
                    }
                } else if s?.running == true, !all.isEmpty {
                    Text("j k move · o open · s show in herdr · x pick · ⇧J ⇧K or ⇧click pick up/down · # close picked · / filter · esc clear")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                VStack(spacing: 2) {
                    if spaces.isEmpty, !filter.isEmpty {
                        Text("No space matches “\(filter)”").foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(spaces) { sp in
                        let key = sp.session + ":" + (sp.repo ?? "")
                        let kids = sp.linked || sp.repo == nil ? [] : spaces.filter { $0.linked && $0.repo == sp.repo }
                        if !(sp.linked && folded.contains(key)) || !filter.isEmpty {   // a worktree row hides while its main space is folded (not while filtering)
                            SpaceLine(space: sp, app: sp.repo.map { store.apps[HubParse.appKey(forRepo: $0)] } ?? nil, store: store,
                                      children: kids,
                                      fold: kids.isEmpty ? nil : Binding(get: { folded.contains(key) },
                                                                          set: { if $0 { folded.insert(key) } else { folded.remove(key) } }),
                                      selected: open?.id == sp.id, cursor: cursor == sp.id, marked: marks.contains(sp.id),
                                      onOpen: {   // ⇧-click picks the range from the last pick to here; a plain click opens it
                                          if NSEvent.modifierFlags.contains(.shift) { pickRange(to: sp.id) } else { cursor = sp.id; openDrawer(sp) }
                                      })
                                .id(sp.id)
                        }
                    }
                }
                if !closed.isEmpty { recentlyClosed(running: s?.running == true) }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)   // centred in what the sidebar and the drawer leave (#57); a narrow window is unchanged
        }
        .onChange(of: cursor) { _, id in if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } } }
        }
        .navigationTitle(session)
        .onChange(of: session) { _, _ in closeDrawer(); filter = ""; cursor = nil; marks = [] }
        .confirmationDialog("Close \(marks.count) spaces?", isPresented: $confirmBatch, titleVisibility: .visible) {
            Button("Close \(marks.count) spaces", role: .destructive) {
                let picked = visibleRows().filter { marks.contains($0.id) }, agents = batchAgents ?? [:]
                Task {
                    for sp in picked { if let e = await store.closeSpace(sp, children: [], agents: [sp.id: agents[sp.id] ?? []]) { stopError = e } }
                    marks = []
                }
            }.disabled(batchAgents == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = (batchAgents ?? [:]).values.reduce(0) { $0 + $1.count }
            Text(batchAgents == nil ? "Reading the agents in them…" : "\(n) agent\(n == 1 ? "" : "s") in them stop; each comes back resumed if you reopen its space from Recently closed. The rest of \(session) keeps running.")
        }
        .onAppear { installKeys() }
        .onDisappear { if let k = keys { NSEvent.removeMonitor(k); keys = nil } }
        .task(id: session) {
            while !Task.isCancelled {
                clientWindow = await WezTerm.clientWindow(session: session)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: session) { _, _ in stopError = nil; reopenError = nil; loadClosed() }
        .onChange(of: store.lastRefresh) { _, _ in loadClosed() }
        .onAppear { loadClosed() }
    }

    /// This session's closed spaces, newest first; inside one group the main space before its worktrees.
    /// Main spaces in herdr order, each followed by its worktree spaces; a worktree whose main space has no
    /// space open stays where herdr put it.
    static func treeOrder(_ list: [HubSpace]) -> [HubSpace] {
        let parents = Set(list.filter { !$0.linked && $0.repo != nil }.map { $0.repo! })
        var out: [HubSpace] = []
        for sp in list where sp.linked == false || sp.repo == nil || !parents.contains(sp.repo!) {
            out.append(sp)
            if !sp.linked, let r = sp.repo { out += list.filter { $0.linked && $0.repo == r } }
        }
        return out
    }

    private func loadClosed() {
        closed = ClosedSpaces.load().filter { $0.session == session }
            .sorted { ($0.closedAt, $0.linked == true ? 0 : 1) > ($1.closedAt, $1.linked == true ? 0 : 1) }
    }

    /// Spaces closed from this page: what they held, and Reopen (same cwd, each agent resumed).
    private func recentlyClosed(running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkFormat.header("RECENTLY CLOSED", closed.count, note: running ? "reopen brings each agent back resumed" : "start the session to reopen")
            ForEach(closed) { c in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.label).font(.custom("Avenir Next", size: 14).weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(c.agents.isEmpty ? "no agents" : c.agents.map { "\($0.kind)\($0.sessionId == nil ? " (no session)" : "")" }.joined(separator: " · "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(c.closedAt.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Reopen") { reopenError = nil; Task { reopenError = await store.reopen(c); loadClosed() } }
                        .controlSize(.small).disabled(!running).handCursor()
                    Button("Forget") { store.forget(c); loadClosed() }.controlSize(.small).handCursor()
                }
                .padding(.vertical, 5).padding(.horizontal, 10)
            }
            if let e = reopenError { Text(e).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(.top, 10)
    }

    /// What stopping ends, counted from the live spaces — busy agents named first. SessionControls adds the resume part.
    private var stopEnds: String {
        let spaces = store.spaces.filter { $0.session == session }
        let agents = spaces.reduce(0) { $0 + $1.agents }, panes = spaces.reduce(0) { $0 + $1.panes }
        let busy = spaces.filter { ["working", "done", "blocked"].contains($0.status) }
            .map { "\($0.label) (\(HubParse.word($0.status)))" }
        var t = "Ends \(spaces.count) spaces, \(panes) panes and \(agents) agents."
        if !busy.isEmpty { t += "\nStill active: " + busy.joined(separator: ", ") + "." }
        return t
    }
}
#endif
