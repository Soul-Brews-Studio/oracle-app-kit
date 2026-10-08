#if os(macOS)
import Foundation

extension CompanionServer {
    // MARK: answers

    private func reply<T: Encodable>(_ v: T) -> Response {
        do { return Response(status: 200, body: try CompanionAPI.encoder.encode(v)) }
        catch { return fail(500, "the Mac could not encode its answer (\(error))", fix: "update the Mac app and the phone app to the same version") }
    }

    func fail(_ status: Int, _ error: String, fix: String? = nil, headers: [String: String] = [:]) -> Response {
        let body = (try? CompanionAPI.encoder.encode(CompanionAPI.Problem(error: error, fix: fix))) ?? Data(#"{"error":"internal error"}"#.utf8)
        return Response(status: status, body: body, headers: headers)
    }

    /// A real place from the Work data for a hint that can be pasted (a stand-in only while no pane is listed).
    private func examplePlace() -> String { store?.activity.first?.place ?? "laris-co:w22:p1" }
    /// A real inbox path for a hint (a stand-in while the inbox is empty).
    private func exampleInboxPath() -> String {
        guard let s = store else { return "handoff/2026-10-05_note.md" }
        return Self.inbox(items: s.inbox, unread: [], root: s.config.inboxPath).items.first?.path ?? "handoff/2026-10-05_note.md"
    }

    /// The attached store once it has read its panes, inbox and GitHub at least once. Before that its lists are empty,
    /// not "nothing there", so the phone is told to wait and keeps the pages it has.
    private func readStore() -> OracleStore? {
        guard let s = store, s.lastRefresh != nil || Self.servesUnrefreshed else { return nil }
        return s
    }

    private func stillReading() -> Response {
        guard store != nil else { return starting() }
        return fail(503, "the \(name) app is still reading its panes, inbox and GitHub (it just started)",
                    fix: "try again in a few seconds")
    }

    private func starting() -> Response {
        fail(503, "the \(name) app is still starting — its window has not attached its store yet",
             fix: "try again in a few seconds; if it stays, open the \(name) window on the Mac")
    }

    static let endpoints = [CompanionAPI.Path.hello, CompanionAPI.Path.work, CompanionAPI.Path.screen, CompanionAPI.Path.inbox,
                            CompanionAPI.Path.inboxFile, CompanionAPI.Path.github, CompanionAPI.Path.search, CompanionAPI.Path.status,
                            CompanionAPI.Path.map, CompanionAPI.Path.trace, CompanionAPI.Path.hey]

    private var allowsMessages: Bool { defaults.bool(forKey: Self.messagesKey) }
    /// The identity: the attached store's, else the one the scene published (once it is this app's).
    private var config: OracleConfig? { store?.config ?? (OracleConfig.current.name == name ? OracleConfig.current : nil) }

    /// The bearer token of a request, compared in constant time.
    private func authorized(_ r: MCPServer.Request) -> Bool {
        guard !token.isEmpty, let h = r.headers["authorization"] else { return false }
        let parts = h.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return Self.constantTimeEquals(String(parts[1]).trimmingCharacters(in: .whitespaces), token)
    }

    func route(_ r: MCPServer.Request) async -> Response {
        guard authorized(r) else {
            return fail(401, "unauthorized — the Authorization: Bearer token is missing or wrong",
                        fix: "on the Mac: Settings → Companion, then scan its code again", headers: ["WWW-Authenticate": "Bearer"])
        }
        guard let comps = URLComponents(string: r.path, encodingInvalidCharacters: true), comps.path.hasPrefix("/") else {
            return fail(400, "the request target is not a path: \(Self.clip(r.path, 80))", fix: "GET /v1/hello")
        }
        let path = comps.path
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        func only(_ method: String, _ run: () async -> Response) async -> Response {
            r.method == method ? await run()
                : fail(405, "\(r.method) is not allowed on \(path)", fix: "use  \(method) \(path)", headers: ["Allow": method])
        }
        switch path {
        case CompanionAPI.Path.hello: return await only("GET") { helloAnswer() }
        case CompanionAPI.Path.work: return await only("GET") { workAnswer() }
        case CompanionAPI.Path.screen: return await only("GET") { await screenAnswer(q) }
        case CompanionAPI.Path.inbox: return await only("GET") { inboxAnswer() }
        case CompanionAPI.Path.inboxFile: return await only("GET") { await inboxFileAnswer(q) }
        case CompanionAPI.Path.github: return await only("GET") { githubAnswer() }
        case CompanionAPI.Path.search: return await only("GET") { await searchAnswer(q, r) }
        case CompanionAPI.Path.status: return await only("GET") { await statusAnswer() }
        case CompanionAPI.Path.map: return await only("GET") { await mapAnswer() }
        case CompanionAPI.Path.trace: return await only("GET") { await traceAnswer(q) }
        case CompanionAPI.Path.hey: return await only("POST") { await heyAnswer(r) }
        default:
            return fail(404, "no such endpoint: \(Self.clip(path, 80))", fix: "the endpoints are  " + Self.endpoints.joined(separator: "  "))
        }
    }

    // hello

    private func helloAnswer() -> Response {
        guard let c = config else { return starting() }
        return reply(CompanionAPI.Hello(name: c.name, repoSlug: c.repoSlug, colorHex: c.colorHex, symbol: c.symbol, appVersion: AppVersion.calver,
                                        api: CompanionAPI.version, host: Self.hostName, allowsMessages: allowsMessages))
    }

    /// The Mac's name — gethostname, not ProcessInfo.hostName, which can wait on a reverse DNS lookup.
    nonisolated static var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "Mac" }
        let h = String(cString: buf)
        return h.hasSuffix(".local") ? String(h.dropLast(6)) : h
    }

    // work

    private func workAnswer() -> Response {
        guard let s = readStore() else { return stillReading() }
        return reply(Self.work(items: s.work, activity: s.activity, problems: s.problems, refreshed: s.lastRefresh, spaces: s.spaces))
    }

    nonisolated static func work(items: [WorkItem], activity: [OracleSnapshot.Activity], problems: [String], refreshed: Date?,
                                 spaces: [HerdrSpace] = []) -> CompanionAPI.Work {
        CompanionAPI.Work(items: items.map { workItem($0, shells: shells(of: $0, spaces: spaces)) }, activity: panes(activity),
                          problems: problems, refreshed: refreshed)
    }

    /// The plain shells in a worktree's herdr space, or with their folder in it: the Mac's Work page lists them after its
    /// agents (panesOf). The phone may read their screen; it never types into one — that would run commands on the Mac.
    nonisolated static func shells(of w: WorkItem, spaces: [HerdrSpace]) -> [CompanionAPI.Pane] {
        let agents = Set(w.panes.map(\.place))
        return spaces.filter { $0.checkout == w.path || $0.panes.contains { $0.cwd == w.path || $0.cwd.hasPrefix(w.path + "/") } }
            .flatMap(\.panes).filter { $0.agent == nil && !agents.contains($0.place) }
            .map { CompanionAPI.Pane(place: $0.place, title: CompanionAPI.shellTitle, status: "idle", since: nil, cwd: $0.cwd) }
    }

    /// Every pane, most urgent first: blocked, done, working, idle.
    nonisolated static func panes(_ activity: [OracleSnapshot.Activity]) -> [CompanionAPI.Pane] {
        activity.sorted { (WorkFormat.rank($0.status), $0.place) < (WorkFormat.rank($1.status), $1.place) }
            .map { CompanionAPI.Pane(place: $0.place, title: $0.title, status: $0.status, since: $0.since, cwd: $0.cwd) }
    }

    nonisolated static func workItem(_ w: WorkItem, shells: [CompanionAPI.Pane] = []) -> CompanionAPI.WorkItem {
        CompanionAPI.WorkItem(path: w.path, folder: w.folder, branch: w.branch, isMain: w.isMain, issue: w.issue,
                              prNumber: w.pr?.number, prTitle: w.pr?.title, state: w.state.label, panes: panes(w.panes) + shells,
                              resumeCommand: w.resumeCommand, slug: w.slug, born: w.born)
    }

    /// A pane the phone may read: an agent pane the Work data lists, or a plain shell the Work page shows.
    nonisolated static func readable(_ place: String, activity: [OracleSnapshot.Activity], work: [WorkItem], spaces: [HerdrSpace]) -> Bool {
        listed(place, activity: activity, work: work) || work.contains { shells(of: $0, spaces: spaces).contains { $0.place == place } }
    }

    /// An agent pane the Work data lists — in the activity, or one a work item holds. Only these are messaged.
    nonisolated static func listed(_ place: String, activity: [OracleSnapshot.Activity], work: [WorkItem]) -> Bool {
        activity.contains { $0.place == place } || work.contains { $0.panes.contains { $0.place == place } }
    }

    // screen

    /// `herdr --session S pane read P --source recent --lines 400` — the rows as the terminal draws them, like PaneScreen.
    nonisolated static func readArgs(place: String) -> [String]? {
        let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-") else { return nil }
        return ["--session", parts[0], "pane", "read", parts[1], "--source", "recent", "--lines", "400"]
    }

    /// The text without its trailing blank rows and spaces (PaneScreen's `\s+$`).
    nonisolated static func trimmed(_ s: String) -> String {
        guard let last = s.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(s[...last])
    }

    private func screenAnswer(_ q: [String: String]) async -> Response {
        guard let s = readStore() else { return stillReading() }
        guard let place = q["place"], !place.isEmpty else {
            return fail(400, "place is missing", fix: "GET /v1/screen?place=\(examplePlace())   — the places are in GET /v1/work")
        }
        guard Self.readable(place, activity: s.activity, work: s.work, spaces: s.spaces), let args = Self.readArgs(place: place) else {
            return fail(404, "\(Self.clip(place, 80)) is not a pane the Work page lists", fix: "GET /v1/work lists the places; on the Mac:  maw herdr ls --agents")
        }
        guard let out = await Shell.run("herdr", args, timeout: 4) else {
            return fail(502, "the Mac can't read \(place) — is herdr running?", fix: "herdr session list    then    herdr --session \(args[1]) pane list")
        }
        return reply(CompanionAPI.Screen(place: place, text: Self.trimmed(out), read: Date()))
    }

    // inbox

    private func inboxAnswer() -> Response {
        guard let s = readStore() else { return stillReading() }
        return reply(Self.inbox(items: s.inbox, unread: s.unread, root: s.config.inboxPath))
    }

    nonisolated static func inbox(items: [InboxItem], unread: Set<String>, root: String) -> CompanionAPI.Inbox {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return CompanionAPI.Inbox(items: items.compactMap { i in
            guard i.path.hasPrefix(prefix) else { return nil }
            return CompanionAPI.InboxEntry(path: String(i.path.dropFirst(prefix.count)), name: i.name, folder: i.folder,
                                           modified: i.modified, unread: unread.contains(i.path))
        }.sorted { $0.modified > $1.modified })
    }

    private func inboxFileAnswer(_ q: [String: String]) async -> Response {
        guard let c = config, !c.inboxPath.isEmpty else {
            return fail(404, "this app has no ψ/inbox on the Mac", fix: "set the oracle's checkout in its OracleConfig (localPath) and rebuild the app")
        }
        guard let rel = q["path"], !rel.isEmpty else {
            return fail(400, "path is missing", fix: "GET /v1/inbox/file?path=\(exampleInboxPath())   — the paths are in GET /v1/inbox")
        }
        let hint = "GET /v1/inbox lists the files; a path is relative to ψ/inbox, e.g.  GET /v1/inbox/file?path=\(exampleInboxPath())"
        guard Self.safe(relative: rel) else {
            return fail(403, "that path leaves ψ/inbox (no .., no absolute path, no hidden file)", fix: hint)
        }
        guard let url = Self.confine(relative: rel, root: c.inboxPath) else {
            return fail(404, "no such file in ψ/inbox: \(Self.clip(rel, 80))", fix: hint)
        }
        let result = await Task.detached(priority: .userInitiated) { Self.readText(url, limit: Self.maxFile) }.value
        switch result {
        case .text(let text, let modified): return reply(CompanionAPI.InboxFile(path: rel, text: text, modified: modified))
        case .missing: return fail(404, "no such file in ψ/inbox: \(Self.clip(rel, 80))", fix: hint)
        case .notRegular: return fail(415, "\(Self.clip(rel, 80)) is not a regular file", fix: hint)
        case .tooLarge: return fail(413, "\(Self.clip(rel, 80)) is larger than \(Self.maxFile / 1024) KB", fix: "open it on the Mac:  open \(Self.shellQuoted(url.path))")
        case .notText: return fail(415, "\(Self.clip(rel, 80)) is not UTF-8 text", fix: "open it on the Mac:  open \(Self.shellQuoted(url.path))")
        case .unreadable(let e): return fail(500, "the Mac could not read \(Self.clip(rel, 80)) (errno \(e))", fix: "ls -l \(Self.shellQuoted(url.path))")
        }
    }

    // github

    private func githubAnswer() -> Response {
        guard let s = readStore() else { return stillReading() }
        return reply(CompanionAPI.GitHub(prs: s.prs.map(Self.entry), issues: s.issues.map(Self.entry)))
    }

    nonisolated static func entry(_ g: GHItem) -> CompanionAPI.GHEntry {
        CompanionAPI.GHEntry(number: g.number, title: g.title, author: g.author, updatedAt: g.updatedAt, url: g.url, isDraft: g.isDraft, branch: g.branch,
                             closes: g.closes.isEmpty ? nil : g.closes)
    }

    // search

    /// The same kind → (kind, who) mapping as MCPServer's memory_search.
    nonisolated static func filter(kind: String) -> (kind: String?, state: String?) {
        switch kind {
        case "sessions": ("history", nil)
        case "you": ("history", "user")
        case "oracle": ("history", "assistant")
        case "notes": ("note", nil)
        case "issues": ("issue", nil)
        case "prs": ("pr", nil)
        default: (nil, nil)
        }
    }

    nonisolated static func hit(_ h: IndexHit) -> CompanionAPI.SearchHit {
        let d = h.doc
        return CompanionAPI.SearchHit(id: d.id, kind: d.kind, title: d.title, snippet: d.snippet, state: d.state, url: d.url, updated: d.updated,
                                      repo: d.repo, number: d.number, score: h.score.isFinite ? h.score : 0)
    }

    /// MCP's kinds, and "gh": issues and PRs together, as the Mac's Memory page filters them.
    nonisolated static let searchKinds = MCPServer.kinds + ["gh"]

    /// Who asked, as the phone names itself ("iPad"): letters, digits and spaces only, at most 24 — it goes into the trace.
    nonisolated static func device(_ headers: [String: String]) -> String {
        let raw = headers[CompanionAPI.deviceHeader.lowercased()] ?? ""
        let kept = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(Character.init)).prefix(24)
        let name = kept.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "phone" : name
    }

    private func searchAnswer(_ q: [String: String], _ r: MCPServer.Request) async -> Response {
        let text = String((q["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        guard !text.isEmpty else {
            return fail(400, "q is empty", fix: "GET /v1/search?q=heartrate&kind=all&limit=25")
        }
        let kind = q["kind"] ?? "all"
        guard Self.searchKinds.contains(kind) else {
            return fail(400, "unknown kind \"\(Self.clip(kind, 30))\"", fix: "kind is one of  " + Self.searchKinds.joined(separator: "  "))
        }
        guard let index = launch?.index() else { return starting() }
        let limit = min(50, max(1, Int(q["limit"] ?? "") ?? 25))
        let f = Self.filter(kind: kind)
        let t0 = Date()
        let kinds: Set<String>? = kind == "gh" ? ["issue", "pr"] : nil   // the Mac's "Issues & PRs": one query, one trace line
        guard let hits = await index.query(text, kind: f.kind, kinds: kinds, state: f.state, limit: limit, source: "companion",
                                           caller: "\(Self.device(r.headers)) · companion") else {
            return fail(503, index.problem ?? "no embedder answered",
                        fix: "on the Mac: Settings → Engine → Retry loading or Check engine  (curl -s 127.0.0.1:11435/health)")
        }
        // the trace line this query just wrote holds its timings
        let t = TraceLog.shared.entries.last { $0.source == "companion" && $0.query == text && $0.at >= t0 }
        func ms(_ x: Double?) -> Double { x.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        return reply(CompanionAPI.Search(query: text, hits: hits.map(Self.hit), embedMs: ms(t?.embedMs), rankMs: ms(t?.rankMs), pool: t?.pool ?? hits.count))
    }

    // status

    private func statusAnswer() async -> Response {
        guard let index = launch?.index() else { return starting() }
        if index.engine == nil { await index.checkEngine() }
        let docs = index.docs, hasMap = !index.layout.xyz.isEmpty
        let engine = index.engine.map { $0.ok ? $0.kind : "not answering" }, built = index.built
        let counts = await Task.detached(priority: .userInitiated) { Self.counts(docs) }.value
        return reply(CompanionAPI.MemoryStatus(items: docs.count, byKind: counts.byKind, sessions: counts.sessions, engine: engine, built: built, hasMap: hasMap))
    }

    /// Items per kind and the number of distinct sessions — MCPServer's memory_status.
    nonisolated static func counts(_ docs: [IndexDoc]) -> (byKind: [String: Int], sessions: Int) {
        var byKind: [String: Int] = [:]
        var sessions: Set<String> = []
        for d in docs { byKind[d.kind, default: 0] += 1; if d.kind == "history" { sessions.insert(d.url) } }
        return (byKind, sessions.count)
    }

    // map

    private func mapAnswer() async -> Response {
        guard let index = launch?.index() else { return starting() }
        let layout = index.layout
        guard !layout.xyz.isEmpty, layout.xyz.count == layout.ids.count else {
            return fail(404, "this memory has no map layout yet", fix: "on the Mac: Settings → Vector search → Rebuild map layout")
        }
        let clusters = index.clusters
        // the memory grew since the Mac's Map page last grouped it: group it now (off the main actor, as the page does),
        // or the phone gets a map with no groups at all
        if clusters.labels.count != layout.ids.count { await clusters.refresh(layout: layout, docs: index.docs) }
        let (ids, xyz, knn, k, docs, labels, groups) = (layout.ids, layout.xyz, layout.knn, layout.k, index.docs, clusters.labels, clusters.groups)
        // a big layout is megabytes of JSON: build and encode it off the main actor
        let body = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? CompanionAPI.encoder.encode(Self.mapData(ids: ids, xyz: xyz, knn: knn, k: k, docs: docs, labels: labels, groups: groups))
        }.value
        guard let body else { return fail(500, "the Mac could not encode the map", fix: "update the Mac app and the phone app to the same version") }
        return Response(status: 200, body: body)
    }

    /// The layout as the phone gets it. Row i of every array is the same doc; a doc the index no longer has keeps its id as title.
    nonisolated static func mapData(ids: [String], xyz: [SIMD3<Float>], knn: [Int32], k: Int, docs: [IndexDoc],
                                    labels: [Int], groups: [MapClusters.Group]) -> CompanionAPI.MapData {
        let at = Dictionary(docs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kinds: [String] = [], titles: [String] = []
        kinds.reserveCapacity(ids.count); titles.reserveCapacity(ids.count)
        for id in ids {
            if let i = at[id] { kinds.append(docs[i].kind); titles.append(title(of: docs[i])) }
            else { kinds.append(""); titles.append(String(id.prefix(120))) }
        }
        let n = ids.count
        let hasKNN = k > 0 && knn.count == n * k
        let grouped = labels.count == n && !groups.isEmpty
        return CompanionAPI.MapData(ids: ids, kinds: kinds, titles: titles, xyz: MapLayout.pack(xyz),
                                    knn: hasKNN ? knn.withUnsafeBufferPointer { Data(buffer: $0) } : Data(), k: hasKNN ? k : 0,
                                    labels: grouped ? labels : [],
                                    groups: grouped ? groups.map { CompanionAPI.MapGroup(id: $0.id, count: $0.count, keywords: $0.keywords, title: $0.title) } : [])
    }

    /// What the Map page names a point: what was said for a session piece, else the title — at most 120 characters.
    nonisolated static func title(of d: IndexDoc) -> String {
        let t = d.kind == "history" && !d.snippet.isEmpty ? d.snippet : d.title
        return String(t.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }

    // trace

    private func traceAnswer(_ q: [String: String]) async -> Response {
        let limit = min(1_000, max(1, Int(q["limit"] ?? "") ?? 200))
        await TraceLog.shared.loadPast()
        let all = TraceLog.shared.past + TraceLog.shared.entries
        return reply(CompanionAPI.Trace(entries: all.suffix(limit).map(Self.finite)))
    }

    /// The same entry with numbers JSON can carry (a NaN would fail the whole answer).
    nonisolated static func finite(_ e: TraceLog.Entry) -> TraceLog.Entry {
        guard !e.embedMs.isFinite || !e.rankMs.isFinite || e.top.contains(where: { !$0.score.isFinite }) else { return e }
        return TraceLog.Entry(id: e.id, at: e.at, source: e.source, index: e.index, query: e.query, filter: e.filter,
                              embedMs: e.embedMs.isFinite ? e.embedMs : 0, rankMs: e.rankMs.isFinite ? e.rankMs : 0, pool: e.pool, via: e.via,
                              top: e.top.map { .init(id: $0.id, title: $0.title, score: $0.score.isFinite ? $0.score : 0) }, caller: e.caller)
    }

    // hey — the one write

    /// What reaches the agent pane. Control characters other than newline and tab are dropped (a NUL in a Process argument
    /// raises an Objective-C exception that kills the app; an ESC or a Ctrl-C is a keystroke, not text), and a message that
    /// starts with "-" gets a space in front, because `maw herdr hey` reads such an argument as an option — `--help` printed
    /// its usage and counted as sent.
    nonisolated static func safeMessage(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control }
        let s = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("-") ? " " + s : s
    }

    private func heyAnswer(_ r: MCPServer.Request) async -> Response {
        guard allowsMessages else {
            return fail(403, "messages from the phone are off on this Mac", fix: "on the Mac: turn on Allow messages in Settings → Companion")
        }
        // a test token can be one character, and loopback is every local process: with one, the server does not type into panes
        if let t = tokenOverride, t.count < 32 {
            return fail(403, "messages are off while the server runs on a short test token (-companionToken)",
                        fix: "relaunch without -companionToken, or with one of at least 32 characters:  openssl rand -hex 32")
        }
        guard let s = readStore() else { return stillReading() }
        guard let hey = try? CompanionAPI.decoder.decode(CompanionAPI.Hey.self, from: r.body) else {
            return fail(400, "the body is not {\"place\", \"text\"} JSON",
                        fix: #"send  {"place":"\#(examplePlace())","text":"hello"}  with  Content-Type: application/json"#)
        }
        let text = Self.safeMessage(hey.text)
        guard !text.isEmpty else { return fail(400, "text is empty", fix: #"send  {"place":"\#(Self.clip(hey.place, 60))","text":"hello"}  — text must not be empty"#) }
        guard text.count <= Self.maxMessage else {
            return fail(413, "the message is \(text.count) characters; the limit is \(Self.maxMessage)", fix: "send it in parts of at most \(Self.maxMessage) characters")
        }
        guard Self.listed(hey.place, activity: s.activity, work: s.work) else {
            return fail(404, "\(Self.clip(hey.place, 80)) is not a pane the Work page lists", fix: "GET /v1/work lists the places; on the Mac:  maw herdr ls --agents")
        }
        guard await s.hey(place: hey.place, message: text) else {
            return fail(502, "maw herdr hey could not deliver the message to \(hey.place)", fix: "on the Mac:  maw herdr ls --agents   (is the pane still there?) — then send again")
        }
        return reply(CompanionAPI.Sent(ok: true))
    }
}
#endif
