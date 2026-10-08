import AppKit
import Combine
import GhosttyTerminal
import OracleKit
import os
import SwiftUI

/// `log show --predicate 'subsystem == "co.laris.oracle.live"'` (the `log` in Nat's zsh is a function: use /usr/bin/log)
let liveLog = Logger(subsystem: "co.laris.oracle.live", category: "fit")

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
    /// The reader's size in control mode (A− / A+ in the drawer's footer).
    static let fontKey = "hub.liveFont"

    let state: TerminalViewState
    let session: InMemoryTerminalSession
    private let box: StreamBox
    @Published private(set) var spec: LiveTerminal.Spec?   // the mode in use: an observe-until-you-type pane switches itself
    private var stream: HerdrStream?
    private var generation = 0   // which stream's events count: a stopped one's stragglers do not
    private var takeover = false // one-shot: the next control stream takes the pane from its client

    @Published private(set) var problem: String?        // what went wrong, then the command that helps
    @Published private(set) var heldElsewhere = false    // another client controls the pane: offer a takeover
    @Published private(set) var paneGrid: (cols: Int, rows: Int)?   // observe: the pane's own size
    @Published private(set) var grid: (cols: Int, rows: Int)?       // the surface's grid now
    @Published private(set) var applied: Float = 13
    @Published private(set) var lastFrame: Date?        // the footer's clock: set at most once a second
    @Published private(set) var typing = false          // control, and the keyboard is the pane's
    @Published private(set) var cropped = false         // observe: the pane is bigger than the view at the smallest font
    private(set) var frames = 0

    private var wantsTyping = false      // `i` / Type: take the keyboard once the control stream has drawn
    private var controlFrames = 0        // frames of the running control stream
    private var fits: Float?             // observe: the largest font measured to hold the pane, at this view size
    private var tooBig: Float?           // observe: the smallest font measured not to hold it
    private var pixels: (Int, Int)?      // the surface's size: a new one voids `fits` and `tooBig`
    private var settle: DispatchWorkItem?
    private var poll: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var failures = 0             // streams in a row that ended without a frame
    private var gridAt = Date.distantPast  // when the surface last reported a grid
    private var recheck: DispatchWorkItem?
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
        state.$isFocused.sink { [weak self] _ in
            DispatchQueue.main.async {   // after the published value has landed
                guard let self else { return }
                // a click into a pane that observes until you type: that is the request (Nat: "can not typing?")
                if self.state.isFocused, let s = self.spec, s.typeToControl, !s.control, !self.heldElsewhere { self.wantTyping() }
                self.updateTyping()
            }
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
        let wasControl = spec?.control == true
        spec = next
        problem = nil; heldElsewhere = false
        if !samePane { takeover = false; paneGrid = nil; frames = 0; lastFrame = nil; failures = 0; fits = nil; tooBig = nil }
        // a click in the drawer (to select text) is not a request to type: only `i` or Type give the pane the keys
        if next.control != wasControl, !(next.control && wantsTyping) { resignKeyboard() }
        if !next.control { wantsTyping = false }
        updateTyping()
        stopStream()
        poll?.cancel(); poll = nil
        cropped = false
        if next.control {
            controlFrames = 0
            let want = Float(UserDefaults.standard.object(forKey: Self.fontKey) as? Double ?? 14)
            setFont(want)
            scheduleSettle()   // control starts once the grid has settled at the reader's font
        } else {
            fit()
            startPoll()
        }
    }

    func end() {
        spec = nil
        poll?.cancel(); poll = nil; retry?.cancel(); retry = nil
        settle?.cancel(); settle = nil
        wantsTyping = false
        stopStream()
        updateTyping()
    }

    func takeOver() {
        guard let spec else { return }
        takeover = true
        begin(LiveTerminal.Spec(session: spec.session, pane: spec.pane, control: true))
    }

    /// `i` or Type: the pane gets the keyboard as soon as its control stream has drawn (now, if it has). A pane that
    /// observes until you type takes control first, at this view's size.
    func wantTyping() {
        guard let s = spec else { return }
        wantsTyping = true
        if s.typeToControl, !s.control, !heldElsewhere {
            begin(LiveTerminal.Spec(session: s.session, pane: s.pane, control: true, typeToControl: true)); return
        }
        if s.control, !heldElsewhere, controlFrames > 0 { takeKeyboard() }
    }

    /// ⌘⎋: the keys go back to the page; a pane that observes until you type is given back its own size too.
    func stopTyping() {
        wantsTyping = false
        resignKeyboard()
        if let s = spec, s.typeToControl, s.control {
            begin(LiveTerminal.Spec(session: s.session, pane: s.pane, control: false, typeToControl: true))
        }
        updateTyping()
    }

    func changeFont(by step: Float) {
        guard spec?.control == true, !heldElsewhere else { return }
        let f = min(Self.maxFont + 8, max(Self.minFont, applied + step))
        UserDefaults.standard.set(Double(f), forKey: Self.fontKey)
        setFont(f)
    }

    private func takeKeyboard() {
        wantsTyping = false
        state.requestFocus()
    }

    private func resignKeyboard() {
        guard let v = state.attachedPlatformView, let w = v.window, w.firstResponder === v else { return }
        w.makeFirstResponder(nil)
    }

    private func updateTyping() {
        let t = state.isFocused && spec?.control == true && !heldElsewhere
        if typing != t { typing = t }
        LiveTerminal.typing = t
    }

    // MARK: - Streams

    private func start(_ mode: HerdrStreamMode, cols: Int, rows: Int) {
        guard let spec else { return }
        stopStream()
        generation += 1
        let mine = generation
        let take = mode == .control && takeover
        if mode == .control { takeover = false; controlFrames = 0 }
        let s = HerdrStream(session: spec.session, pane: spec.pane, mode: mode, cols: cols, rows: rows,
                            takeover: take) { [weak self] e in
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
            if stream?.mode == .control {
                controlFrames += 1
                if wantsTyping { takeKeyboard() }
            }
        case .closed(let reason):
            if HerdrStreamWire.isHeldElsewhere(reason) || HerdrStreamWire.wasTakenOver(reason) {
                heldElsewhere = true
                wantsTyping = false
                resignKeyboard()
                updateTyping()
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

    /// Control was refused: read the pane at its own size (fitted again), following its size as observe does,
    /// and keep offering the takeover.
    private func startObserveFallback() {
        guard let spec, spec.control else { return }
        stopStream()
        fits = nil; tooBig = nil
        startPoll()
    }

    private func startPoll() {
        poll?.cancel()
        poll = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                await self?.readPaneSize(force: first)
                first = false
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Sizes

    private var observing: Bool { spec.map { !$0.control || heldElsewhere } ?? false }

    private func surfaceResized(_ vp: InMemoryTerminalViewport) {
        let g = (cols: Int(vp.columns), rows: Int(vp.rows))
        guard g.cols > 0, g.rows > 0 else { return }
        let changed = grid.map { $0 != g } ?? true
        grid = g
        gridAt = Date()
        let px = (Int(vp.widthPixels), Int(vp.heightPixels))
        if px.0 > 0, pixels.map({ $0 != px }) ?? true { pixels = px; fits = nil; tooBig = nil }   // a new view size
        guard spec != nil else { return }
        if observing {
            fit()
            if changed { scheduleRefresh() }
        } else if changed || stream == nil {
            scheduleSettle()
        }
    }

    /// Control: a grid that stops changing for a moment goes to herdr (start, or resize the running stream).
    private func scheduleSettle() {
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let spec = self.spec, spec.control, !self.heldElsewhere, let g = self.grid else { return }
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
                guard let self, self.observing, self.stream != nil, let size = self.observeSize else { return }
                self.start(.observe, cols: size.cols, rows: size.rows)
            }
        }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// What observe asks herdr for: the pane's own size, or, when the pane does not fit even at the smallest
    /// font, the top-left part that does (herdr crops; frames wider than the grid would wrap into garbage).
    private var observeSize: (cols: Int, rows: Int)? {
        guard let pg = paneGrid else { return nil }
        guard cropped, let g = grid else { return pg }
        return (min(pg.cols, g.cols), min(pg.rows, g.rows))
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
        guard self.spec == spec, observing else { return }
        if force || paneGrid.map({ $0 != g }) ?? true {
            if paneGrid.map({ $0 != g }) ?? true { fits = nil; tooBig = nil }
            paneGrid = g
            if problem?.hasPrefix("can't read the size") == true { problem = nil }
            fit()
            if let size = observeSize { start(.observe, cols: size.cols, rows: size.rows) }
        } else if stream == nil, let size = observeSize {
            start(.observe, cols: size.cols, rows: size.rows)
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

    /// Observe: the largest font whose grid holds the pane (`LiveFit`: measured bounds, so it settles).
    private func fit() {
        guard observing, let pg = paneGrid, let g = grid else { return }
        let step = LiveFit.next(font: applied, grid: g, pane: pg, fits: fits, tooBig: tooBig,
                                minFont: Self.minFont, maxFont: Self.maxFont)
        liveLog.notice("fit \(self.spec?.pane ?? "", privacy: .public): \(self.applied, privacy: .public) pt grid \(g.cols, privacy: .public)x\(g.rows, privacy: .public) pane \(pg.cols, privacy: .public)x\(pg.rows, privacy: .public) → \(step.font, privacy: .public) pt")
        fits = step.fits; tooBig = step.tooBig
        if cropped != step.cropped { cropped = step.cropped }
        if step.font != applied { setFont(step.font) }
    }

    private func setFont(_ f: Float) {
        applied = f
        state.controller.setTerminalConfiguration(Self.config(font: f))
        guard observing else { return }
        // Cells are whole pixels: a smaller font can draw the same cell (16.75–18 pt all give 11 px at 1x), and then no
        // grid comes back and the fit would stop on a cropped pane (163 columns of 165, measured in Pulse). With the
        // grid still too small and nothing new after 0.3 s, the same grid is the measurement: step down again.
        let at = Date()
        recheck?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.observing, self.gridAt < at, let pg = self.paneGrid, let g = self.grid,
                      g.cols < pg.cols || g.rows < pg.rows else { return }
                self.fit()
            }
        }
        recheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
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
        .onAppear { pane.begin(spec) }
        .onChange(of: spec) { _, s in pane.begin(s) }
        .onDisappear { pane.end() }
        .onReceive(NotificationCenter.default.publisher(for: LiveTerminal.focusNotification)) { _ in pane.wantTyping() }
        .background(StopTypingKey(active: pane.typing) { focused = false; pane.stopTyping() })
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = pane.problem {
                Text(p).font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pane.cropped, pane.spec?.control != true || pane.heldElsewhere {
                Text("\(spec.pane) is bigger than this drawer even at \(Int(LivePane.minFont)) pt: showing its top-left part. Widen the drawer, or f for full screen.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Text(summary).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                if pane.heldElsewhere {
                    Button("Take over") { pane.takeOver() }.buttonStyle(.borderless).font(.caption.weight(.semibold)).handCursor()
                        .help("herdr --session \(spec.session ?? "default") terminal session control \(spec.pane) --takeover — the other client is closed")
                } else if pane.spec?.control != true, spec.typeToControl {
                    Button("Type") { pane.wantTyping() }.buttonStyle(.borderless).font(.caption.weight(.semibold)).handCursor()
                        .help("Click the pane, or Type: it takes this drawer's size and your keys; ⌘⎋ gives it back")
                } else if pane.spec?.control == true {
                    Button("A−") { pane.changeFont(by: -1) }.buttonStyle(.borderless).font(.caption.weight(.semibold)).handCursor()
                        .help("Smaller text: the pane gets more columns")
                    Button("A+") { pane.changeFont(by: 1) }.buttonStyle(.borderless).font(.caption.weight(.semibold)).handCursor()
                        .help("Bigger text: the pane gets fewer columns")
                    if !pane.typing {
                        Button("Type") { pane.wantTyping() }.buttonStyle(.borderless).font(.caption.weight(.semibold)).handCursor()
                            .help("Keys go to the pane (i); ⌘⎋ gives them back")
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var summary: String {
        let mode = pane.spec?.control == true && !pane.heldElsewhere ? "control" : "observe"
        var parts = ["live · \(mode)"]
        if let g = pane.grid { parts.append("\(g.cols)×\(g.rows)") }
        if mode == "observe", let p = pane.paneGrid { parts.append("pane \(p.cols)×\(p.rows)") }
        parts.append(String(format: "%.1f pt", Double(pane.applied)))
        if let t = pane.lastFrame { parts.append("frame \(t.formatted(date: .omitted, time: .standard))") }
        else { parts.append("waiting for the first frame") }
        if mode == "control" { parts.append(spec.typeToControl ? "the pane keeps this size until ⌘⎋" : "the pane keeps this size until you leave full screen") }
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
