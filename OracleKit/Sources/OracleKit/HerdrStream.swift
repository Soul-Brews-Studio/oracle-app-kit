import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// One live herdr terminal stream, read the way Heeler (herdr's iOS companion) reads one: raw frames for a real
/// terminal emulator, instead of the pane's text read every second.
///
///     herdr --session S terminal session observe|control <pane> --cols C --rows R [--takeover]
///
/// herdr writes one JSON object per line:
///
///     {"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":6,"full":true,"bytes":"<base64>"}
///     {"type":"terminal.closed","reason":"detached"}
///
/// Measured on m5 (2026-10-08):
/// - `observe` is read-only. Its frames are the pane's own grid, cropped or padded to C×R from the top left, so a
///   viewer with fewer rows than the pane loses the agent's input box: observe at the pane's own size. It ignores
///   stdin, so a new size means a new stream.
/// - `control` sizes the pane's terminal to C×R: the agent redraws to fit. It reads JSON lines on stdin
///   (`terminal.input`, `terminal.resize`, `terminal.release`). One client per terminal: a second one is closed with
///   "… already has an attached client; retry with --takeover" (exit 0), and `--takeover` closes the first one with
///   "terminal attach taken over". A release closes it with "detached".
public struct HerdrStreamFrame: Sendable, Equatable {
    public let seq: Int
    public let width: Int
    public let height: Int
    public let full: Bool
    public let bytes: Data
}

public enum HerdrStreamEvent: Sendable, Equatable {
    case frame(HerdrStreamFrame)
    /// herdr closed the stream; its reason ("detached" after a release).
    case closed(String)
    /// The herdr process ended, after everything it wrote: its exit status and the end of its stderr.
    case ended(Int32, String)
}

public enum HerdrStreamMode: String, Sendable { case observe, control }

/// The protocol, apart from the process: arguments, the messages a control stream reads, and the lines herdr writes.
public enum HerdrStreamWire {
    public static func arguments(session: String?, pane: String, mode: HerdrStreamMode, cols: Int, rows: Int, takeover: Bool = false) -> [String] {
        var a: [String] = []
        if let session, !session.isEmpty { a += ["--session", session] }
        a += ["terminal", "session", mode.rawValue, pane]
        if mode == .control, takeover { a.append("--takeover") }
        a += ["--cols", String(max(1, cols)), "--rows", String(max(1, rows))]
        return a
    }

    public static func input(_ bytes: Data) -> Data { line(["type": "terminal.input", "bytes": bytes.base64EncodedString()]) }
    public static func resize(cols: Int, rows: Int) -> Data { line(["type": "terminal.resize", "cols": max(1, cols), "rows": max(1, rows)]) }
    public static let release = line(["type": "terminal.release"])

    private static func line(_ o: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        d.append(0x0A)
        return d
    }

    /// One line herdr wrote; nil for a line that is not a frame or a close (or not JSON).
    public static func event(_ line: Data) -> HerdrStreamEvent? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return nil }
        switch type {
        case "terminal.frame":
            guard (o["encoding"] as? String ?? "ansi") == "ansi", let b = o["bytes"] as? String, let bytes = Data(base64Encoded: b) else { return nil }
            return .frame(HerdrStreamFrame(seq: o["seq"] as? Int ?? 0, width: o["width"] as? Int ?? 0, height: o["height"] as? Int ?? 0,
                                           full: o["full"] as? Bool ?? false, bytes: bytes))
        case "terminal.closed":
            return .closed(o["reason"] as? String ?? "closed")
        default:
            return nil
        }
    }

    /// herdr's close reason when another client holds the terminal: a takeover is what helps.
    public static func isHeldElsewhere(_ reason: String) -> Bool { reason.contains("already has an attached client") }
    /// herdr's close reason when another client took the terminal from this one.
    public static func wasTakenOver(_ reason: String) -> Bool { reason.contains("taken over") }

    /// Cuts a byte stream into lines; a partial line waits for the rest.
    public struct Lines {
        private var buffer = Data()
        public init() {}
        public mutating func append(_ chunk: Data) -> [Data] {
            buffer.append(chunk)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                if !line.isEmpty { out.append(line) }
                buffer = Data(buffer[buffer.index(after: nl)...])
            }
            return out
        }
    }
}

