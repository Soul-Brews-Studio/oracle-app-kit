#if os(macOS)
import SwiftUI

/// An oracle's own memory: every session of its repo on this Mac — what you asked and what it answered — scanned
/// first, then embedded on demand and searched by meaning. The hub's semantic-memory page, for one oracle.
/// Read the relic way (SessionHistory): main threads only, prose embedded, tools counted for later.
struct HistoryView: View {
    private static var actionDone = false   // launch arguments last the whole process: run the test action once
    let config: OracleConfig
    @ObservedObject private var index: GHIndex
    @ObservedObject private var load = ModelLoad.shared
    @State private var query = ""
    @State private var who = "all"
    @FocusState private var focused: Bool

    init(config: OracleConfig) {
        self.config = config
        _index = ObservedObject(wrappedValue: GHIndex.history(config.repoSlug))
    }

    private var sessions: Int { Set(index.docs.filter { $0.kind == "history" }.map(\.url)).count }
    private var since: String { index.docs.map(\.updated).filter { !$0.isEmpty }.min().map { String($0.prefix(10)) } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("SEMANTIC MEMORY").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(config.color)
                Text("\(config.name)'s memory").font(.custom("Avenir Next", size: 34).weight(.bold))
                Text("Every session, ψ note, issue and PR of \(config.repoSlug) — what you asked, what \(config.name) answered and wrote down, ready for meaning.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 22) {
                    CoverageRing(ready: index.docs.count, pending: index.pending, running: index.running,
                                 progress: index.phase == "embedding" ? Double(index.textDone) / Double(max(1, index.textTotal))
                                         : index.phase == "reading" ? Double(index.repoDone) / Double(max(1, index.repoTotal)) : nil,
                                 phase: index.phase, readingLabel: "READING SESSIONS")
                        .frame(width: 230)
                    card
                }
                DebugLogView()
                searchField
                HStack(spacing: 12) {
                    Picker("", selection: $who) {
                        Text("All").tag("all"); Text("You").tag("user"); Text(config.name).tag("assistant")
                        Text("ψ notes").tag("note"); Text("Issues & PRs").tag("gh")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 430)
                    Text("a session result copies the command that reopens it").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .onChange(of: who) { if !query.isEmpty { Task { await search() } } }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(index.hits.enumerated()), id: \.element.id) { i, h in
                        HitCard(hit: h, rank: i, oracleName: config.name)
                    }
                    if index.hits.isEmpty && !query.isEmpty && !index.searching {
                        Text(index.docs.isEmpty ? "nothing embedded yet — Scan, then Run batch" : "press ↩ to search")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .onChange(of: load.finished) { Task { await index.checkEngine() } }
        .task {
            GHIndex.active = index
            await index.checkEngine()
            // the model loads when this page is first opened, not at launch: an oracle app should not hold it unasked
            if GHIndex.loaded == nil, !load.loading, load.failed == nil, !load.absent {
                load.reload?(UserDefaults.standard.string(forKey: "hub.engineMode") ?? "gpu")
            }
            if index.scanned == nil, !index.running {   // scan first: how much there is, before anything is embedded
                await index.indexMemory(repo: config.repoSlug, checkout: config.localPath, embed: false, why: "page opened — scan first")
            }
            if !Self.actionDone, UserDefaults.standard.string(forKey: "memoryAction") == "batch" {   // -memoryAction batch (tests)
                Self.actionDone = true
                for _ in 0..<1200 where ModelLoad.shared.loading { do { try await Task.sleep(for: .milliseconds(500)) } catch { return } }
                await index.indexMemory(repo: config.repoSlug, checkout: config.localPath, embed: true, why: "-memoryAction batch (test)")
                if let q = UserDefaults.standard.string(forKey: "memoryQuery"), !q.isEmpty { query = q; await search() }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Vector engine", systemImage: "cpu").font(.headline).foregroundStyle(config.color).padding(.bottom, 8)
            EngineRow(name: "Engine", value: index.engine.map { $0.ok ? ($0.kind.hasPrefix("bundled") ? $0.kind : "\($0.kind) · 127.0.0.1:11435") : "loading…" } ?? "checking…")
            if load.loading || load.failed != nil || load.absent {
                ModelLoadRow(load: load, fallback: index.engine?.ok == true && index.engine?.kind.hasPrefix("bundled") == false)
            }
            if index.engine?.kind.hasPrefix("bundled") == true { NeuralEngineRow() }
            if !load.absent { EnginePicker(load: load) }
            if !load.root.isEmpty {
                EngineRow(name: "Loaded from", value: load.root + (load.finished.flatMap { f in load.started.map { String(format: " · ready in %.1f s", f.timeIntervalSince($0)) } } ?? ""))
            }
            StorageRow(index: index)
            EngineRow(name: "Index", value: "\(grouped(index.docs.count)) items · \(grouped(sessions)) sessions"
                      + (since.isEmpty ? "" : " · since \(since)")
                      + (index.built.map { " · built \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
            Divider().padding(.vertical, 10)
            Label("Scan", systemImage: "doc.text.magnifyingglass").font(.headline).foregroundStyle(Color.cyan).padding(.bottom, 6)
            if let c = index.scanned {
                EngineRow(name: "Transcripts", value: "\(grouped(c.filesOurs)) are \(config.name)'s, of \(grouped(c.files)) read · \(grouped(c.bytes / 1_000_000)) MB new")
                EngineRow(name: "Said", value: "\(grouped(c.prose)) user + assistant · tools \(grouped(c.toolUse + c.toolResult)) (later) · thinking \(grouped(c.thinking)) (never)")
                EngineRow(name: "To embed", value: c.newChunks == 0 ? "no new session pieces" : "\(grouped(c.newChunks)) new pieces of \(grouped(c.distinct)) distinct")
                if let p = index.plan, p.need > 0 {
                    EngineRow(name: "Vector cache", value: "\(grouped(p.hits)) of \(grouped(p.need)) embedded before — reused · \(grouped(p.need - p.hits)) to embed",
                              good: p.hits == p.need ? true : nil)
                }
                if let sd = index.sideScan {
                    EngineRow(name: "ψ · GitHub", value: "\(grouped(sd.notes)) notes · \(grouped(sd.issues)) issues · \(grouped(sd.prs)) PRs · \(grouped(sd.new)) to embed")
                }
                EngineRow(name: "Sources", value: index.scannedSources.map(\.label).joined(separator: " · "))
            } else {
                EngineRow(name: "Transcripts", value: index.running ? "scanning…" : "not scanned yet")
            }
            Divider().padding(.vertical, 10)
            Label("Batch controls", systemImage: "square.stack.3d.up").font(.headline).foregroundStyle(Color.orange).padding(.bottom, 8)
            HStack(spacing: 10) {
                if index.running {
                    Button { index.stop() } label: { Label(index.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(index.stopping).handCursor()
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { Task { await index.indexMemory(repo: config.repoSlug, checkout: config.localPath, embed: true, why: "Run batch button") } } label: {
                        Label("Run batch", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).disabled(index.cooldown).handCursor()
                    .help("Read what is new in \(config.name)'s sessions and embed it")
                }
                Button { Task { await index.indexMemory(repo: config.repoSlug, checkout: config.localPath, embed: false, why: "Scan button") } } label: {
                    Label("Scan", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.cyan).controlSize(.large).disabled(index.running || index.cooldown).handCursor()
                .help("Count what there is — nothing is embedded or saved")
                Button { Task { await index.reembedAll(repos: []) } } label: { Label("Re-embed all", systemImage: "bolt.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).disabled(index.running || index.cooldown || index.docs.isEmpty).handCursor()
            }
            if index.running || !index.rateHistory.isEmpty { LiveTelemetry(index: index).padding(.top, 10) }
            if !index.progress.isEmpty { Text(index.progress).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.top, 6) }
            if let p = index.problem { Text(p).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 6) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Ask \(config.name)'s past by meaning — what did we decide about…", text: $query)
                .textFieldStyle(.plain).font(.custom("Avenir Next", size: 16)).focused($focused)
                .onSubmit { Task { await search() } }
            if index.searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(focused ? config.color : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
        .shadow(color: focused ? config.color.opacity(0.45) : .clear, radius: 14)
    }

    private func search() async {
        switch who {
        case "user", "assistant": await index.search(query, kind: "history", state: who)
        case "note": await index.search(query, kind: "note")
        case "gh": await index.search(query, kinds: ["issue", "pr"])
        default: await index.search(query)
        }
    }
}
#endif
