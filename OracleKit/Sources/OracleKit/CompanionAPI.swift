import Foundation

/// The companion API: an oracle app on the Mac serves its own pages, read-only, to the same oracle's app on an
/// iPhone or iPad — Work (spaces, panes, a pane's live screen), Inbox, PRs and issues, Memory search, the Map, the
/// Trace. The data lives on the Mac (herdr, the checkout, the transcripts, the embedding model); the phone shows it.
///
/// Transport: HTTP/1.1 + JSON on the Mac app's companion port (its MCP port + 10), bound ONLY to 127.0.0.1 and the
/// Mac's NetBird mesh address (100.64.0.0/10), never 0.0.0.0. Every request carries `Authorization: Bearer <token>`;
/// the token is made on the Mac (Settings → Companion) and reaches the phone by QR code or a pasted pairing link.
/// Off until switched on in Settings. Writes (a message to an agent) need a second switch, also off by default.
///
/// Every type here is shared: the Mac encodes, the phone decodes. Dates are ISO 8601. Change `version` on any
/// breaking change; the phone refuses a server with another major version and says which side to update.
public enum CompanionAPI {
    public static let version = 1

    /// The companion port of an app: its MCP port + 10 (hub 4800 · Neo 4801 · Pulse 4802 · Nexus 4803).
    public static func port(mcp: UInt16) -> UInt16 { mcp + 10 }

    public enum Path {
        public static let hello = "/v1/hello"          // GET  → Hello (also the auth check)
        public static let work = "/v1/work"            // GET  → Work
        public static let screen = "/v1/screen"        // GET  ?place=<session:pane> → Screen (the pane's rows, as drawn)
        public static let inbox = "/v1/inbox"          // GET  → Inbox
        public static let inboxFile = "/v1/inbox/file" // GET  ?path=<relative to ψ/inbox> → InboxFile (text files, ≤ 512 KB)
        public static let github = "/v1/github"        // GET  → GitHub (open PRs and issues, as the Mac app has them)
        public static let search = "/v1/search"        // GET  ?q=<text>&kind=all|sessions|you|oracle|notes|issues|prs&limit=n → Search
        public static let status = "/v1/status"        // GET  → MemoryStatus
        public static let map = "/v1/map"              // GET  → MapData (the 3-D positions, kinds, titles, groups)
        public static let trace = "/v1/trace"          // GET  ?limit=n → Trace (newest last)
        public static let hey = "/v1/hey"              // POST Hey → Sent   (only when "Allow messages" is on)
    }

    // MARK: payloads

    public struct Hello: Codable, Sendable, Equatable {
        public var name: String            // "Pulse"
        public var repoSlug: String        // "laris-co/pulse"
        public var colorHex: String
        public var symbol: String
        public var appVersion: String      // CalVer of the Mac app
        public var api: Int                // CompanionAPI.version
        public var host: String            // the Mac's host name
        public var allowsMessages: Bool    // POST /v1/hey is on
        public init(name: String, repoSlug: String, colorHex: String, symbol: String, appVersion: String, api: Int, host: String, allowsMessages: Bool) {
            self.name = name; self.repoSlug = repoSlug; self.colorHex = colorHex; self.symbol = symbol
            self.appVersion = appVersion; self.api = api; self.host = host; self.allowsMessages = allowsMessages
        }
    }

