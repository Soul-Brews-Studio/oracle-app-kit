import AppKit
import Combine
import GhosttyTerminal
import OracleKit
import SwiftUI

public enum OracleTerminal {
    /// The hub's drawers draw herdr panes with Ghostty from now on (`LiveTerminal.make`).
    @MainActor public static func install() {
        LiveTerminal.make = { spec in AnyView(LivePaneView(spec: spec)) }
    }
}

/// Where typed bytes go. Ghostty calls from its own thread, so the stream sits behind a lock; an observe stream
/// drops what it is given, so a read-only pane never gets keys.
final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: HerdrStream?
    private var resized: (@Sendable (InMemoryTerminalViewport) -> Void)?
    func set(_ s: HerdrStream?) { lock.withLock { stream = s } }
    func send(_ d: Data) { lock.withLock { stream }?.send(d) }
    func onResize(_ f: @escaping @Sendable (InMemoryTerminalViewport) -> Void) { lock.withLock { resized = f } }
    func resize(_ vp: InMemoryTerminalViewport) { lock.withLock { resized }?(vp) }
}

/// One herdr pane in Ghostty, live: `observe` (read-only, at the pane's own size, the font fitted to the drawer)
/// or `control` (the pane takes the view's size, so the agent redraws to fill it, and the keys when you type).
@MainActor final class LivePane: ObservableObject {
    static let background = "0a0a0f", foreground = "dcdcdc"
    static let padX = 8, padY = 6
    static let minFont: Float = 6, maxFont: Float = 20
    /// The reader's size in control mode (⌘+ / ⌘− in the drawer's footer).
    static let fontKey = "hub.liveFont"

    let state: TerminalViewState
    let session: InMemoryTerminalSession
    private let box: StreamBox
    private(set) var spec: LiveTerminal.Spec?
    private var stream: HerdrStream?
    private var generation = 0   // which stream's events count: a stopped one's stragglers do not
    private var takeover = false

    @Published private(set) var problem: String?        // what went wrong, then the command that helps
    @Published private(set) var heldElsewhere = false    // another client controls the pane: offer a takeover
    @Published private(set) var paneGrid: (cols: Int, rows: Int)?   // observe: the pane's own size
    @Published private(set) var grid: (cols: Int, rows: Int)?       // the surface's grid now
    @Published private(set) var applied: Float = 13
    @Published private(set) var lastFrame: Date?        // the footer's clock: set at most once a second
    private(set) var frames = 0
    @Published private(set) var typing = false

    private var settle: DispatchWorkItem?
    private var poll: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0   // streams in a row that ended without a frame
    private var bag: Set<AnyCancellable> = []

