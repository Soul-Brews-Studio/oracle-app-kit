import SwiftUI
import os
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Message the oracle's agents from the app — `maw herdr hey --session <s> <pane> <message>`, which runs
/// `herdr --session <s> agent prompt <pane> <message>`. ARRA Chat's composer: one field, a target picker, send.
struct HeyComposer: View {
    @ObservedObject var store: OracleStore
    @Binding var text: String
    var focus: String? = nil       // the pane open in the 3rd column, if any: messages go there
    @State private var target: String?
    @State private var note: String?
    @State private var sending = false
    var body: some View {
        let c = store.config
        let twins = WorkParse.twins(store.activity)
        let panes = store.activity.filter { twins[$0.place] == nil }
            .sorted { (WorkFormat.rank($0.status), $0.place) < (WorkFormat.rank($1.status), $1.place) }
        let chosen = panes.first { $0.place == focus } ?? panes.first { $0.place == target } ?? panes.first { $0.cwd == c.localPath && $0.status == "idle" } ?? panes.first
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(c.name) — maw herdr hey", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.custom("Avenir Next", size: 15)).lineLimit(1...6)
                    .onSubmit { send(to: chosen) }
                Button { send(to: chosen) } label: {
                    Image(systemName: sending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24)).foregroundStyle(canSend(chosen) ? c.color : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain).handCursor().disabled(!canSend(chosen))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            HStack(spacing: 10) {
                Menu {
                    ForEach(panes, id: \.place) { p in
                        Button { target = p.place } label: {
                            Text("\(WorkFormat.pane(p.place, home: WorkFormat.homeSession(store.activity))) · \(p.status) · \(String(p.title.prefix(40)))")
                        }
                    }
                } label: {
                    Text(chosen.map { "to \(WorkFormat.pane($0.place, home: WorkFormat.homeSession(store.activity))) · \($0.status)" } ?? "no agent pane open")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(panes.isEmpty)
                if let note { Text(note).font(.caption).foregroundStyle(note.hasPrefix("sent") ? Color.secondary : Color.orange).textSelection(.enabled).lineLimit(2) }
                Spacer()
                Text("⌘↩ to send").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
        .background(.bar)
    }

    private func canSend(_ p: OracleSnapshot.Activity?) -> Bool {
        p != nil && !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func send(to p: OracleSnapshot.Activity?) {
        guard let p, canSend(p) else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true; note = nil
        Task {
            let ok = await store.hey(place: p.place, message: message)
            sending = false
            if ok { text = ""; note = "sent to \(p.place)" }
            else { note = "not sent — run: " + OracleStore.heyCommand(place: p.place, message: message) }
        }
    }
}
#endif


#if os(macOS)
/// The real terminal of one herdr pane, read live (`herdr --session S pane read P`, every second), newest at the bottom.
/// Read-only: typing goes through the message box under the Work column, which targets this pane while it is open.
struct TerminalColumn: View {
    /// The widest row in terminal cells (a CJK or emoji glyph takes two), so the font can be sized to fit it.
    static func columns(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { row in
            row.unicodeScalars.reduce(0) { n, u in n + ((0x1100...0x115F).contains(u.value) || (0x2E80...0xA4CF).contains(u.value) || (0xAC00...0xD7A3).contains(u.value)
                || (0xF900...0xFAFF).contains(u.value) || (0xFE30...0xFE4F).contains(u.value) || (0xFF00...0xFF60).contains(u.value) || (0x1F300...0x1FAFF).contains(u.value) ? 2
                : (u.properties.generalCategory == .nonspacingMark ? 0 : 1)) }
        }.max() ?? 0
    }
    @ObservedObject var store: OracleStore
    let place: String
    var active = true
    var activate: () -> Void = {}
    let close: () -> Void
    var full = false
    var toggleFull: (() -> Void)? = nil
    @AppStorage(LiveTerminal.enabledKey) private var live = true   // ☑ the pane live (when the app links a terminal) · ☐ its text
    var body: some View {
        let act = store.activity.first { $0.place == place }
        let shell = store.spaces.flatMap(\.panes).first { $0.place == place }   // a plain shell pane: no agent record
        let home = WorkFormat.homeSession(store.activity)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(WorkFormat.dot(act?.status ?? shell?.status ?? "", store.config.color)).frame(width: 8, height: 8)
                Text(WorkFormat.pane(place, home: home)).font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(active ? store.config.color : Color.primary)
                Text(act?.title ?? shell.map { ($0.agent ?? "shell") + " · " + (($0.cwd as NSString).lastPathComponent) } ?? "")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if LiveTerminal.make != nil {
                    Toggle("Live", isOn: $live).toggleStyle(.checkbox).font(.caption).handCursor()
                        .help("Ticked: the pane itself, live; click it (or Type) to type into it. Esc then goes to the agent; ⌘⎋ gives the pane back and closes it (in full screen: leaves full screen). Unticked: its text, read every second.")
                }
                Button { store.openInWezTerm(place: place) } label: { Label("WezTerm", systemImage: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless).font(.caption.weight(.medium)).labelStyle(.titleAndIcon).handCursor()
                    .help("Open this pane in its WezTerm window, focused and in front (the drawer lets go of it first)")
                if let toggleFull {
                    Button(action: toggleFull) {
                        Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor()
                    .help(full ? "Back to the page (esc)" : "Full screen: the pane over the whole page (esc comes back)")
                }
                if let item = store.work.first(where: { $0.panes.contains { $0.place == place } }) {
                    Button("bring here") { store.bringToMain(item); close() }.buttonStyle(.borderless).font(.caption.weight(.medium)).handCursor()
                        .help("Bring this pane's WezTerm window to the main display")
                }
                Button(action: close) { Image(systemName: "xmark").font(.callout.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help(active ? "Close (esc)" : "Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(active ? store.config.color.opacity(0.12) : Color.clear)
            .contentShape(Rectangle()).onTapGesture(perform: activate)   // click a header: that pane becomes the active one
            Divider()
            if live, let make = LiveTerminal.make {
                // the pane itself, live (herdr's stream in Ghostty): read-only until you click it, press Type or i
                make(LiveTerminal.Spec.place(place, typeToControl: true)).id(place)
            } else {
                PaneScreen(place: place)
            }
        }
    }
}

/// One herdr pane drawn as its screen, read live every second: the oracle apps' drawer and the hub's space drawer.
/// `place` = "<session>:<pane>" or a pane id in the default session.
struct PaneScreen: View {
    let place: String
    @State private var text = ""
    @State private var read: Date?
    @State private var failed = false
    /// The largest drawer font: an agent writes its rows at its pane's width (~110 columns here), so a wide drawer
    /// is filled by a bigger font rather than by longer rows, which the pane never has.
    static let maxFont: CGFloat = 20
    @AppStorage("oracle.drawerFit") private var fit = true   // ☑ fit the drawer · ☐ bigger font, scroll (Nat's choice)
    var body: some View {
        VStack(spacing: 0) {
            let shown = failed && text.isEmpty ? "can't read \(place) — is herdr running?\n  herdr pane list" : text
            Group { if fit {
            GeometryReader { geo in
                // a terminal screen, not a scroll view (Nat: "make the right fit, no scroll"): the font shrinks until the
                // widest row fits the drawer (a monospaced cell is ~0.6 of the font size), and only the newest rows that
                // fit the height are shown — widen or heighten the drawer to see more
                let all = shown.split(separator: "\n", omittingEmptySubsequences: false)
                let recent = all.suffix(160).joined(separator: "\n")
                let size = min(Self.maxFont, max(7, (geo.size.width - 26) / (CGFloat(max(TerminalColumn.columns(recent), 40)) * 0.602)))
                let rows = max(4, Int((geo.size.height - 24) / (size * 1.22)))
                Text(all.suffix(rows).joined(separator: "\n"))
                    .font(.system(size: size, design: .monospaced)).foregroundStyle(Color(white: 0.86))
                    .fixedSize(horizontal: true, vertical: false)   // never re-wrap: tables and boxes keep their shape
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(12)
                    .clipped()
            }
            } else {
                // bigger font, scroll both ways; opens at the newest row and the leftmost column. At least 13 pt, and
                // larger when the pane's rows are narrower than the drawer, so a wide drawer is filled, not half empty
                GeometryReader { geo in
                let size = max(13, min(Self.maxFont, (geo.size.width - 26) / (CGFloat(max(TerminalColumn.columns(shown), 40)) * 0.602)))
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(shown).font(.system(size: size, design: .monospaced)).foregroundStyle(Color(white: 0.86))
                                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(12)
                            Color.clear.frame(width: 1, height: 1).id("end")
                        }
                    }
                    .onChange(of: text) { proxy.scrollTo("end", anchor: .bottomLeading) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottomLeading) }
                }
                }
            } }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
            HStack {
                Text(read.map { "live · every 1 s · read \($0.formatted(date: .omitted, time: .standard))" } ?? "reading…")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Toggle("Fit", isOn: $fit).toggleStyle(.checkbox).font(.caption).handCursor()
                    .help("Ticked: shrink the text to fit the drawer, no scrolling. Unticked: bigger font, scroll.")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .task(id: place) {
            text = ""; failed = false
            let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
            let args = parts.count == 2 ? ["--session", parts[0], "pane", "read", parts[1], "--source", "recent", "--lines", "400"]   // the rows as the terminal draws them
                                        : ["pane", "read", place, "--source", "recent", "--lines", "400"]   // the rows as the terminal draws them
            while !Task.isCancelled {
                if let out = await Shell.run("herdr", args, timeout: 4) {
                    let clean = out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    if clean != text { text = clean }
                    read = Date(); failed = false
                } else { failed = true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
#endif

#if os(macOS)
let fitLog = Logger(subsystem: "co.laris.oracle.kit", category: "fit")

/// Grows or shrinks the app window to the right (or left, at the screen edge) so a drawer adds room instead of
/// taking it from the Work column.
@MainActor enum Drawer {
    /// Each window's frame before a fit: the next double-click goes back to it.
    private static var beforeFit: [Int: NSRect] = [:]

    /// The sidebar's width, measured from the window's split view (272 when there is none).
    static func sidebarWidth(in w: NSWindow) -> CGFloat {
        guard let content = w.contentView, let s = splitView(in: content), let first = s.arrangedSubviews.first else { return 272 }
        return s.isSubviewCollapsed(first) ? 0 : first.frame.width
    }

    /// The window width that holds the sidebar and a page of `page` points, plus the scroll bar.
    static func fitWidth(page: CGFloat, window w: NSWindow) -> CGFloat {
        let content = (sidebarWidth(in: w) + page + 16).rounded()
        return w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content, height: 100)).width
    }

    /// The window as wide as its sidebar and a page of `page` points (oracle-<name>://fit); its left edge stays.
    static func fit(page: CGFloat) {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let width = fitWidth(page: page, window: w)
        guard w.frame.width > width + 1 else { return }
        beforeFit[w.windowNumber] = w.frame
        var f = w.frame; f.size.width = width
        w.setFrame(f, display: true, animate: true)
        fitLog.notice("fit \(Int(page), privacy: .public): \(Int(beforeFit[w.windowNumber]?.width ?? 0), privacy: .public) → \(Int(w.frame.width), privacy: .public)")
    }

    /// Double-click to fit, and again to go back (Nat: "too wide? double click to fit?", "when double click back"):
    /// wider than the page → fit, keeping the frame it had; fitted → that frame again (or the screen's width).
    static func toggleFit(page: CGFloat, window w: NSWindow) {
        let width = fitWidth(page: page, window: w)
        if abs(w.frame.width - width) <= 2 {
            let back = beforeFit.removeValue(forKey: w.windowNumber) ?? w.screen?.visibleFrame ?? w.frame
            w.setFrame(back, display: true, animate: true)
            fitLog.notice("back \(Int(page), privacy: .public): \(Int(width), privacy: .public) → \(Int(back.width), privacy: .public)")
        } else if w.frame.width > width + 1 {
            fit(page: page)
        } else if let v = w.screen?.visibleFrame {   // narrower than the page: as wide as the screen, as macOS's zoom would
            beforeFit[w.windowNumber] = w.frame
            var f = w.frame; f.origin.x = v.minX; f.size.width = v.width
            w.setFrame(f, display: true, animate: true)
        }
    }

    private static func splitView(in v: NSView) -> NSSplitView? {
        if let s = v as? NSSplitView, s.isVertical { return s }
        for sub in v.subviews { if let s = splitView(in: sub) { return s } }
        return nil
    }

    /// `leftward`: the window's right edge stays put and it grows to the left — what a drag on the drawer's left edge wants
    static func grow(by dx: CGFloat, leftward: Bool = false, animate: Bool = true) {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        var f = w.frame
        f.size.width += dx
        if leftward { f.origin.x -= dx }
        if let vis = w.screen?.visibleFrame {
            if f.width > vis.width { f.size.width = vis.width }
            if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }   // no room on the right: open toward the left
            if f.minX < vis.minX { f.origin.x = vis.minX }
        }
        w.setFrame(f, display: true, animate: animate)
    }
}

/// The drawer's left edge: drag it to trade width with the Work column (Nat: "middle more narrow, the right edge stays,
/// so the drawer gets wider"). The window does not move; Work keeps at least 420 px.
struct DrawerHandle: View {
    static let width: CGFloat = 7
    @Binding var width: Double
    /// how wide the drawer may get: the window's content minus the sidebar (~260) and Work's 420 minimum
    private var maxWidth: CGFloat {
        let win = (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.contentView?.bounds.width ?? 1400
        return max(360, win - 260 - 420 - Self.width)
    }
    @State private var start: Double?
    @State private var inside = false
    var body: some View {
        ZStack {
            Color.primary.opacity(inside || start != nil ? 0.12 : 0.04)
            Capsule().fill(Color.primary.opacity(0.35)).frame(width: 2, height: 34)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .onHover { h in
            guard h != inside else { return }
            inside = h
            if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if inside { inside = false; NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                let base = start ?? width; if start == nil { start = width }
                let next = min(Double(maxWidth), max(360, base - g.translation.width))
                if abs(next - width) >= 1 { width = next }
            }
            .onEnded { _ in start = nil })
        .help("Drag to make the terminal wider or narrower")
    }
}
#endif