#if os(macOS)
/// The herdr process of one stream. Events arrive on the main thread, in order; `.ended` comes last, after every
/// line herdr wrote. `send` and `resize` are for a control stream (an observe stream takes no input). `stop`
/// releases a control stream, so herdr gives the pane back its own size, then ends the process.
public final class HerdrStream: @unchecked Sendable {
    public let mode: HerdrStreamMode
    public let arguments: [String]
    private let onEvent: @MainActor @Sendable (HerdrStreamEvent) -> Void
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let writes = DispatchQueue(label: "co.laris.oracle.kit.herdr-stream.in")
    private let reads = DispatchQueue(label: "co.laris.oracle.kit.herdr-stream.out")   // lines and the end, in order
    private let lock = NSLock()
    private var errTail = Data()
    private var stopped = false

    public init(session: String?, pane: String, mode: HerdrStreamMode, cols: Int, rows: Int, takeover: Bool = false,
                onEvent: @escaping @MainActor @Sendable (HerdrStreamEvent) -> Void) {
        self.mode = mode
        self.arguments = HerdrStreamWire.arguments(session: session, pane: pane, mode: mode, cols: cols, rows: rows, takeover: takeover)
        self.onEvent = onEvent
    }

    /// What this stream runs, to paste into a shell.
    public var command: String { "herdr " + arguments.joined(separator: " ") }

