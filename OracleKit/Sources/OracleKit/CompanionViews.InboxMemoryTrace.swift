#if os(iOS)
import SwiftUI

// MARK: - Inbox: the Mac's ψ/inbox, newest first, a file opens as text

struct PhoneInboxView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var inbox: CompanionAPI.Inbox?
    @State private var failed: String?
    @State private var readAt: Date?             // when a read last worked: a failing one keeps the list and says since when
    @State private var show = 0                  // All · Unread · Read
    @State private var openEntry: CompanionAPI.InboxEntry?
    @State private var reading = false
    private static var actionDone = false
    private var c: OracleConfig { store.config }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "tray",
                              gives: "The files and notes in \(c.name)'s ψ/inbox on your Mac — handoffs, drops, links — newest first, to read here.")
            }
        }
        .navigationTitle("Inbox")
    }

    /// The Mac says unread and this phone has not opened it since it changed — what the sidebar badge and the widget count.
    private func unread(_ e: CompanionAPI.InboxEntry) -> Bool { e.unread && !store.hasRead(path: e.path, modified: e.modified) }

    private var page: some View {
        let all = inbox?.items ?? []
        let unreadCount = all.filter(unread).count
        let rows: [CompanionAPI.InboxEntry] = show == 1 ? all.filter(unread) : show == 2 ? all.filter { !unread($0) } : all
        return List {
            VStack(alignment: .leading, spacing: 10) {
                PhoneSegments(options: [(0, "All \(all.count)"), (1, "Unread \(unreadCount)"), (2, "Read \(all.count - unreadCount)")],
                              selection: $show, accent: c.color)
                if let failed { PhoneReadFailure(problem: failed, since: readAt) { Task { await load() } } }
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            ForEach(rows) { e in
                Button { openEntry = e } label: { row(e) }.buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .sheet(item: $openEntry) { e in
            NavigationStack { PhoneInboxFile(entry: e, accent: c.color) }.phonePageSheet().tint(c.color)
                .onAppear { store.markRead(InboxItem(path: e.path, name: e.name, folder: e.folder, modified: e.modified)) }
        }
        .overlay {
            if inbox == nil && failed == nil { ProgressView() }
            else if inbox != nil && rows.isEmpty {
                Text(show == 1 ? "Nothing unread." : show == 2 ? "Nothing read yet." : "Inbox is empty on the Mac.").foregroundStyle(.secondary)
            }
        }
        .refreshable { await load() }
        .onAppear { Task { await load() } }
        .onForeground { Task { await load() } }
        .onChange(of: client.pairing) { inbox = nil; readAt = nil; Task { await load() } }
        .onChange(of: client.reachable) { _, now in if now == true, failed != nil { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
    }

    private func row(_ e: CompanionAPI.InboxEntry) -> some View {
        let u = unread(e)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(u ? c.color : .clear)
                .overlay(Circle().stroke(u ? .clear : Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(u ? .body.weight(.semibold) : .body).foregroundStyle(u ? .primary : .secondary).lineLimit(2)
                Text("\(u ? "unread" : "read") · \(e.folder) · \(PhoneFormat.stamp(e.modified))")
                    .font(.caption).foregroundStyle(u ? AnyShapeStyle(c.color) : AnyShapeStyle(.tertiary))
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        if reading { return }
        reading = true; defer { reading = false }
        if let i = await client.shielded({ await $0.inbox() }) { inbox = i; readAt = Date(); failed = nil } else { failed = PhoneFormat.why(client) }
        if !Self.actionDone, let n = UserDefaults.standard.string(forKey: "inboxOpen").flatMap(Int.init), let items = inbox?.items, n < items.count {   // -inboxOpen <n> (tests)
            Self.actionDone = true
            openEntry = items[n]
        }
    }
}

/// One inbox file as text, in a sheet: a Markdown file with its inline styling (bold, code, links) and the lines kept as
/// written; plain monospaced when it does not parse, or is not Markdown. Only the head of a long file is laid out — one Text
/// draws its whole string at once, and the Mac serves up to 512 KB — with a line saying the rest is on the Mac.
struct PhoneInboxFile: View {
    let entry: CompanionAPI.InboxEntry
    let accent: Color
    @ObservedObject private var client = CompanionClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var file: CompanionAPI.InboxFile?   // its text is what is shown: the head of the file, at most `limit` bytes
    @State private var fullSize: Int?                   // the file's size in bytes, when only its head is shown
    @State private var rendered: AttributedString?
    @State private var failed: String?
    static let limit = 64 * 1024

    /// The head of a text that the page lays out: at most `limit` bytes, ending at a line (a line longer than that is cut at a
    /// character instead). nil when the whole text fits.
    static func head(of text: String, limit: Int = PhoneInboxFile.limit) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count > limit + limit / 8 else { return nil }   // a file just over 64 KB shows whole, never "64 KB of 64 KB"
        var end = limit
        if let newline = bytes[..<limit].lastIndex(of: 10), newline > limit / 2 { end = bytes[newline - 1] == 13 ? newline - 1 : newline }   // a CRLF goes whole
        else { while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 } }   // not inside a character
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
    private static func kb(_ bytes: Int) -> String { "\((bytes + 512) / 1024) KB" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.name).font(.custom("Avenir Next", size: 22).weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text("\(entry.folder) · \(PhoneFormat.stamp(file?.modified ?? entry.modified))")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if let rendered {
                    Text(rendered).font(.callout).textSelection(.enabled).tint(accent)
                } else if let file {
                    Text(file.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                } else if let failed {
                    PhoneProblemCard(text: failed) { Task { await load() } }
                } else {
                    ProgressView()
                }
                if let file, let fullSize {
                    Divider()
                    Text("Showing the first \(Self.kb(file.text.utf8.count)) of \(Self.kb(fullSize)) — the rest is on the Mac, in ψ/inbox/\(entry.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Inbox").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await load() }
    }

    private func load() async {
        let path = entry.path
        guard let f = await client.shielded({ await $0.inboxFile(path: path) }) else { failed = PhoneFormat.why(client); return }
        let head = Self.head(of: f.text)
        let text = head ?? f.text   // what is laid out, as plain text and as Markdown alike
        fullSize = head == nil ? nil : f.text.utf8.count
        file = head == nil ? f : CompanionAPI.InboxFile(path: f.path, text: text, modified: f.modified)
        failed = nil
        guard ["md", "markdown", "mdx", ""].contains((entry.name as NSString).pathExtension.lowercased()) else { return }   // a csv or a log stays as written
        rendered = await Task.detached(priority: .userInitiated) {
            try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        }.value
    }
}

// MARK: - Memory: the search half of the Mac's Memory page, the Mac does the searching

struct PhoneMemoryView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var query = ""
    @State private var who = "all"                // all · you · oracle · notes · gh
    @State private var found: CompanionAPI.Search?
    @State private var status: CompanionAPI.MemoryStatus?
    @State private var statusRead: Date?          // when the status last read: a failing read keeps it and says since when
    @State private var statusFailed: String?
    @State private var searching = false
    @State private var failed: String?
    @State private var copied: String?
    @State private var asked = 0                  // the newest search wins; an older answer is dropped
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL
    private static var actionDone = false
    private var c: OracleConfig { store.config }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "brain",
                              gives: "Ask \(c.name)'s past by meaning — its sessions, ψ notes, issues and PRs. Your Mac runs the search; the answers come here.")
            }
        }
        .navigationTitle("Memory")
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PhoneHeader(eyebrow: "SEMANTIC MEMORY", title: "\(c.name)'s memory",
                            subtitle: "Every session, ψ note, issue and PR of \(c.repoSlug) — what you asked, what \(c.name) answered and wrote down, ready for meaning.",
                            accent: c.color)
                statusLine
                if let statusFailed, failed == nil { PhoneReadFailure(problem: statusFailed, since: statusRead) { Task { await readStatus() } } }
                searchField
                PhoneSegments(options: [("all", "All"), ("you", "You"), ("oracle", c.name), ("notes", "ψ notes"), ("gh", "Issues & PRs")],
                              selection: $who, accent: c.color)
                    .onChange(of: who) { if !query.trimmingCharacters(in: .whitespaces).isEmpty { Task { await search() } } }
                if let failed { PhoneProblemCard(text: failed) { Task { await search() } } }
                if let f = found {
                    Text("\(f.hits.count) \(f.hits.count == 1 ? "result" : "results") · \(String(format: "%.0f + %.1f ms", f.embedMs, f.rankMs)) · \(grouped(f.pool)) ranked — a session result copies the command that reopens it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(found?.hits ?? []) { h in
                        PhoneHitCard(hit: h, oracleName: c.name, copied: copied == h.id) { open(h) }
                    }
                }
                if let f = found, f.hits.isEmpty, failed == nil, !searching {
                    Text(status?.items == 0 ? "nothing embedded yet — on the Mac: \(c.name) → Memory → Scan, then Run batch"
                                            : "nothing close to that — try other words")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await readStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await readStatus() } }
        .onAppear { Task { await start() } }
        .onChange(of: client.pairing) { status = nil; statusRead = nil; statusFailed = nil; Task { await start() } }
        .onChange(of: client.reachable) { _, now in if now == true, statusFailed != nil { Task { await start() } } }
    }

    private func readStatus() async {
        if let s = await client.shielded({ await $0.status() }) { status = s; statusRead = Date(); statusFailed = nil }
        else { statusFailed = PhoneFormat.why(client) }
    }

    private func start() async {
        await readStatus()
        if !Self.actionDone, let q = UserDefaults.standard.string(forKey: "memoryQuery"), !q.isEmpty {   // -memoryQuery <text> (tests)
            Self.actionDone = true
            query = q; await search()
        }
    }

    /// What the Mac holds: items, sessions, when it was built.
    @ViewBuilder private var statusLine: some View {
        if let s = status {
            Text("\(grouped(s.items)) items · \(grouped(s.sessions)) sessions" + (s.built.map { " · built \(PhoneFormat.built($0))" } ?? ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Ask \(c.name)'s past — what did we decide about…", text: $query)
                .textFieldStyle(.plain).font(.custom("Avenir Next", size: 17)).focused($focused)
                .submitLabel(.search).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await search() } }
            if searching { ProgressView().controlSize(.small) }
            else if !query.isEmpty {
                Button { query = ""; found = nil; failed = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? c.color : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
        .shadow(color: focused ? c.color.opacity(0.45) : .clear, radius: 14)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { found = nil; return }
        asked += 1; let mine = asked
        searching = true; failed = nil
        let answer = await client.search(q, kind: who)   // "gh": issues and PRs in one query, as the Mac's Memory page asks
        guard mine == asked else { return }
        searching = false
        if let answer {
            found = answer
            if statusFailed != nil { await readStatus() }   // the Mac just answered: the status banner follows the latest evidence
        } else { failed = PhoneFormat.why(client) }
    }

    /// A session copies the command that reopens it; a note, issue or PR opens its link when it is a web link.
    private func open(_ h: CompanionAPI.SearchHit) {
        if h.kind == "history" { WorkFormat.copy(h.url); flash(h.id) }
        else if let u = URL(string: h.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") { openURL(u) }
        else { WorkFormat.copy(URL(string: h.url)?.path ?? h.url); flash(h.id) }   // a note's file lives on the Mac: its path
    }
    private func flash(_ id: String) {
        copied = id
        Task { try? await Task.sleep(for: .seconds(1.8)); if copied == id { copied = nil } }
    }
}

/// One result, as the Mac's HitCard draws it: the match, what it is, when, the title, a glowing bar, the snippet.
struct PhoneHitCard: View {
    let hit: CompanionAPI.SearchHit
    let oracleName: String
    let copied: Bool
    let action: () -> Void
    private var label: String {
        hit.kind == "pr" ? "PR" : hit.kind == "note" ? "ψ note" : hit.kind == "history" ? (hit.state == "user" ? "you" : oracleName) : "issue"
    }
    private var meta: String {
        switch hit.kind {
        case "note": return "\(hit.repo) · ψ/\(hit.state)\(hit.number > 0 ? " · part \(hit.number + 1)" : "")"
        case "history": return copied ? "command copied ✓" : "session · \(String(hit.updated.dropFirst(11).prefix(5)))"
        default: return "\(hit.repo)#\(hit.number)"
        }
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", max(0, Double(hit.score)) * 100)).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(PhoneStyle.hit).frame(width: 40, alignment: .leading)
                    Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(hit.kind == "note" || hit.kind == "history" ? String(hit.updated.prefix(10)) : hit.state.lowercased())
                        .font(.caption2).foregroundStyle(hit.state == "OPEN" ? Color.green : Color.secondary).lineLimit(1)
                    Text(meta).font(.caption.monospaced()).foregroundStyle(copied ? PhoneStyle.hit : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                Text(hit.title).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                GeometryReader { g in   // the match, as a glowing bar
                    let w = g.size.width * CGFloat(max(0, min(1, (hit.score - 0.4) / 0.5)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(LinearGradient(colors: [PhoneStyle.hit.opacity(0.5), PhoneStyle.hit], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w).shadow(color: PhoneStyle.hit.opacity(0.7), radius: 6)
                    }
                }
                .frame(height: 3)
                if !hit.snippet.isEmpty { Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).phoneCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trace: every query asked of the Mac's memory, newest first

struct PhoneTraceView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var trace: CompanionAPI.Trace?
    @State private var failed: String?
    @State private var readAt: Date?             // when a read last worked: a failing one keeps the list and says since when
    @State private var who = "all"               // all · mcp · page · companion
    @State private var open: UUID?
    @State private var reading = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var c: OracleConfig { store.config }
    private var narrow: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "list.bullet.rectangle",
                              gives: "Every query asked of \(c.name)'s memory — from its pages, over MCP and from phones — who asked, and what came back first.")
            }
        }
        .navigationTitle("Trace")
    }

    /// Who asked, as a row shows it: the caller the Mac measured, else "you" on a page.
    static func from(_ e: TraceLog.Entry) -> String { e.caller ?? (e.source == "mcp" ? "caller not recorded" : "you") }
    private func tint(_ e: TraceLog.Entry) -> Color { e.source == "mcp" ? .orange : e.source == "page" ? c.color : .cyan }

    private var page: some View {
        let all: [TraceLog.Entry] = (trace?.entries ?? []).reversed()
        let sources = ["page", "mcp", "companion"].filter { s in all.contains { $0.source == s } }
        let rows = who == "all" ? all : all.filter { $0.source == who }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                PhoneHeader(eyebrow: "TRACE", title: c.name.hasSuffix("s") ? "\(c.name)' trace" : "\(c.name)'s trace",
                            subtitle: "Every query asked of \(c.name)'s memory — from its pages, over MCP and from phones — who asked, and what came back first.",
                            accent: c.color)
                    .padding(.bottom, 6)
                if sources.count > 1 {
                    PhoneSegments(options: [("all", "All")] + sources.map { ($0, $0 == "mcp" ? "MCP" : $0.capitalized) }, selection: $who, accent: c.color)
                }
                Text("\(grouped(rows.count)) of \(all.count >= 200 ? "the newest " : "")\(grouped(all.count)) queries")   // client.trace reads 200
                    .font(.caption).foregroundStyle(.secondary)
                if let failed { PhoneReadFailure(problem: failed, since: readAt) { Task { await load() } } }
                if trace != nil && all.isEmpty && failed == nil {
                    Text("no query yet — search the Memory page, or ask over MCP").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
                ForEach(rows) { e in row(e) }
            }
            .padding(.horizontal, narrow ? 18 : 28).padding(.vertical, 18)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if trace == nil && failed == nil { ProgressView() } }
        .refreshable { await load() }
        .onAppear { Task { await load() } }
        .onForeground { Task { await load() } }
        .onChange(of: client.pairing) { trace = nil; readAt = nil; Task { await load() } }
        .onChange(of: client.reachable) { _, now in if now == true, failed != nil { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
    }

    /// The same row as the Mac's TraceView: when, PAGE · MCP · COMPANION, the query, who asked, the best hit; a tap shows them all.
    private func row(_ e: TraceLog.Entry) -> some View {
        let cost = narrow ? String(format: "%.0f ms", e.embedMs + e.rankMs) : String(format: "%.0f + %.1f ms · %@ ranked", e.embedMs, e.rankMs, grouped(e.pool))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(PhoneFormat.when(e.at)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                Text(e.source.uppercased()).foregroundStyle(tint(e)).lineLimit(1).fixedSize()
                if !narrow { Text("\"\(e.query)\"").lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: 0)
                Text(cost).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            if narrow { Text("\"\(e.query)\"").lineLimit(open == e.id ? 4 : 2).truncationMode(.tail) }
            Text("   " + Self.from(e)).foregroundStyle(tint(e).opacity(0.9)).lineLimit(1)
            if open == e.id {
                Text("   \(e.filter) · \(grouped(e.pool)) ranked · \(e.via) · \(e.index)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(e.top.enumerated()), id: \.offset) { i, h in
                    Text(String(format: "   %d. %.0f%%  %@", i + 1, Double(h.score) * 100, h.title)).lineLimit(2)
                }
            } else if let top = e.top.first {
                Text(String(format: "   best %.0f%% · %@", Double(top.score) * 100, top.title)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: narrow ? 11 : 12, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(open == e.id ? 0.08 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { open = open == e.id ? nil : e.id }
    }

    private func load() async {
        if reading { return }
        reading = true; defer { reading = false }
        if let t = await client.shielded({ await $0.trace() }) { trace = t; readAt = Date(); failed = nil } else { failed = PhoneFormat.why(client) }
    }
}

#endif
