#if os(macOS)
import Foundation
import Network

/// A local MCP server inside the app, so the oracle's own agent can search its memory by meaning:
///     claude mcp add --transport http <name> http://127.0.0.1:<port>/mcp
/// Streamable HTTP answered with plain JSON (no SSE stream), JSON-RPC 2.0: initialize, ping, tools/list, tools/call.
/// Tools: memory_search, memory_status. Listens on 127.0.0.1 only — nothing leaves this Mac.
@MainActor
public final class MCPServer: ObservableObject {
    public static let shared = MCPServer()
    public struct Call: Identifiable, Sendable {
        public let id = UUID()
        public let at: Date
        public let method: String
        public let detail: String
        public let ms: Double
    }
    @Published public private(set) var running = false
    @Published public private(set) var port: UInt16 = 0
    @Published public private(set) var name = ""
    @Published public private(set) var calls: [Call] = []
    @Published public private(set) var problem: String?
    private var listener: NWListener?
    private var index: (() -> GHIndex)?
    /// who is on the other end of each MCP session (the id handed out at initialize), so it is measured once
    private var sessions: [String: MCPCaller] = [:]

    public var url: String { "http://127.0.0.1:\(port)/mcp" }
    public var addCommand: String { "claude mcp add --transport http \(name) \(url)" }

