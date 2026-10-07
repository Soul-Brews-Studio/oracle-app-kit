import Foundation

/// The hub's debug log: what the embedder is doing and how fast. Model parts loading (compiled or from the cache),
/// repos read, every embed call (texts, tokens, milliseconds, where it ran), searches, errors.
/// Shown live on the search page and appended to ~/Library/Logs/ARRA Oracles/embed.log, so a run can be read back later.
@MainActor
public final class HubLog: ObservableObject {
    public static let shared = HubLog()

    public enum Kind: String, Sendable { case load, read, embed, search, info, error }
    public struct Line: Identifiable, Sendable {
        public let id: Int
        public let at: Date
        public let kind: Kind
        public let text: String
    }

    @Published public private(set) var lines: [Line] = []
    private var next = 0
    private let keep = 500

    public static let file: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ARRA Oracles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("embed.log")
    }()

    private lazy var handle: FileHandle? = Self.open()
    private var written = 0

    /// Opens the log for appending; past 5 MB the old file becomes embed.log.1 (one kept).
    private static func open() -> FileHandle? {
        let fm = FileManager.default, path = file.path
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 5_000_000 {
            let old = file.appendingPathExtension("1")
            try? fm.removeItem(at: old); try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        return try? FileHandle(forWritingTo: file)
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    public static func clock(_ d: Date) -> String { clock.string(from: d) }

    public func add(_ kind: Kind, _ text: String) {
        let line = Line(id: next, at: Date(), kind: kind, text: text)
        next += 1
        lines.append(line)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        written += 1
        if written % 500 == 0 { try? handle?.close(); handle = Self.open() }   // a menu-bar app runs for days: rotate as it goes
        if let h = handle {   // the throwing API: a full disk or a removed file drops the line, never crashes the app
            _ = try? h.seekToEnd()   // another copy of the hub may have appended meanwhile
            try? h.write(contentsOf: Data("\(Self.clock(line.at)) \(kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(text)\n".utf8))
        }
    }

    /// Everything on screen, as plain text — the Copy button.
    public var text: String {
        lines.map { "\(Self.clock($0.at)) \($0.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.text)" }.joined(separator: "\n")
    }
}

/// What the in-process engine has done, for the live speed readout: totals, rates over the last 10 s,
/// which workers are running their model right now, and the last few calls.
public struct EmbedActivity: Sendable {
    public struct Call: Sendable, Identifiable {
        public let id: Int
        public let at: Date
        public let texts: Int, tokens: Int
        public let ms: Double
        public init(id: Int, at: Date, texts: Int, tokens: Int, ms: Double) {
            self.id = id; self.at = at; self.texts = texts; self.tokens = tokens; self.ms = ms
        }
    }
    public var texts = 0, tokens = 0, requests = 0, calls = 0
    public var textsPerSecond = 0.0, tokensPerSecond = 0.0
    public var busy: [Bool] = []
    public var stageSeconds = 0.0, predictSeconds = 0.0, poolSeconds = 0.0
    public var last: [Call] = []            // newest first
    public init() {}
}

/// "1,234" — thousands separators for counts in the log.
func grouped(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }

/// "44.1k" — short counts for rates.
func short(_ x: Double) -> String { x >= 10_000 ? String(format: "%.1fk", x / 1000) : String(Int(x.rounded())) }

/// The Neural Engine meter for the whole Mac (IOReport, no root): utilization % and memory bandwidth, sampled once a
/// second while a view watches. The hub injects the reader — ANEEmbedCore's ANEMonitor — and it stays nil on a Mac
/// whose IOReport has no ANE channels.
@MainActor
public final class ANEMeter: ObservableObject {
    public static let shared = ANEMeter()
    public var reader: (() -> (utilization: Double, gbs: Double)?)?
    @Published public private(set) var utilization: Double?
    @Published public private(set) var gbs: Double?
    @Published public private(set) var history: [Double] = []   // GB/s, one point a second, last 60 s
    private var timer: Timer?
    private var watchers = 0

    public func watch() {
        watchers += 1
        guard timer == nil, reader != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }
    public func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }
    private func sample() {
        guard let r = reader?() else { return }
        utilization = r.utilization; gbs = r.gbs
        history.append(r.gbs); if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}
