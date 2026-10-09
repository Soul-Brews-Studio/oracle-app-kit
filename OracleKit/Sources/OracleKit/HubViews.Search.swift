#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Search issues & PRs by meaning — embedded on the ANE (EmbeddingGemma 2 via Chippy :11435)

struct IndexSearchView: View {
    private static var launchQueryDone = false   // launch arguments last the whole process: apply -hubQuery once
    private static var launchActionDone = false
    @ObservedObject var store: HubStore
    @ObservedObject var index: GHIndex
    @ObservedObject private var load = ModelLoad.shared
    var focusTick = 0
    @State private var query = ""
    @State private var kind = "all"
    @State private var openOnly = false
    @FocusState private var fieldFocused: Bool
    private var slugs: [String] { Array(Set(store.oracles.compactMap { $0.checkout.flatMap(GHIndex.slug(fromCheckout:)) })).sorted() }
    private var vaults: [String] { store.oracles.compactMap(\.checkout) }   // their ψ vaults
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                // Relic Studio's Embedding screen, for issues & PRs (Nat: "like this")
                Text("SEMANTIC MEMORY").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(Color.orange)
                Text("Issues, PRs & ψ notes").font(.custom("Avenir Next", size: 34).weight(.bold))
                Text("Every oracle's issues, pull requests and ψ vault notes, ready for meaning.").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 22) {
                    CoverageRing(ready: index.docs.count, pending: index.pending, running: index.running,
                                 progress: index.phase == "embedding" ? Double(index.textDone) / Double(max(1, index.textTotal))
                                         : index.phase == "reading" ? Double(index.repoDone) / Double(max(1, index.repoTotal)) : nil,
                                 phase: index.phase)
                        .frame(width: 230)
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Vector engine", systemImage: "cpu").font(.headline).foregroundStyle(HubStyle.accent).padding(.bottom, 8)
                        EngineRow(name: "Engine", value: index.engine.map { $0.ok ? ($0.kind.hasPrefix("bundled") ? $0.kind : "\($0.kind) · 127.0.0.1:11435 · \($0.workers) workers") : "not answering" } ?? "checking…")
                        if load.loading || load.failed != nil || load.absent { ModelLoadRow(load: load, fallback: index.engine?.ok == true && index.engine?.kind.hasPrefix("bundled") == false) }
                        if index.engine?.kind.hasPrefix("bundled") == true { NeuralEngineRow() }
                        if !load.absent { EnginePicker(load: load) }
                        EngineRow(name: "Model", value: GHIndex.model)
                        EngineRow(name: "Model check", value: index.engine.map { $0.ok && $0.models.contains(GHIndex.model) ? "✓ served" : "✗ not served — nothing embeds this model yet: see the debug log" } ?? "—",
                                  good: index.engine.map { $0.ok && $0.models.contains(GHIndex.model) })
                        EngineRow(name: "Vector space", value: index.engine.map { String($0.space.prefix(36)) + ($0.space.count > 36 ? "…" : "") } ?? "—")
                        EngineRow(name: "Index", value: "\(index.docs.count) items · \(index.docs.filter { $0.kind == "note" }.count) notes · \(Set(index.docs.map(\.repo)).count) oracles" + (index.built.map { " · built \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        Divider().padding(.vertical, 10)
                        Label("Batch controls", systemImage: "square.stack.3d.up").font(.headline).foregroundStyle(Color.orange).padding(.bottom, 8)
                        HStack(spacing: 10) {
                            if index.running {
                                Button { index.stop() } label: {
                                    Label(index.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(index.stopping).handCursor()
                                .keyboardShortcut(".", modifiers: .command)
                                .help("Stop the batch (⌘.) — reading: the index stays as it was; embedding: what is done is kept, the rest keeps its old vectors")
                            } else {
                                Button { Task { await index.index(repos: slugs, vaults: vaults, why: "Run batch button") } } label: {
                                    Label("Run batch", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).disabled(slugs.isEmpty || index.cooldown).handCursor()
                                .help("Read issues + PRs of \(slugs.count) oracle repos with gh; embed only what is new or changed")
                            }
                            Button { Task { await index.reembedAll(repos: slugs, vaults: vaults) } } label: {
                                Label("Re-embed all", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.cyan).controlSize(.large).disabled(index.running || index.cooldown || index.docs.isEmpty).handCursor()
                            .help("Embed all \(index.docs.count) items again — in-process on this Mac's Neural Engine once the bundled model has loaded. Watch the speed and the debug log.")
                            Button { Task { await index.checkEngine() } } label: { Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).controlSize(.large).handCursor()
                        }
                        if index.running || !index.rateHistory.isEmpty {
                            LiveTelemetry(index: index).padding(.top, 10)
                        }
                        if !index.progress.isEmpty {
                            Text(index.progress).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        if let p = index.problem { Text(p).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 6) }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                }
                DebugLogView()
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Ask by meaning — flood sensors, ontology of the fleet, ANE speed…   ⌘F", text: $query)
                        .textFieldStyle(.plain).font(.custom("Avenir Next", size: 16)).focused($fieldFocused)
                        .onSubmit { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } }
                    if index.searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(fieldFocused ? HubStyle.accent : Color.primary.opacity(0.1), lineWidth: fieldFocused ? 1.5 : 1))
                .shadow(color: fieldFocused ? HubStyle.accent.opacity(0.45) : .clear, radius: 14)
                .animation(.easeOut(duration: 0.2), value: fieldFocused)
                HStack(spacing: 12) {
                    Picker("", selection: $kind) { Text("All").tag("all"); Text("Issues").tag("issue"); Text("PRs").tag("pr"); Text("Notes").tag("note") }
                        .pickerStyle(.segmented).frame(width: 300)
                    Toggle("Open only", isOn: $openOnly).toggleStyle(.checkbox)
                    Spacer()
                }
                .onChange(of: kind) { if !query.isEmpty { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } } }
                .onChange(of: openOnly) { if !query.isEmpty { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } } }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(index.hits.enumerated()), id: \.element.id) { i, h in
                        HitCard(hit: h, rank: i)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(Double(i) * 0.03), value: index.hits.map(\.id))
                    }
                    if index.hits.isEmpty && !query.isEmpty && !index.searching {
                        Text("press ↩ to search").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .onChange(of: focusTick) { fieldFocused = true }
        .onAppear { if focusTick > 0 { fieldFocused = true } }
        .onChange(of: load.finished) { Task { await index.checkEngine() } }   // the bundled model is ready: show it
        .task {   // -hubAction reembed | batch: once the bundled model is up, Re-embed all or Run batch (to time the ANE, test Stop)
            let action = UserDefaults.standard.string(forKey: "hubAction") ?? ""   // -hubAction reembed | batch
            guard !Self.launchActionDone, action == "reembed" || action == "batch" else { return }
            Self.launchActionDone = true   // launch arguments last the whole process: run it once
            for _ in 0..<1200 where ModelLoad.shared.loading || store.oracles.isEmpty {   // 10 min at most
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }   // the page went away
            }
            let stopAfter = UserDefaults.standard.double(forKey: "hubStopAfter")   // -hubStopAfter 15: press Stop 15 s in (tests Stop)
            if stopAfter > 0 { Task { try? await Task.sleep(for: .seconds(stopAfter)); index.stop() } }
            if action == "batch" { await index.index(repos: slugs, vaults: vaults, why: "-hubAction batch (test)") } else { await index.reembedAll(repos: slugs, vaults: vaults) }
        }
        .task {
            GHIndex.active = index
            await index.checkEngine()
            if !Self.launchQueryDone, let q = UserDefaults.standard.string(forKey: "hubQuery"), !q.isEmpty, query.isEmpty {   // -hubQuery "…", once
                Self.launchQueryDone = true
                query = q; await index.search(q)
            }
        }
        .task {   // first visit, or older than 6 h: refresh the index in the background
            if !index.running, let why = index.staleReason {
                if store.oracles.isEmpty { await store.refresh() }
                await index.index(repos: slugs, vaults: vaults, why: "automatic on opening Search — \(why)")
            }
        }
    }
}

