import Foundation
import CryptoKit

/// One oracle's own session history on this Mac — its Claude Code sessions and Codex rollouts — read the way relic3
/// reads them (agent-relic-v3 src/ingest/shapes.ts, src/contracts/{roles,tiers}.ts), in new code:
///
///   - the main thread only: a Claude session is `<project>/<uuid>.jsonl`; `subagents/` and workflow agents are
///     skipped (relic's tier `session`). Every Codex rollout is a main thread.
///   - a record belongs to the oracle when its own `cwd` is in the repo (github.com/<org>/<repo>, a sibling-worktree
///     marker stripped) — never the folder name, whose encoding maps both "/" and "." to "-".
///   - the role is what the content block IS, not the envelope that carried it: a `user` record holding only a
///     tool_result is tool traffic. Prose (user, assistant) is embedded; tool_use / tool_result are counted for
///     "with tools", later; thinking and reasoning never.
///   - host text is dropped: <system-reminder> blocks, slash-command wrappers, Codex AGENTS.md preambles, isMeta.
///   - the same text said again (archive copies, "continue") is kept once: distinct texts, by hash.
public enum SessionHistory {
    /// A folder of transcripts — the places relic3 reads: this account's ~/.claude/projects and its archives, other
    /// config homes, another account's projects when this one may read them, Codex rollouts.
    public struct Source: Sendable, Hashable {
        public let kind: String       // claude · codex
        public let path: String
        public let label: String
    }

    public static func sources() -> [Source] {
        let fm = FileManager.default, home = NSHomeDirectory()
        var out: [Source] = []
        let claude = home + "/.claude"
        for name in ((try? fm.contentsOfDirectory(atPath: claude)) ?? []).sorted() where name == "projects" || name.hasPrefix("projects-") {
            out.append(Source(kind: "claude", path: claude + "/" + name, label: "~/.claude/" + name))
        }
        for name in ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted() where name.hasPrefix(".claude-") {
            let p = home + "/" + name + "/projects"
            if fm.fileExists(atPath: p) { out.append(Source(kind: "claude", path: p, label: "~/" + name + "/projects")) }
        }
        for user in ((try? fm.contentsOfDirectory(atPath: "/Users")) ?? []).sorted()
        where !user.hasPrefix(".") && user != "Shared" && "/Users/" + user != home {
            let p = "/Users/" + user + "/.claude/projects"
            if (try? fm.contentsOfDirectory(atPath: p)) != nil { out.append(Source(kind: "claude", path: p, label: user + "'s ~/.claude/projects")) }
        }
        let codex = home + "/.codex/sessions"
        if fm.fileExists(atPath: codex) { out.append(Source(kind: "codex", path: codex, label: "~/.codex/sessions")) }
        return out
    }