    public func start() {
        guard let herdr = Shell.which("herdr") else { deliver(.ended(-1, "herdr not found on PATH")); return }
        process.executableURL = URL(fileURLWithPath: herdr)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.searchPaths.joined(separator: ":")
        process.environment = env
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        // a write after herdr has gone must fail, not raise SIGPIPE and end the app
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let err = stderr.fileHandleForReading
        err.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self, !chunk.isEmpty else { h.readabilityHandler = nil; return }
            self.lock.withLock { self.errTail.append(chunk); if self.errTail.count > 2048 { self.errTail = Data(self.errTail.suffix(2048)) } }
        }
        do { try process.run() } catch {
            let ns = error as NSError
            deliver(.ended(-1, "could not start herdr: \(ns.domain) \(ns.code)")); return
        }
        // stdout is read to its end on one queue, then the exit: so `.ended` follows every frame and close
        let out = stdout.fileHandleForReading, p = process
        reads.async { [weak self] in
            var lines = HerdrStreamWire.Lines()
            while true {
                let chunk = out.availableData   // blocks until data or EOF
                if chunk.isEmpty { break }
                for e in lines.append(chunk).compactMap(HerdrStreamWire.event) { self?.deliver(e) }
            }
            p.waitUntilExit()
            guard let self else { return }
            let tail = self.lock.withLock { String(decoding: self.errTail, as: UTF8.self) }
            self.deliver(.ended(p.terminationStatus, tail.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    /// Keys and pastes for the pane (control only).
    public func send(_ bytes: Data) {
        guard mode == .control, !bytes.isEmpty else { return }
        write(HerdrStreamWire.input(bytes))
    }

    /// The viewer's grid changed (control only: an observe stream is restarted instead).
    public func resize(cols: Int, rows: Int) {
        guard mode == .control else { return }
        write(HerdrStreamWire.resize(cols: cols, rows: rows))
    }

    public func stop() {
        let first = lock.withLock { let f = !stopped; stopped = true; return f }
        guard first else { return }
        let p = process
        guard p.isRunning else { return }
        if mode == .control {
            write(HerdrStreamWire.release)   // herdr gives the pane back its own size and closes with "detached"
            writes.async { [stdin] in try? stdin.fileHandleForWriting.close() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
        } else {
            p.terminate()
        }
    }

    private func write(_ d: Data) {
        writes.async { [stdin] in try? stdin.fileHandleForWriting.write(contentsOf: d) }
    }

    private func deliver(_ e: HerdrStreamEvent) {
        let f = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { f(e) } }
    }

    deinit { if process.isRunning { process.terminate() } }
}
#endif

/// Observe's font fit, apart from the terminal: the largest font whose grid still holds the pane's (herdr crops a
/// smaller viewer from the top left, and an agent's input box is in its bottom rows).
///
/// A grid scales about as 1/font, so the next font is this one times the room the grid has: no pixel sizes (a
/// window on a 1x display beside a 2x one made those wrong: 12.8 pt where 20 fitted). Cells are whole pixels, so
/// that guess can overshoot; every grid that comes back is a measurement, and the font stays between the largest
/// that held the pane and the smallest that did not, so it settles instead of cycling (8.75 → 8.5 → 8.25 → 8.75 …
/// without the bounds, in the review's model).
public enum LiveFit {
    public struct Step: Equatable, Sendable {
        public var font: Float
        public var fits: Float?      // the largest font measured to hold the pane, at this view size
        public var tooBig: Float?    // the smallest font measured not to
        public var cropped: Bool     // not even the smallest font holds it
    }

    public static func next(font: Float, grid: (cols: Int, rows: Int), pane: (cols: Int, rows: Int),
                            fits: Float?, tooBig: Float?, minFont: Float = 6, maxFont: Float = 20) -> Step {
        guard pane.cols > 0, pane.rows > 0, grid.cols > 0, grid.rows > 0 else {
            return Step(font: font, fits: fits, tooBig: tooBig, cropped: false)
        }
        let holds = grid.cols >= pane.cols && grid.rows >= pane.rows
        let fits = holds ? max(fits ?? 0, font) : fits
        let tooBig = holds ? tooBig : min(tooBig ?? .greatestFiniteMagnitude, font)
        let room = min(Double(grid.cols) / Double(pane.cols), Double(grid.rows) / Double(pane.rows))
        var target = min(maxFont, max(minFont, Float((Double(font) * room * 0.99 * 4).rounded(.down) / 4)))
        if let tb = tooBig, target >= tb { target = tb - 0.25 }   // measured too big: stay under it
        if let f = fits, target < f { target = f }               // measured to hold the pane: never below it
        target = max(minFont, target)
        return Step(font: abs(target - font) >= 0.25 ? target : font, fits: fits, tooBig: tooBig,
                    cropped: !holds && font <= minFont)
    }
}

/// A live terminal for one herdr pane, when the app links one: the hub installs Ghostty's (OracleTerminal), as
/// Heeler draws herdr panes. Without it a drawer reads the pane's text every second (`PaneScreen`).
public enum LiveTerminal {
    public struct Spec: Hashable, Sendable {
        public let session: String?
        public let pane: String
        /// false: observe (read-only, the pane keeps its size); true: control (the pane takes this view's size and keys)
        public let control: Bool
        /// Observe until you type: a click, Type or `i` takes control at the view's size, ⌘⎋ gives the pane back
        /// (an oracle app's Work drawer).
        public let typeToControl: Bool
        public init(session: String?, pane: String, control: Bool, typeToControl: Bool = false) {
            self.session = session; self.pane = pane; self.control = control; self.typeToControl = typeToControl
        }

        /// "laris-co:w27:p1" → session laris-co, pane w27:p1; a bare "w27:p1" is the default session's.
        public static func place(_ place: String, typeToControl: Bool) -> Spec {
            let parts = place.split(separator: ":")
            if parts.count >= 3 { return Spec(session: String(parts[0]), pane: parts.dropFirst().joined(separator: ":"), control: false, typeToControl: typeToControl) }
            return Spec(session: nil, pane: place, control: false, typeToControl: typeToControl)
        }
    }
    #if canImport(SwiftUI)
    @MainActor public static var make: ((Spec) -> AnyView)?
    #endif
    /// True while a live terminal in control mode has the keyboard: the page's own keys (j/k, esc…) stand aside.
    @MainActor public static var typing = false
    /// Posted to give the shown live terminal the keyboard (the hub's `i`): it takes it once its control stream
    /// has drawn, so keys typed in between are not lost to the page's shortcuts.
    public static let focusNotification = Notification.Name("co.laris.oracle.liveTerminal.focus")
    /// Posted (object: "<session>:<pane>") to make the live terminal of that pane let go: it stops typing and gives the
    /// pane back its own size, before WezTerm shows it (Nat: "open in wezterm and active").
    public static let releaseNotification = Notification.Name("co.laris.oracle.liveTerminal.release")
    /// Posted (object: "<session>:<pane>") when ⌘⎋ gave a typed-into pane's keys back: the page then does its own esc —
    /// leave full screen first, else close that pane — in the same press. Esc itself stays the agent's interrupt
    /// (Nat, 2026-10-09: "⌘⎋ = app's esc").
    public static let escapeNotification = Notification.Name("co.laris.oracle.liveTerminal.escape")
    /// Whether the drawers draw live terminals; off, they read the pane's text every second (with its history).
    public static let enabledKey = "hub.liveTerminal"
}