    public struct Pane: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: String { place }
        public var place: String           // "laris-co:w22:p1" — session:pane
        public var title: String           // the pane's current task (terminal title) or "shell"
        public var status: String          // working · blocked · done · idle · unknown
        public var since: Date?
        public var cwd: String?
        public init(place: String, title: String, status: String, since: Date? = nil, cwd: String? = nil) {
            self.place = place; self.title = title; self.status = status; self.since = since; self.cwd = cwd
        }
    }

    public struct WorkItem: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: String { path }
        public var path: String            // checkout path on the Mac (shown as its folder)
        public var folder: String
        public var branch: String
        public var isMain: Bool
        public var issue: Int?
        public var prNumber: Int?
        public var prTitle: String?
        public var state: String           // needs you · working · open · resumable · cold (WorkItem.State.label)
        public var panes: [Pane]
        public var resumeCommand: String?  // what reopens it, when it can be resumed
        public var slug: String?           // the worktree's /herdr-wt slug ("companion"), as the Mac shows it; nil from an older Mac
        public var born: Date?             // when the worktree was made (its herdr lock, else its folder's date)
        public init(path: String, folder: String, branch: String, isMain: Bool, issue: Int?, prNumber: Int?, prTitle: String?,
                    state: String, panes: [Pane], resumeCommand: String?, slug: String? = nil, born: Date? = nil) {
            self.path = path; self.folder = folder; self.branch = branch; self.isMain = isMain; self.issue = issue
            self.prNumber = prNumber; self.prTitle = prTitle; self.state = state; self.panes = panes; self.resumeCommand = resumeCommand
            self.slug = slug; self.born = born
        }
    }

    public struct Work: Codable, Sendable, Equatable {
        public var items: [WorkItem]
        public var activity: [Pane]        // every pane, most urgent first (blocked, done, working, idle)
        public var problems: [String]      // what the Mac app could not read ("maw / herdr not answering")
        public var refreshed: Date?
        public init(items: [WorkItem], activity: [Pane], problems: [String], refreshed: Date?) {
            self.items = items; self.activity = activity; self.problems = problems; self.refreshed = refreshed
        }
    }

    public struct Screen: Codable, Sendable, Equatable {
        public var place: String
        public var text: String            // the rows as the terminal draws them (≤ 400), trailing spaces trimmed
        public var read: Date
        public init(place: String, text: String, read: Date) { self.place = place; self.text = text; self.read = read }
    }

    public struct InboxEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: String { path }
        public var path: String            // relative to the oracle's ψ/inbox
        public var name: String
        public var folder: String          // handoff · dropped · …
        public var modified: Date
        public var unread: Bool
        public init(path: String, name: String, folder: String, modified: Date, unread: Bool) {
            self.path = path; self.name = name; self.folder = folder; self.modified = modified; self.unread = unread
        }
    }

    public struct Inbox: Codable, Sendable, Equatable {
        public var items: [InboxEntry]     // newest first
        public init(items: [InboxEntry]) { self.items = items }
    }

    public struct InboxFile: Codable, Sendable, Equatable {
        public var path: String
        public var text: String
        public var modified: Date
        public init(path: String, text: String, modified: Date) { self.path = path; self.text = text; self.modified = modified }
    }

    public struct GHEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: Int { number }
        public var number: Int
        public var title: String
        public var author: String
        public var updatedAt: Date?
        public var url: URL?
        public var isDraft: Bool
        public var branch: String?
        public var closes: [Int]?          // issues a PR closes: what ties a PR to an issue's worktree; nil from an older Mac
        public init(number: Int, title: String, author: String, updatedAt: Date?, url: URL?, isDraft: Bool, branch: String?, closes: [Int]? = nil) {
            self.number = number; self.title = title; self.author = author; self.updatedAt = updatedAt
            self.url = url; self.isDraft = isDraft; self.branch = branch; self.closes = closes
        }
    }

    public struct GitHub: Codable, Sendable, Equatable {
        public var prs: [GHEntry]
        public var issues: [GHEntry]
        public init(prs: [GHEntry], issues: [GHEntry]) { self.prs = prs; self.issues = issues }
    }

    public struct SearchHit: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: String              // IndexDoc.id
        public var kind: String            // history · note · issue · pr
        public var title: String
        public var snippet: String
        public var state: String           // user|assistant for a session piece; folder for a note; OPEN/CLOSED/MERGED
        public var url: String             // a session's resume command; a note's file URL; an issue/PR URL
        public var updated: String
        public var repo: String
        public var number: Int
        public var score: Float
        public init(id: String, kind: String, title: String, snippet: String, state: String, url: String, updated: String,
                    repo: String, number: Int, score: Float) {
            self.id = id; self.kind = kind; self.title = title; self.snippet = snippet; self.state = state
            self.url = url; self.updated = updated; self.repo = repo; self.number = number; self.score = score
        }
    }

    public struct Search: Codable, Sendable, Equatable {
        public var query: String
        public var hits: [SearchHit]
        public var embedMs: Double
        public var rankMs: Double
        public var pool: Int
        public init(query: String, hits: [SearchHit], embedMs: Double, rankMs: Double, pool: Int) {
            self.query = query; self.hits = hits; self.embedMs = embedMs; self.rankMs = rankMs; self.pool = pool
        }
    }

    public struct MemoryStatus: Codable, Sendable, Equatable {
        public var items: Int
        public var byKind: [String: Int]
        public var sessions: Int
        public var engine: String?
        public var built: Date?
        public var hasMap: Bool
        public init(items: Int, byKind: [String: Int], sessions: Int, engine: String?, built: Date?, hasMap: Bool) {
            self.items = items; self.byKind = byKind; self.sessions = sessions; self.engine = engine; self.built = built; self.hasMap = hasMap
        }
    }

    public struct MapGroup: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var id: Int
        public var count: Int
        public var keywords: [String]
        public init(id: Int, count: Int, keywords: [String]) { self.id = id; self.count = count; self.keywords = keywords }
    }

    /// The Map as the Mac laid it out. Row i of every array is the same doc.
    public struct MapData: Codable, Sendable, Equatable {
        public var ids: [String]
        public var kinds: [String]          // history · note · issue · pr
        public var titles: [String]         // ≤ 120 chars; a session piece's snippet, else the title
        public var xyz: Data                // N × 3 Float32, little-endian (base64 in JSON)
        public var knn: Data                // N × k Int32, -1 = none
        public var k: Int
        public var labels: [Int]            // group per row (empty when not grouped yet)
        public var groups: [MapGroup]
        public init(ids: [String], kinds: [String], titles: [String], xyz: Data, knn: Data, k: Int, labels: [Int], groups: [MapGroup]) {
            self.ids = ids; self.kinds = kinds; self.titles = titles; self.xyz = xyz; self.knn = knn; self.k = k
            self.labels = labels; self.groups = groups
        }
    }

    public struct Trace: Codable, Sendable {
        public var entries: [TraceLog.Entry]
        public init(entries: [TraceLog.Entry]) { self.entries = entries }
    }

    public struct Hey: Codable, Sendable, Equatable {
        public var place: String
        public var text: String
        public init(place: String, text: String) { self.place = place; self.text = text }
    }

    public struct Sent: Codable, Sendable, Equatable {
        public var ok: Bool
        public init(ok: Bool) { self.ok = ok }
    }

    /// Every error answer: what went wrong, and what fixes it (fleet rule: an error ends with the fix).
    public struct Problem: Codable, Sendable, Equatable, Error {
        public var error: String
        public var fix: String?
        public init(error: String, fix: String? = nil) { self.error = error; self.fix = fix }
    }

    // MARK: pairing

    /// What the phone needs to reach one oracle app: shown on the Mac as a QR code and a link,
    /// `oracle-<name lowercased>://pair?host=<ip>&port=<n>&token=<hex>&name=<Name>`.
    public struct Pairing: Codable, Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var token: String
        public var name: String
        public init(host: String, port: UInt16, token: String, name: String) {
            self.host = host; self.port = port; self.token = token; self.name = name
        }
        public var baseURL: URL? { URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)") }
        public func link(scheme: String) -> URL? {
            var c = URLComponents(); c.scheme = scheme; c.host = "pair"
            c.queryItems = [.init(name: "host", value: host), .init(name: "port", value: String(port)),
                            .init(name: "token", value: token), .init(name: "name", value: name)]
            return c.url
        }
        /// Parses a pairing link (any scheme); nil when a field is missing.
        public static func parse(_ url: URL) -> Pairing? {
            guard url.host == "pair", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
            func q(_ n: String) -> String? { items.first { $0.name == n }?.value.flatMap { $0.isEmpty ? nil : $0 } }
            guard let host = q("host"), let p = q("port").flatMap(UInt16.init), let token = q("token"), let name = q("name") else { return nil }
            return Pairing(host: host, port: p, token: token, name: name)
        }
    }

    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    /// The title of a plain shell pane in a worktree's panes: the phone reads its screen and never types into it.
    public static let shellTitle = "shell"
    /// The phone names itself in this header ("iPad"), so the Mac's trace says who asked: "iPad · companion".
    public static let deviceHeader = "X-Companion-Device"
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