    /// "laris-co/pulse" for a cwd anywhere in that repo — a worktree folder under it, or a `pulse.wt-x` sibling.
    /// nil when the path has no forge triple (relic3 repoKeyOf).
    public static func repoKey(_ cwd: String) -> String? {
        let parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"].contains($0) }), parts.count >= i + 3 {
            return parts[i + 1] + "/" + normalizeRepo(parts[i + 2])
        }
        if let w = parts.firstIndex(of: "worktrees"), w > 0, parts[w - 1] == "incubate", parts.count >= w + 3 {
            return parts[w + 1] + "/" + normalizeRepo(parts[w + 2])
        }
        return nil
    }
    static func normalizeRepo(_ s: String) -> String {
        s.replacingOccurrences(of: #"\.(wt-.*|omx-worktrees|worktrees)$"#, with: "", options: .regularExpression)
    }
    static func same(_ a: String?, _ b: String) -> Bool { a?.lowercased() == b.lowercased() }

    // MARK: - files

    /// What the last run knew about one transcript, so the next one reads only what was appended.
    public struct Mark: Codable, Sendable {
        public var size: Int
        public var mtime: Double
        public var offset: Int          // bytes read up to the last complete line
        public var ours: Bool           // its first cwd is in this oracle's repo
        public var session: String
        public var cwd: String
        public var title: String
    }

    struct FileRef: Sendable { let path: String; let kind: String; let source: String; let size: Int; let mtime: Double }

    /// Candidate transcripts for `repo`: Claude main-session files in project folders whose name could be the repo
    /// (a superset — the cwd inside decides), and every Codex rollout.
    static func candidates(repo: String, in sources: [Source]) -> [FileRef] {
        let fm = FileManager.default
        let enc = { (s: String) in s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-").lowercased() }
        let needle = "github-com-" + enc(repo)
        var out: [FileRef] = []
        func add(_ path: String, _ kind: String, _ source: String) {
            guard let a = try? fm.attributesOfItem(atPath: path) else { return }
            out.append(FileRef(path: path, kind: kind, source: source, size: (a[.size] as? Int) ?? 0,
                               mtime: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
        }
        for s in sources {
            if s.kind == "claude" {
                for dir in (try? fm.contentsOfDirectory(atPath: s.path)) ?? [] {
                    let name = dir.lowercased()
                    guard let r = name.range(of: needle), r.upperBound == name.endIndex || name[r.upperBound] == "-" else { continue }
                    let p = s.path + "/" + dir
                    for f in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where f.hasSuffix(".jsonl") { add(p + "/" + f, "claude", s.label) }
                }
            } else if let walk = fm.enumerator(atPath: s.path) {
                while let f = walk.nextObject() as? String {
                    if f.hasSuffix(".jsonl") { add(s.path + "/" + f, "codex", s.label) }
                }
            }
        }
        return out
    }

    // MARK: - parsing

    /// One thing said in a session, cleaned: who said it, when, and where it came from.
    struct Said: Sendable { let role: String; let text: String; let ts: String; let session: String; let cwd: String; let path: String }

    /// Counts the page shows after a scan, before anything is embedded.
    public struct Counts: Codable, Sendable {
        public var files = 0, filesOurs = 0, bytes = 0, lines = 0, bad = 0, sessions = 0
        public var prose = 0, short = 0, toolUse = 0, toolResult = 0, thinking = 0, system = 0, host = 0
        public var distinct = 0, chunks = 0, newChunks = 0
        public var first = "", last = ""
        public init() {}
        mutating func add(_ o: Counts) {
            files += o.files; filesOurs += o.filesOurs; bytes += o.bytes; lines += o.lines; bad += o.bad; sessions += o.sessions
            prose += o.prose; short += o.short; toolUse += o.toolUse; toolResult += o.toolResult; thinking += o.thinking
            system += o.system; host += o.host
            if !o.first.isEmpty, first.isEmpty || o.first < first { first = o.first }
            if o.last > last { last = o.last }
        }
    }

    /// Reads `file` from `mark.offset` (all of it when the file is new or shorter than before). Returns what was said
    /// in `repo`, the counts, and the new mark. Only complete lines are read; a line still being written waits.
    static func read(_ file: FileRef, repo: String, mark: Mark?) -> (said: [Said], counts: Counts, mark: Mark) {
        var c = Counts(); c.files = 1
        var m = mark ?? Mark(size: 0, mtime: 0, offset: 0, ours: false, session: "", cwd: "", title: "")
        if mark != nil, file.size < m.offset { m = Mark(size: 0, mtime: 0, offset: 0, ours: false, session: "", cwd: "", title: "") }   // rewritten
        let fresh = m.offset == 0
        guard let h = FileHandle(forReadingAtPath: file.path) else { return ([], c, m) }
        defer { try? h.close() }
        // a file we already know is not ours: nothing to read
        if !fresh && !m.ours { m.size = file.size; m.mtime = file.mtime; return ([], c, m) }
        if fresh {   // whose is it? the first cwd is near the top: read 64 KB, not a 200 MB rollout that is someone else's
            let head = (try? h.read(upToCount: 65_536)) ?? Data()
            var probe = m
            for raw in head.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let rec = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
                _ = file.kind == "codex" ? codex(rec, &probe) : claude(rec, &probe)
                if !probe.cwd.isEmpty { break }
            }
            if !probe.cwd.isEmpty, !same(repoKey(probe.cwd), repo) {
                m.ours = false; m.cwd = probe.cwd; m.session = probe.session
                m.offset = file.size; m.size = file.size; m.mtime = file.mtime
                return ([], c, m)
            }
        }
        try? h.seek(toOffset: UInt64(m.offset))
        guard let data = try? h.readToEnd(), !data.isEmpty, let lastNL = data.lastIndex(of: 0x0A) else {
            m.size = file.size; m.mtime = file.mtime; return ([], c, m)
        }
        let body = data[data.startIndex...lastNL]
        c.bytes = body.count
        var said: [Said] = []
        var decided = !fresh
        for raw in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
            c.lines += 1
            // most lines are tool traffic, thinking or UI bookkeeping: count them from their bytes, parse only prose
            if decided, let kind = quick(raw) {
                switch kind {
                case "tool_result": c.toolResult += 1
                case "tool_use": c.toolUse += 1
                case "thinking": c.thinking += 1
                default: break
                }
                continue
            }
            guard let rec = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { c.bad += 1; continue }
            let out = file.kind == "codex" ? codex(rec, &m) : claude(rec, &m)
            if !decided, !m.cwd.isEmpty {   // the session's first cwd decides whose it is
                decided = true
                m.ours = same(repoKey(m.cwd), repo)
                if !m.ours { break }
            }
            guard m.ours || !decided else { continue }
            switch out.role {
            case "user", "assistant":
                if out.host { c.host += 1; continue }
                let t = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count < minChars { c.short += 1; continue }
                c.prose += 1
                if !out.ts.isEmpty { if c.first.isEmpty || out.ts < c.first { c.first = out.ts }; if out.ts > c.last { c.last = out.ts } }
                said.append(Said(role: out.role, text: t, ts: out.ts, session: m.session, cwd: out.cwd ?? m.cwd, path: file.path))
            case "tool_use": c.toolUse += 1
            case "tool_result": c.toolResult += 1
            case "thinking", "reasoning": c.thinking += 1
            case "system": c.system += 1
            default: break
            }
        }
        if !decided { m.ours = false }   // no cwd in the whole file: not attributable
        if m.ours { c.filesOurs = 1; if fresh { c.sessions = 1 } } else { said = []; c = Counts(); c.files = 1 }
        m.offset = m.offset + body.count
        m.size = file.size; m.mtime = file.mtime
        // records outside the repo (the session moved): kept out
        return (said.filter { same(repoKey($0.cwd), repo) || $0.cwd.isEmpty }, c, m)
    }

    struct Line { var role = ""; var text = ""; var ts = ""; var cwd: String?; var host = false }

    // Byte patterns of JSON STRUCTURE, as Claude Code and Codex write it (compact, no spaces). Text a person or a
    // model wrote is a JSON string, where quotes are escaped (\"type\"), so it can never match one of these.
    private static func bytes(_ s: String) -> Data { Data(s.utf8) }
    private static let prose = [#""type":"text""#, #""role":"user","content":""#, #""type":"message""#, #""type":"agent_message""#,
                                #""type":"session_meta""#, #""type":"turn_context""#, #""type":"ai-title""#, #""type":"summary""#].map(bytes)
    private static let toolResultMarks = [#""type":"tool_result""#, #""type":"function_call_output""#, #""type":"custom_tool_call_output""#].map(bytes)
    private static let toolUseMarks = [#""type":"tool_use""#, #""type":"function_call""#, #""type":"custom_tool_call""#].map(bytes)
    private static let thinkingMarks = [#""type":"thinking""#, #""type":"redacted_thinking""#, #""type":"reasoning""#].map(bytes)
    private static let userMark = bytes(#""type":"user""#), assistantMark = bytes(#""type":"assistant""#)

    /// What a line is, from its bytes alone — nil when it may hold prose (a text block, a person's string prompt, a
    /// Codex message, a title) and has to be parsed. Everything else is only counted: on Neo's history that is most
    /// of 3.4 GB (162k tool lines, 54k thinking, and progress / snapshot / attachment bookkeeping).
    static func quick(_ raw: Data) -> String? {
        raw.withUnsafeBytes { (line: UnsafeRawBufferPointer) -> String? in
            func has(_ p: Data) -> Bool {   // memmem over the line's own bytes: fast, and exact on a slice of a bigger Data
                p.withUnsafeBytes { memmem(line.baseAddress, line.count, $0.baseAddress, $0.count) != nil }
            }
            if prose.contains(where: has) { return nil }
            if toolResultMarks.contains(where: has) { return "tool_result" }
            if toolUseMarks.contains(where: has) { return "tool_use" }
            if thinkingMarks.contains(where: has) { return "thinking" }
            // a user or assistant record of a shape not seen here (keys in another order): parse it rather than lose it
            if has(userMark) || has(assistantMark) { return nil }
            return "other"
        }
    }

    /// Shorter than this says little on its own ("ok", "continue", "jus add more") — relic's cut for its counts.
    static let minChars = 40
    /// What gets embedded for one piece: the piece alone, in EmbeddingGemma's document form. The session title stays
    /// out — in every piece it made short lines match on the title alone (measured: "relic3 discord bot" ranked
    /// four one-line replies of one session at 78–79%).
    static func embedText(_ piece: String) -> String { GHIndex.docText(title: "none", body: piece) }

    /// A Claude Code record: type user | assistant | system; the role by what the block is.
    static func claude(_ r: [String: Any], _ m: inout Mark) -> Line {
        var l = Line()
        let type = r["type"] as? String ?? ""
        if let cwd = r["cwd"] as? String, !cwd.isEmpty { l.cwd = cwd; if m.cwd.isEmpty { m.cwd = cwd } }
        if m.session.isEmpty, let s = r["sessionId"] as? String { m.session = s }
        if type == "ai-title", let t = r["aiTitle"] as? String, !t.isEmpty { m.title = t }
        if type == "summary", m.title.isEmpty, let t = r["summary"] as? String { m.title = t }
        guard ["user", "assistant", "system"].contains(type) else { return l }
        l.ts = r["timestamp"] as? String ?? ""
        if type == "system" { l.role = "system"; return l }
        if r["isMeta"] as? Bool == true { l.role = "user"; l.host = true; return l }
        let msg = r["message"] as? [String: Any]
        let content = msg?["content"] ?? r["content"]
        if let s = content as? String {
            l.role = msg?["role"] as? String ?? type; l.text = clean(s)
        } else if let blocks = content as? [[String: Any]] {
            let kinds = Set(blocks.compactMap { $0["type"] as? String })
            if kinds.contains("tool_result") && !kinds.contains("text") { l.role = "tool_result"; return l }
            if kinds.contains("tool_use") && !kinds.contains("text") { l.role = "tool_use"; return l }
            if kinds == ["thinking"] || kinds == ["redacted_thinking"] { l.role = "thinking"; return l }
            l.role = msg?["role"] as? String ?? type
            l.text = clean(blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
        }
        if l.role == "user", l.text.isEmpty { l.host = true }
        if m.title.isEmpty, l.role == "user", !l.text.isEmpty { m.title = String(l.text.prefix(90)) }
        return l
    }

    /// A Codex rollout record: only response_item carries transcript; session_meta / turn_context carry the cwd.
    static func codex(_ r: [String: Any], _ m: inout Mark) -> Line {
        var l = Line()
        let type = r["type"] as? String ?? ""
        l.ts = r["timestamp"] as? String ?? ""
        guard let p = r["payload"] as? [String: Any] else { return l }
        if type == "session_meta" || type == "turn_context" {
            if let cwd = p["cwd"] as? String, !cwd.isEmpty, m.cwd.isEmpty { m.cwd = cwd }
            if type == "session_meta", let id = (p["id"] ?? p["session_id"]) as? String { m.session = id }
            return l
        }
        guard type == "response_item" else { return l }
        switch p["type"] as? String ?? "" {
        case "message", "agent_message":
            let role = (p["type"] as? String) == "agent_message" ? "assistant" : (p["role"] as? String ?? "")
            let text = (p["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
                ?? (p["message"] as? String) ?? ""
            l.role = role
            if role == "developer" { l.role = "user"; l.host = true; return l }   // AGENTS.md and the host's instructions
            l.text = clean(text)
            if role == "user", isHostPreamble(l.text) { l.host = true }
            if m.title.isEmpty, role == "user", !l.host, !l.text.isEmpty { m.title = String(l.text.prefix(90)) }
        case "reasoning": l.role = "reasoning"
        case "function_call", "custom_tool_call": l.role = "tool_use"
        case "function_call_output", "custom_tool_call_output": l.role = "tool_result"
        default: break
        }
        return l
    }

    static func isHostPreamble(_ t: String) -> Bool {
        let s = t.drop { $0.isWhitespace }
        return ["# AGENTS.md instructions", "<recommended_plugins>", "<codex_internal_context", "You have oh-my-codex installed",
                "<INSTRUCTIONS>", "<environment_context>", "<user_instructions>"].contains { s.hasPrefix($0) }
    }

    /// Host text out, the person's words in: <system-reminder> blocks and command stdout dropped, a slash command
    /// kept as "/name args", envelope tags (channel, teammate…) unwrapped.
    static func clean(_ s: String) -> String {
        var t = s
        for tag in ["system-reminder", "local-command-stdout", "local-command-stderr", "local-command-caveat", "command-message"] {
            t = t.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "<command-name>([\\s\\S]*?)</command-name>", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "<command-args>([\\s\\S]*?)</command-args>", with: " $1", options: .regularExpression)
        t = t.replacingOccurrences(of: "</?(channel|teammate-message|hook_prompt)\\b[^>]*>", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - chunks

    /// Pieces of at most `size` characters, cut at a line or a space near the end so words stay whole.
    static func chunks(_ text: String, size: Int = 1600) -> [String] {
        guard text.count > size else { return [text] }
        var out: [String] = [], rest = Substring(text)
        while rest.count > size {
            let window = rest.prefix(size)
            let cut = window.lastIndex(of: "\n").flatMap { window.distance(from: window.startIndex, to: $0) > size / 2 ? $0 : nil }
                ?? window.lastIndex(of: " ").flatMap { window.distance(from: window.startIndex, to: $0) > size / 2 ? $0 : nil }
                ?? window.endIndex
            out.append(String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...].drop { $0.isWhitespace }
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.filter { !$0.isEmpty }
    }

    /// Everything new in this oracle's history since `ledger`, as index entries (no vector yet), the same text once.
    /// `known` are the hashes already in the index. Off the main actor; `progress(done, total)` per file.
    static func collect(repo: String, ledger: [String: Mark], known: Set<String>, stop: StopFlag = StopFlag(),
                        verbose: (@Sendable (String) -> Void)? = nil,
                        progress: @escaping @Sendable (Int, Int) -> Void) -> (docs: [IndexDoc], counts: Counts, ledger: [String: Mark], sources: [Source]) {
        let sources = Self.sources()
        let files = candidates(repo: repo, in: sources)
        var ledger = ledger, counts = Counts(), seen = known, docs: [IndexDoc] = []
        var skippedMs = 0, skippedFiles = 0
        var distinct = Set<String>()
        for (i, f) in files.enumerated() {
            if stop.isSet { break }
            if i % 25 == 0 { progress(i, files.count) }
            let old = ledger[f.path]
            if let old, old.size == f.size, old.mtime == f.mtime {   // untouched since last time
                if old.ours { counts.filesOurs += 1 }
                counts.files += 1; continue
            }
            let tf = Date()
            let r = read(f, repo: repo, mark: old)
            ledger[f.path] = r.mark
            counts.add(r.counts)
            if let verbose {
                let ms = Int(Date().timeIntervalSince(tf) * 1000)
                if r.mark.ours {
                    let c = r.counts
                    verbose("\(f.source) · \((f.path as NSString).lastPathComponent.prefix(13))… · \(String(format: "%.1f", Double(c.bytes) / 1e6)) MB · " +
                            "\(c.lines) lines · \(c.prose) prose · \(c.toolUse + c.toolResult) tools · \(c.thinking) thinking · \(ms) ms" +
                            (r.mark.title.isEmpty ? "" : " · \(r.mark.title.prefix(48))"))
                } else { skippedMs += ms; skippedFiles += 1 }
            }
            let title = r.mark.title
            let resume = f.kind == "codex" ? "cd '\(r.mark.cwd)' && codex resume \(r.mark.session)"
                                           : "cd '\(r.mark.cwd)' && claude --resume \(r.mark.session)"
            for s in r.said {
                let pieces = chunks(s.text)
                for (n, piece) in pieces.enumerated() {
                    let hash = SHA256.hash(data: Data(piece.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                    distinct.insert(hash)
                    guard seen.insert(hash).inserted else { continue }
                    let lines = piece.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    docs.append(IndexDoc(repo: repo, kind: "history", number: n, title: title.isEmpty ? "(untitled session)" : title,
                                         state: s.role, url: resume, updated: s.ts,
                                         snippet: String(lines.prefix(3).joined(separator: " · ").prefix(260)), hash: hash, vec: [],
                                         text: embedText(piece)))
                }
            }
        }
        progress(files.count, files.count)
        if let verbose, skippedFiles > 0 { verbose("\(skippedFiles) transcripts are other repos' — decided from their first 64 KB in \(skippedMs) ms") }
        counts.distinct = distinct.count
        counts.newChunks = docs.count
        return (docs, counts, ledger, sources)
    }
}

/// A Stop that a scan running off the main actor can see between files.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.withLock { value } }
    public func set() { lock.withLock { value = true } }
}