    public func start(name: String, port: UInt16, index: @escaping () -> GHIndex) {
        stop()
        self.name = name; self.port = port; self.index = index; problem = nil
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 4790)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated { self?.accept(c) }   // the listener runs on the main queue
            }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        self?.running = true
                        HubLog.shared.add(.info, "MCP: listening on 127.0.0.1:\(port) — \(self?.addCommand ?? "")")
                    case .failed(let e):
                        self?.running = false
                        self?.problem = "MCP could not listen on 127.0.0.1:\(port) (\(e)) — see what holds it:  lsof -nP -iTCP:\(port) -sTCP:LISTEN"
                        HubLog.shared.add(.error, self?.problem ?? "")
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            problem = "MCP could not listen on 127.0.0.1:\(port) (\(error)) — see what holds it:  lsof -nP -iTCP:\(port) -sTCP:LISTEN"
            HubLog.shared.add(.error, problem ?? "")
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil; running = false
    }

    // MARK: HTTP, just enough

    struct Request {
        let method: String; let path: String; let headers: [String: String]; let body: Data
        /// Why the request can't be read (answered 400, then closed); nil for a good one.
        var bad: String? = nil
    }
    nonisolated static let maxHeader = 64 << 10, maxBody = 8 << 20

    /// A complete request from what has arrived, or nil while headers or body are still coming. A request that can
    /// never be read — a Content-Length below 0 or past 8 MB, a header block past 64 KB — comes back with `bad` set,
    /// instead of slicing the buffer with it (a negative length crashed the app, from any local process).
    nonisolated static func parse(_ d: Data) -> Request? {
        let d = Data(d)
        func bad(_ why: String) -> Request { Request(method: "", path: "", headers: [:], body: Data(), bad: why) }
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return d.count > maxHeader ? bad("the header block is over 64 KB") : nil }
        guard end.lowerBound <= maxHeader else { return bad("the header block is over 64 KB") }
        var lines = String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return bad("no request line") }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length: Int
        if let h = headers["content-length"] {
            guard let n = Int(h), n >= 0, n <= maxBody else { return bad("Content-Length must be a number from 0 to 8 MB") }
            length = n
        } else { length = 0 }
        guard d.count - end.upperBound >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: d[end.upperBound..<(end.upperBound + length)])
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                var buf = buffer
                if let data { buf.append(data) }
                if let r = Self.parse(buf) { self?.handle(r, c); return }
                if done || error != nil || buf.count > Self.maxHeader + Self.maxBody { c.cancel(); return }
                self?.receive(c, buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ json: Any?, headers: [String: String] = [:]) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: JSON-RPC

    private func handle(_ r: Request, _ c: NWConnection) {
        if let why = r.bad {
            HubLog.shared.add(.error, "MCP: refused a request — \(why)")
            respond(c, 400, ["error": why]); return
        }
        if r.method == "GET", r.path == "/health" {
            respond(c, 200, ["status": "ok", "name": name, "version": AppVersion.calver, "tools": Self.tools.compactMap { $0["name"] }]); return
        }
        guard r.path.hasPrefix("/mcp") else { respond(c, 404, ["error": "not found — POST JSON-RPC to /mcp"]); return }
        if r.method == "GET" { respond(c, 405, nil); return }                       // no server-initiated stream
        if r.method == "DELETE" {                                                       // a client ending its session
            if let sid = r.headers["mcp-session-id"] { sessions[sid] = nil }
            respond(c, 200, [:]); return
        }
        guard r.method == "POST", let msg = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else {
            respond(c, 400, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]); return
        }
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id = msg["id"] else { respond(c, 202, nil); return }               // a notification: nothing to answer
        let t0 = Date()
        let sid = r.headers["mcp-session-id"]
        let port: UInt16? = if case let .hostPort(_, p) = c.endpoint { p.rawValue } else { nil }
        Task { @MainActor in
            var detail = ""
            var headers: [String: String] = [:]
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                reply["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                                   "capabilities": ["tools": ["listChanged": false]],
                                   "serverInfo": ["name": name, "version": AppVersion.calver],
                                   "instructions": "Search this oracle's own memory by meaning: its sessions, ψ vault notes, issues and PRs."]
                var who = MCPCaller()
                if let port { who = await MCPCaller.resolve(port: port) }
                if let info = params["clientInfo"] as? [String: Any] {
                    who.client = [info["name"] as? String, info["version"] as? String].compactMap { $0 }.joined(separator: " ")
                }
                if who.client.isEmpty { who.client = r.headers["user-agent"] ?? "" }
                let session = UUID().uuidString.lowercased()
                if sessions.count >= 500 { sessions.removeAll() }
                sessions[session] = who
                headers["Mcp-Session-Id"] = session
                detail = who.label
            case "ping": reply["result"] = [String: Any]()
            case "tools/list": reply["result"] = ["tools": Self.tools]
            case "tools/call":
                var who = sid.flatMap { sessions[$0] } ?? MCPCaller()
                if who.pid == 0, let port {   // a session from before this launch, or a client that sends no session id
                    who = await MCPCaller.resolve(port: port)
                    who.client = sid.flatMap { sessions[$0]?.client } ?? r.headers["user-agent"] ?? ""
                    if let sid { sessions[sid] = who }
                }
                if let said = (params["arguments"] as? [String: Any])?["from"] as? String { who.said = said }
                let (result, d) = await call(params, caller: who.label)
                reply["result"] = result; detail = d + (who.label.isEmpty ? "" : " · " + who.label)
            default:
                reply["error"] = ["code": -32601, "message": "method not found: \(method)"]
            }
            respond(c, 200, reply, headers: headers)
            let ms = Date().timeIntervalSince(t0) * 1000
            calls.append(Call(at: Date(), method: method, detail: detail, ms: ms))
            if calls.count > 200 { calls.removeFirst(calls.count - 200) }
            HubLog.shared.add(.search, String(format: "MCP %@%@ · %.0f ms", method, detail.isEmpty ? "" : " " + detail, ms))
        }
    }

    nonisolated static let kinds = ["all", "sessions", "you", "oracle", "notes", "issues", "prs"]
    static let tools: [[String: Any]] = [
        ["name": "memory_search",
         "description": "Search this oracle's memory by meaning — its own sessions (what was asked and what it answered), its ψ vault notes, its GitHub issues and PRs. Returns the best matches with a score, a snippet and where each came from.",
         "inputSchema": ["type": "object",
                         "properties": ["query": ["type": "string", "description": "What to look for, in plain words"],
                                        "kind": ["type": "string", "enum": kinds,
                                                 "description": "all (default) · sessions · you (what the person asked) · oracle (what the oracle answered) · notes · issues · prs"],
                                        "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many results, 10 by default"],
                                        "from": ["type": "string",
                                                 "description": "Who is asking — your oracle or system, e.g. neo-oracle or codex. Optional: the server also identifies the calling process and its repo."]],
                         "required": ["query"]]],
        ["name": "memory_status",
         "description": "What this memory holds: items per kind, sessions, the embedding engine, the vector space, when it was built.",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ]

    private func call(_ params: [String: Any], caller: String) async -> ([String: Any], String) {
        let tool = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        func text(_ s: String, error: Bool = false) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": error] }
        guard let index = index?() else { return (text("no index in this app", error: true), tool) }
        switch tool {
        case "memory_search":
            let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return (text("query is empty", error: true), tool) }
            let kind = args["kind"] as? String ?? "all"
            let limit = min(50, max(1, args["limit"] as? Int ?? 10))
            let filter: (kind: String?, state: String?) = switch kind {
                case "sessions": ("history", nil)
                case "you": ("history", "user")
                case "oracle": ("history", "assistant")
                case "notes": ("note", nil)
                case "issues": ("issue", nil)
                case "prs": ("pr", nil)
                default: (nil, nil)
            }
            guard let hits = await index.query(q, kind: filter.kind, state: filter.state, limit: limit, source: "mcp",
                                               caller: caller.isEmpty ? nil : caller) else {
                return (text(index.problem ?? "no embedder answered", error: true), "memory_search \"\(q)\" failed")
            }
            let lines = hits.enumerated().map { i, h -> String in
                let d = h.doc
                let what = d.kind == "history" ? "session · \(d.state == "user" ? "asked" : "answered") · \(d.updated.prefix(16))"
                    : d.kind == "note" ? "ψ/\(d.state)" : "\(d.kind) \(d.repo)#\(d.number) · \(d.state.lowercased())"
                let where_ = d.kind == "history" ? "reopen: \(d.url)" : d.url
                return String(format: "%d. %.0f%% · %@ · %@\n   %@\n   %@", i + 1, Double(h.score) * 100, what, d.title, d.snippet, where_)
            }
            return (text(lines.isEmpty ? "nothing found for \"\(q)\"" : lines.joined(separator: "\n")), "memory_search \"\(q)\" → \(hits.count)")
        case "memory_status":
            var byKind: [String: Int] = [:]
            for d in index.docs { byKind[d.kind, default: 0] += 1 }
            let sessions = Set(index.docs.filter { $0.kind == "history" }.map(\.url)).count
            let s = """
            items: \(index.docs.count) — \(byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            sessions: \(sessions)
            engine: \(index.engine?.kind ?? "not checked yet")
            vector space: \(index.space ?? "—")
            built: \(index.built.map { $0.formatted() } ?? "never")
            vector cache: \(VectorCache.shared.count) vectors
            """
            return (text(s), tool)
        default:
            return (text("unknown tool: \(tool)", error: true), tool)
        }
    }
}
#endif