struct HitCard: View {
    let hit: IndexHit
    var rank = 0
    var oracleName = "oracle"
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        let d = hit.doc
        Button {
            if d.kind == "history" {   // a session line: copy the command that reopens the session
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.url, forType: .string)
                copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } else if let u = URL(string: d.url) { NSWorkspace.shared.open(u) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", max(0, hit.score) * 100)).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(HubStyle.accent).frame(width: 40, alignment: .leading)
                    Text(d.kind == "pr" ? "PR" : d.kind == "note" ? "ψ note" : d.kind == "history" ? (d.state == "user" ? "you" : oracleName) : "issue").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(d.kind == "note" || d.kind == "history" ? String(d.updated.prefix(10)) : d.state.lowercased()).font(.caption2).foregroundStyle(d.state == "OPEN" ? Color.green : Color.secondary)
                    Text(d.kind == "note" ? "\(d.repo) · ψ/\(d.state)\(d.number > 0 ? " · part \(d.number + 1)" : "")" : d.kind == "history" ? (copied ? "resume command copied ✓" : "session · \(String(d.updated.dropFirst(11).prefix(5)))") : "\(d.repo)#\(d.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(d.title).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(2)
                GeometryReader { g in   // the match, as a glowing bar
                    let w = g.size.width * CGFloat(max(0, min(1, (hit.score - 0.4) / 0.5)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(LinearGradient(colors: [HubStyle.accent.opacity(0.5), HubStyle.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w).shadow(color: HubStyle.accent.opacity(0.7), radius: 6)
                    }
                }
                .frame(height: 3)
                if !d.snippet.isEmpty { Text(d.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? HubStyle.accent.opacity(0.6) : Color.clear, lineWidth: 1))
            .shadow(color: hover ? HubStyle.accent.opacity(0.35) : .clear, radius: 12)
            .scaleEffect(hover ? 1.008 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .help(d.kind == "history" ? "Click to copy:  " + d.url : d.url)
    }
}
#endif