    init() {
        let box = StreamBox()
        self.box = box
        let session = InMemoryTerminalSession(
            write: { data in box.send(data) },
            resize: { vp in box.resize(vp) },
            suppressesPixelOnlyResizes: true)
        self.session = session
        state = TerminalViewState(controller: TerminalController(theme: TerminalTheme(light: Self.colors, dark: Self.colors),
                                                                terminalConfiguration: Self.config(font: 13)))
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), resizeThrottleMilliseconds: 60)
        box.onResize { [weak self] vp in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.surfaceResized(vp) } }
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.end() }   // a quitting hub gives a controlled pane back its size
            .store(in: &bag)
        state.$isFocused.sink { [weak self] f in
            guard let self else { return }
            typing = f && spec?.control == true
            LiveTerminal.typing = typing
        }.store(in: &bag)
    }

    static let colors = TerminalConfiguration { b in
        b.withBackground(background); b.withForeground(foreground)
        b.withSelectionBackground("33415c"); b.withCursorColor("64b5f6")
    }

    static func config(font: Float) -> TerminalConfiguration {
        TerminalConfiguration { b in
            b.withFontSize(font)
            b.withFontThicken(true)
            b.withCursorStyle(.block); b.withCursorStyleBlink(false)
            b.withWindowPaddingX(padX); b.withWindowPaddingY(padY)
            b.withBackground(background); b.withForeground(foreground)
        }
    }

    // MARK: - Mode

    func begin(_ next: LiveTerminal.Spec) {
        let samePane = spec?.pane == next.pane && spec?.session == next.session
        spec = next
        problem = nil; heldElsewhere = false
        if !samePane { takeover = false; paneGrid = nil; frames = 0; lastFrame = nil; failures = 0 }
        typing = state.isFocused && next.control; LiveTerminal.typing = typing
        stopStream()
        poll?.cancel(); poll = nil
        if next.control {
            let want = Float(UserDefaults.standard.object(forKey: Self.fontKey) as? Double ?? 14)
            setFont(want)
            scheduleSettle()   // control starts once the grid has settled at the reader's font
        } else {
            fit()
            poll = Task { [weak self] in
                var first = true
                while !Task.isCancelled {
                    await self?.readPaneSize(force: first)
                    first = false
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    func end() {
        spec = nil
        poll?.cancel(); poll = nil; retry?.cancel(); retry = nil
        settle?.cancel(); settle = nil
        stopStream()
        if LiveTerminal.typing { LiveTerminal.typing = false }
    }

    func takeOver() {
        guard let spec else { return }
        takeover = true
        begin(LiveTerminal.Spec(session: spec.session, pane: spec.pane, control: true))
    }

    func changeFont(by step: Float) {
        guard spec?.control == true else { return }
        let f = min(Self.maxFont + 8, max(Self.minFont, applied + step))
        UserDefaults.standard.set(Double(f), forKey: Self.fontKey)
        setFont(f)
    }

    // MARK: - Streams

    private func start(_ mode: HerdrStreamMode, cols: Int, rows: Int) {
        guard let spec else { return }
        stopStream()
        generation += 1
        let mine = generation
        let s = HerdrStream(session: spec.session, pane: spec.pane, mode: mode, cols: cols, rows: rows,
                            takeover: mode == .control && takeover) { [weak self] e in
            guard let self, mine == self.generation, self.stream != nil else { return }   // a stopped stream's late events
            self.handle(e)
        }
        stream = s
        box.set(s)
        s.start()
    }

    private func stopStream() {
        stream?.stop()
        stream = nil
        box.set(nil)
    }

    private func handle(_ e: HerdrStreamEvent) {
        switch e {
        case .frame(let f):
            session.receive(f.bytes)
            frames += 1; failures = 0
            let now = Date()
            if lastFrame.map({ now.timeIntervalSince($0) >= 1 }) ?? true { lastFrame = now }
            if problem != nil, !heldElsewhere { problem = nil }
        case .closed(let reason):
            if HerdrStreamWire.isHeldElsewhere(reason) || HerdrStreamWire.wasTakenOver(reason) {
                heldElsewhere = true
                problem = HerdrStreamWire.wasTakenOver(reason)
                    ? "another client took \(spec?.pane ?? "the pane") over — reading it instead"
                    : "another client controls \(spec?.pane ?? "the pane") (Heeler, or herdr terminal attach) — reading it instead"
                startObserveFallback()
            } else if reason != "detached" {
                problem = reason
            }
        case .ended(let status, let err):
            let s = stream
            stream = nil; box.set(nil)
            guard spec != nil else { return }
            if problem == nil {
                problem = "the herdr stream ended (\(status))" + (err.isEmpty ? "" : ": " + err.prefix(160))
                    + "\n  " + (s?.command ?? "herdr pane list")
            }
            failures += 1
            retry?.cancel()
            guard failures < 5 else { return }   // the problem line stays, with its command
            retry = Task { [weak self] in   // herdr restarted, or the pane went: try again, quietly
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.stream == nil, let spec = self.spec else { return }
                self.begin(spec)
            }
        }
    }

    /// Control was refused: read the pane, and keep offering the takeover.
    private func startObserveFallback() {
        guard let spec, spec.control else { return }
        stopStream()
        Task { [weak self] in await self?.readPaneSize(force: true) }   // refits, then observes
    }

    // MARK: - Sizes

    private func surfaceResized(_ vp: InMemoryTerminalViewport) {
        let g = (cols: Int(vp.columns), rows: Int(vp.rows))
        guard g.cols > 0, g.rows > 0 else { return }
        let changed = grid.map { $0 != g } ?? true
        grid = g
        guard let spec else { return }
        if spec.control && !heldElsewhere {
            if changed || stream == nil { scheduleSettle() }
        } else {
            fit()
            if changed { scheduleRefresh() }
        }
    }

    /// Control: a grid that stops changing for a moment goes to herdr (start, or resize the running stream).
    private func scheduleSettle() {
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let spec = self.spec, spec.control, !self.heldElsewhere || self.takeover, let g = self.grid else { return }
                if let s = self.stream, s.mode == .control { s.resize(cols: g.cols, rows: g.rows) }
                else { self.start(.control, cols: g.cols, rows: g.rows) }
            }
        }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    /// Observe: once the grid has settled, a new stream, whose first frame redraws the whole pane.
    private func scheduleRefresh() {
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let spec = self.spec, !spec.control || self.heldElsewhere, let g = self.paneGrid, self.stream != nil else { return }
                self.start(.observe, cols: g.cols, rows: g.rows)
            }
        }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// Observe: the pane's own size, from herdr's layout. A new size refits the font and restarts the stream.
    private func readPaneSize(force: Bool = false) async {
        guard let spec else { return }
        var args = ["pane", "layout", "--pane", spec.pane]
        if let s = spec.session { args = ["--session", s] + args }
        guard let out = await Shell.run("herdr", args, timeout: 4),
              let g = Self.paneGrid(layout: out, pane: spec.pane) else {
            if paneGrid == nil { problem = "can't read the size of \(spec.pane)\n  herdr \(args.joined(separator: " "))" }
            return
        }
        guard self.spec == spec else { return }
        if force || paneGrid.map({ $0 != g }) ?? true {
            paneGrid = g
            if problem?.hasPrefix("can't read the size") == true { problem = nil }
            fit()
            if !spec.control || heldElsewhere { start(.observe, cols: g.cols, rows: g.rows) }
        } else if stream == nil, !spec.control {
            start(.observe, cols: g.cols, rows: g.rows)
        }
    }

    /// `herdr pane layout` → the pane's rect, which is the size of its terminal.
    nonisolated static func paneGrid(layout: String, pane: String) -> (cols: Int, rows: Int)? {
        guard let d = layout.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let panes = ((o["result"] as? [String: Any])?["layout"] as? [String: Any])?["panes"] as? [[String: Any]],
              let p = panes.first(where: { $0["pane_id"] as? String == pane }),
              let r = p["rect"] as? [String: Any], let w = r["width"] as? Int, let h = r["height"] as? Int, w > 0, h > 0
        else { return nil }
        return (w, h)
    }

    /// Observe: the largest font whose grid still holds the pane's (herdr crops a smaller viewer from the top
    /// left, and an agent's input box is in its bottom rows). A grid scales as 1/font, so the font that fits is
    /// this one times the room the grid has: no pixel sizes (a window on a 1x display beside a 2x one made
    /// those wrong: 12.8 pt where 20 fitted), one or two steps, each checked on the grid that comes back.
    private func fit() {
        guard let spec, !spec.control || heldElsewhere, let pg = paneGrid, let g = grid else { return }
        let room = min(Double(g.cols) / Double(pg.cols), Double(g.rows) / Double(pg.rows))
        let f = (Double(applied) * room * 0.99 * 4).rounded(.down) / 4
        let target = Float(max(Double(Self.minFont), min(Double(Self.maxFont), f)))
        if abs(target - applied) >= 0.25 { setFont(target) }
    }

    private func setFont(_ f: Float) {
        applied = f
        state.controller.setTerminalConfiguration(Self.config(font: f))
    }
}

/// The drawer's live screen: Ghostty, with a footer that says what it is doing and what helps.
struct LivePaneView: View {
    let spec: LiveTerminal.Spec
    @StateObject private var pane = LivePane()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurfaceView(context: pane.state)
                .terminalFocused($focused)
                .background(Color(red: 0.04, green: 0.04, blue: 0.06))
            .overlay(alignment: .topTrailing) {
                if pane.typing {
                    Text("typing into \(spec.pane) · ⌘⎋ stop")
                        .font(.caption.monospaced().weight(.semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(red: 0.39, green: 0.71, blue: 0.96)))
                        .padding(8)
                }
            }
            footer
        }
        .onAppear { pane.begin(spec); LiveTerminal.focus = { focused = true } }
        .onChange(of: spec) { _, s in pane.begin(s) }
        .onDisappear { pane.end(); LiveTerminal.focus = nil }
        .background(StopTypingKey(active: pane.typing) { focused = false; NSApp.keyWindow?.makeFirstResponder(nil) })
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = pane.problem {
                Text(p).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(summary).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                if pane.heldElsewhere {
                    Button("Take over") { pane.takeOver() }.buttonStyle(.borderless).font(.caption.weight(.semibold)).handCursorIfAvailable()
                        .help("herdr --session \(spec.session ?? "default") terminal session control \(spec.pane) --takeover — the other client is closed")
                }
                if spec.control {
                    Button("A−") { pane.changeFont(by: -1) }.buttonStyle(.borderless).font(.caption.weight(.semibold))
                        .help("Smaller text: the pane gets more columns")
                    Button("A+") { pane.changeFont(by: 1) }.buttonStyle(.borderless).font(.caption.weight(.semibold))
                        .help("Bigger text: the pane gets fewer columns")
                    if !pane.typing {
                        Button("Type") { focused = true }.buttonStyle(.borderless).font(.caption.weight(.semibold))
                            .help("Keys go to the pane (i, or click it); ⌘⎋ gives them back")
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var summary: String {
        let mode = spec.control && !pane.heldElsewhere ? "control" : "observe"
        var parts = ["live · \(mode)"]
        if let g = pane.grid { parts.append("\(g.cols)×\(g.rows)") }
        if mode == "observe", let p = pane.paneGrid { parts.append("pane \(p.cols)×\(p.rows)") }
        parts.append(String(format: "%.1f pt", Double(pane.applied)))
        if let t = pane.lastFrame { parts.append("frame \(t.formatted(date: .omitted, time: .standard))") }
        else { parts.append("waiting for the first frame") }
        if mode == "control" { parts.append("the pane keeps this size until you leave full screen") }
        return parts.joined(separator: " · ")
    }
}

/// ⌘⎋ while typing: the keys go back to the page.
private struct StopTypingKey: NSViewRepresentable {
    let active: Bool
    let stop: () -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.stop = stop
        context.coordinator.set(active)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.set(false) }
    @MainActor final class Coordinator {
        var stop: () -> Void = {}
        private var monitor: Any?
        func set(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    guard e.keyCode == 53, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return e }
                    self?.stop(); return nil
                }
            } else if !on, let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}

private extension View {
    /// The pointing hand, as OracleKit's buttons have it.
    func handCursorIfAvailable() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
