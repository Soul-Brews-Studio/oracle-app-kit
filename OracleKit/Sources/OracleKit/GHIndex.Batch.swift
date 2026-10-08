import Foundation
import CryptoKit

extension GHIndex {
    // MARK: index

    /// Why nothing can embed: which state the bundled model is in, and the command that helps.
    func noEmbedderProblem() -> String {
        if let f = ModelLoad.shared.failed {
            return "no embedder: the bundled model did not load (\(f)) and nothing answers on 127.0.0.1:11435 — press Retry on the engine card, or check the service:  curl -s 127.0.0.1:11435/health"
        }
        if ModelLoad.shared.absent {
            return "no embedder: this build carries no model and nothing answers on 127.0.0.1:11435 — start an embedding service there, then:  curl -s 127.0.0.1:11435/health"
        }
        return "no embedder answered:  curl -s 127.0.0.1:11435/health"
    }

    /// Pull issues + PRs of every repo, embed what is new or changed on the ANE, save.
    /// `why` goes to the debug log. `reembed` embeds every item again, not only new or changed ones.
    /// Stop ends it between steps: while reading nothing changes; while embedding what is done is kept.
    public func index(repos slugs: [String], vaults: [String] = [], why: String, reembed: Bool = false) async {
        guard !running else { HubLog.shared.add(.info, "a batch is already running — \(why) skipped"); return }
        running = true; stopRequested = false; problem = nil
        defer { endRun() }
        HubLog.shared.add(.info, "batch: \(slugs.count) repos — \(why)" + (built.map { " · index built \(Int(Date().timeIntervalSince($0) / 60)) min ago" } ?? " · no index yet")
                          + (reembed ? " · embed everything again" : ""))
        guard await alive() else {
            problem = noEmbedderProblem(); HubLog.shared.add(.error, problem ?? ""); progress = ""; return
        }
        phase = "reading"; repoTotal = slugs.count; repoDone = 0; textDone = 0; textTotal = 0; rateHistory = []
        defer { phase = "idle"; currentRepo = "" }
        let tRead = Date()
        // gh is network-bound (~2 s a repo): read 6 repos at a time, log each as it lands, keep the input order.
        var byRepo: [Int: [IndexDoc]] = [:]
        var finished = 0
        let stopped = await withTaskGroup(of: (Int, String, RepoRead).self) { group -> Bool in
            var next = 0
            func start() { let i = next, repo = slugs[i]; next += 1; group.addTask { (i, repo, await Self.read(repo)) } }
            while next < min(6, slugs.count) { start() }
            while let item = await group.next() {
                let (i, repo, r) = item
                byRepo[i] = r.docs; finished += 1
                r.errors.forEach { HubLog.shared.add(.error, $0) }
                HubLog.shared.add(.read, "\(repo): \(r.issues) issues · \(r.prs) PRs · \(r.ms) ms")
                repoDone = finished; currentRepo = repo
                progress = "reading \(repo) (\(finished)/\(slugs.count))"
                if stopRequested { group.cancelAll(); return true }
                if next < slugs.count { start() }
            }
            return false
        }
        if stopped {
            progress = "stopped while reading (\(finished)/\(slugs.count) repos) — the index is unchanged"
            HubLog.shared.add(.info, progress); return
        }
        var fresh = slugs.indices.flatMap { byRepo[$0] ?? [] }
        if !vaults.isEmpty {   // every oracle's ψ notes, read off the main actor
            progress = "reading the ψ vaults of \(vaults.count) oracles"
            let tv = Date()
            let notes = await Task.detached(priority: .userInitiated) { GHIndex.readVaults(vaults) }.value
            fresh += notes.docs
            HubLog.shared.add(.read, String(format: "ψ vaults: %@ notes from %d vaults in %.1f s (memory, inbox folders, writing, outbox, active, lab; skipped %@ inbox messages)",
                                            grouped(notes.docs.count), notes.vaults, Date().timeIntervalSince(tv), grouped(notes.skipped)))
        }
        // The space this run's vectors land in. Another space than the stored one makes every old vector useless.
        let runSpace = bundled()?.space ?? serviceSpace
        let moved = space != nil && runSpace != nil && space != runSpace && !docs.isEmpty
        if moved { HubLog.shared.add(.info, "the embedder's vector space is not the index's (\(space?.prefix(36) ?? "")… → \(runSpace?.prefix(36) ?? "")…): embedding everything again") }
        let everything = reembed || moved
        // reuse the vector of anything whose embedded text did not change
        let old = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if !everything {
            for i in fresh.indices { if let o = old[fresh[i].id], o.hash == fresh[i].hash, !o.vec.isEmpty { fresh[i].vec = o.vec } }
        }
        let need = fresh.indices.filter { fresh[$0].vec.isEmpty }
        let target = everything || space == nil ? runSpace : space
        let (todo, hits) = reembed ? (need, 0) : await fromCache(&fresh, need, space: target)   // Re-embed all computes anew
        HubLog.shared.add(.info, String(format: "read %@ items from %d repos in %.1f s · %@ unchanged · %@ from the vector cache · %@ to embed",
                                        grouped(fresh.count), slugs.count, Date().timeIntervalSince(tRead), grouped(fresh.count - need.count),
                                        grouped(hits), grouped(todo.count)))
        repoDone = slugs.count; phase = "embedding"; textTotal = todo.count
        let t0 = Date()
        let done = await embedChunks(&fresh, todo, want: target)
        let complete = done == todo.count
        if !complete && !moved {   // stopped or failed midway: what was not reached keeps its old entry, so the next run embeds it
            for i in fresh.indices where fresh[i].vec.isEmpty { if let o = old[fresh[i].id], !o.vec.isEmpty { fresh[i] = o } }
        }
        docs = fresh.filter { !$0.vec.isEmpty }
        pending = fresh.count - docs.count
        lastRun = (done, fresh.count - todo.count, Date().timeIntervalSince(t0))
        repos = slugs
        if let target { space = target }
        if complete { built = Date() }   // a partial run does not count as fresh: the 6 h refresh still comes
        save()
        let secs = Date().timeIntervalSince(t0)
        if complete {
            progress = todo.isEmpty ? "up to date — nothing new to embed" : "embedded \(done) in \(String(format: "%.1f", secs)) s (\(Int(Double(done) / max(secs, 0.001))) texts/s, \(via)), \(fresh.count - todo.count) reused"
        } else {
            progress = "\(stopRequested ? "stopped" : "stopped early") after \(done)/\(todo.count) — " + (moved ? "\(pending) items wait for the next run" : "the rest keep their old vectors")
        }
        HubLog.shared.add(.info, "batch done — " + progress)
    }

    /// The notes of every oracle's ψ vault, as index entries (no vector yet). Only main checkouts (a worktree's ψ is
    /// the same vault), each real vault once (symlinked vaults are shared), and only the note folders: memory, inbox
    /// subfolders (handoffs…), writing, outbox, active, lab — never learn/ (cloned repos) and not the flat ψ/inbox/*.md
    /// files, which are maw and timekeeper message traffic, not notes.
    /// `everything` (an oracle's own vault, Nat: "all psi vault / retrospective / inbox / everything"): every folder
    /// and the flat inbox messages too, long notes in pieces — only cloned repos (a folder with its own .git; symlinked
    /// clones are not followed) and another oracle's vault nested inside (a folder with its own memory/ and inbox/,
    /// like ψ/soul-brews-studio/arra-oracle-v3) stay out. The same text in two files is kept once.
    nonisolated static func readVaults(_ checkouts: [String], everything: Bool = false) -> (docs: [IndexDoc], vaults: Int, skipped: Int) {
        let fm = FileManager.default
        var seen = Set<String>(), docs: [IndexDoc] = [], skipped = 0, texts = Set<String>()
        let iso = ISO8601DateFormatter()
        for checkout in checkouts where !checkout.contains("/wt/") {
            let real = URL(fileURLWithPath: checkout).appendingPathComponent("ψ").resolvingSymlinksInPath()
            guard fm.fileExists(atPath: real.path), seen.insert(real.path).inserted else { continue }
            let owner = slug(fromCheckout: checkout) ?? URL(fileURLWithPath: checkout).lastPathComponent
            for top in everything ? [""] : ["memory", "inbox", "writing", "outbox", "active", "lab"] {
                let dir = top.isEmpty ? real : real.appendingPathComponent(top)
                guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                               options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in walk {
                    let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    if v?.isDirectory == true {
                        let name = url.lastPathComponent
                        if everything {
                            let clone = fm.fileExists(atPath: url.appendingPathComponent(".git").path)
                            let vault = fm.fileExists(atPath: url.appendingPathComponent("memory").path) && fm.fileExists(atPath: url.appendingPathComponent("inbox").path)
                            if clone || vault || ["node_modules", "build", "dist"].contains(name) { walk.skipDescendants(); skipped += 1 }
                        } else if ["learn", "node_modules", ".git", "build", "dist"].contains(name) { walk.skipDescendants() }
                        continue
                    }
                    guard url.pathExtension == "md", (v?.fileSize ?? 0) < 1_000_000 else { continue }
                    if !everything, top == "inbox", url.deletingLastPathComponent().path == dir.path { skipped += 1; continue }
                    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    var body = Substring(raw)
                    if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
                        body = body[end.upperBound...]   // drop YAML front matter
                    }
                    let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let heading = lines.first { $0.hasPrefix("#") }.map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
                    let title = heading.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
                    let folder = url.deletingLastPathComponent().path == real.path ? "" :
                        url.deletingLastPathComponent().path.replacingOccurrences(of: real.path + "/", with: "")
                    let updated = v?.contentModificationDate.map { iso.string(from: $0) } ?? ""
                    // the hub: one piece per note (its start); an oracle's own vault: the whole note, in pieces
                    let pieces = everything ? SessionHistory.chunks(String(body).trimmingCharacters(in: .whitespacesAndNewlines)) : [String(body)]
                    for (n, piece) in pieces.enumerated() {
                        let text = docText(title: title, body: piece)
                        let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                        if everything, !texts.insert(hash).inserted { continue }   // the same text in another file
                        let plines = n == 0 ? lines.filter { !$0.hasPrefix("#") } : piece.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        docs.append(IndexDoc(repo: owner, kind: "note", number: n, title: title, state: folder, url: url.absoluteString,
                                             updated: updated, snippet: String(plines.prefix(2).joined(separator: " · ").prefix(220)), hash: hash, vec: [], text: text))
                    }
                }
            }
        }
        return (docs, seen.count, skipped)
    }

    /// One repo's issues and PRs as index entries (no vector yet).
    struct RepoRead: Sendable { var docs: [IndexDoc] = []; var issues = 0, prs = 0, ms = 0; var errors: [String] = [] }
    nonisolated private static func read(_ repo: String) async -> RepoRead {
        let t0 = Date()
        var r = RepoRead()
        for kind in ["issue", "pr"] {
            let fields = "number,title,body,state,url,updatedAt"
            guard let out = await Shell.run("gh", [kind, "list", "-R", repo, "--state", "all", "-L", "300", "--json", fields], timeout: 40),
                  let rows = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] else {
                r.errors.append("\(repo): gh \(kind) list gave nothing (no access, or \(kind == "issue" ? "issues are off" : "no PRs")):  gh \(kind) list -R \(repo) -L 1")
                continue
            }
            if kind == "issue" { r.issues = rows.count } else { r.prs = rows.count }
            for row in rows {
                let title = row["title"] as? String ?? "", body = row["body"] as? String ?? ""
                let text = docText(title: title, body: body)
                let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                let snippet = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2).joined(separator: " · ")
                r.docs.append(IndexDoc(repo: repo, kind: kind, number: row["number"] as? Int ?? 0, title: title,
                                       state: row["state"] as? String ?? "", url: row["url"] as? String ?? "",
                                       updated: row["updatedAt"] as? String ?? "", snippet: String(snippet.prefix(220)), hash: hash, vec: [], text: text))
            }
        }
        r.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return r
    }

    /// One oracle's own memory, and only its own: its sessions on this Mac (Claude Code + Codex, read the relic way,
    /// only what was appended since the last run), its ψ vault, its GitHub issues and PRs. A scan counts what there is
    /// and changes nothing on disk; with `embed`, what is new or changed is embedded and saved.
    public func indexMemory(repo: String, checkout: String, embed: Bool, why: String) async {
        guard !running else { HubLog.shared.add(.info, "a run is already going — \(why) skipped"); return }
        running = true; stopRequested = false; problem = nil
        defer { endRun() }
        HubLog.shared.add(.info, "\(embed ? "memory batch" : "memory scan"): \(repo) — \(why)")
        phase = "reading"; repoTotal = 1; repoDone = 0; textDone = 0; textTotal = 0; rateHistory = []
        defer { phase = "idle"; currentRepo = "" }
        // 1 · sessions
        progress = "scanning transcripts…"
        let t0 = Date()
        // a scan just before: start from where it stopped reading, so the batch reads only what changed since
        let base = embed ? pendingScan : nil
        let verbose = UserDefaults.standard.object(forKey: "hub.verboseLog") as? Bool ?? true   // the debug log's Verbose box
        let known = Set(docs.filter { $0.kind == "history" }.map(\.hash)).union(base?.docs.map(\.hash) ?? []), start = base?.ledger ?? ledger
        stopFlag = StopFlag()
        let flag = stopFlag
        var say: (@Sendable (String) -> Void)? = nil
        if verbose { say = { line in GHIndex.logRead(line) } }
        let sayLine = say
        let r = await Task.detached(priority: .userInitiated) {
            SessionHistory.collect(repo: repo, ledger: start, known: known, stop: flag, verbose: sayLine) { done, total in
                Task { @MainActor in self.repoDone = done; self.repoTotal = max(total, 1); self.progress = "scanning transcripts \(done)/\(total)" }
            }
        }.value
        let newPieces = (base?.docs ?? []) + r.docs
        if !embed { pendingScan = (r.docs, r.ledger) } else { pendingScan = nil }
        scanned = r.counts; scannedSources = r.sources
        let c = r.counts
        HubLog.shared.add(.read, String(format: "sessions: %@ transcripts read in %.1f s (%@ of them %@'s, %@ MB new) from %d sources: %@",
                                        grouped(c.files), Date().timeIntervalSince(t0), grouped(c.filesOurs), repo, grouped(c.bytes / 1_000_000),
                                        r.sources.count, r.sources.map(\.label).joined(separator: ", ")))
        let before = base.map { " (+ \(grouped($0.docs.count)) from the scan before)" } ?? ""
        let said = "said: \(grouped(c.prose)) prose (user + assistant) · \(grouped(c.short)) too short · \(grouped(c.host)) host text · "
        let rest = "tools \(grouped(c.toolUse + c.toolResult)) (later) · thinking \(grouped(c.thinking)) (never) · \(grouped(c.distinct)) distinct pieces, \(grouped(r.docs.count)) new"
        HubLog.shared.add(.read, said + rest + before)
        if stopRequested { progress = "stopped while scanning — the index is unchanged"; HubLog.shared.add(.info, progress); return }
        // 2 · its own ψ vault and its own issues and PRs: the current set replaces the old one; unchanged keeps its vector
        progress = "reading the ψ vault and GitHub…"
        let tv = Date()
        let vault = checkout.isEmpty ? [] : await Task.detached(priority: .userInitiated) { GHIndex.readVaults([checkout], everything: true).docs }.value
        let gh = await Self.read(repo)
        gh.errors.forEach { HubLog.shared.add(.error, $0) }
        let oldSide = Dictionary(docs.filter { $0.kind != "history" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var side = vault + gh.docs
        for i in side.indices { if let o = oldSide[side[i].id], o.hash == side[i].hash, !o.vec.isEmpty { side[i].vec = o.vec } }
        let sideNew = side.filter { $0.vec.isEmpty }.count
        sideScan = (vault.count, gh.issues, gh.prs, sideNew)
        HubLog.shared.add(.read, String(format: "own ψ vault: %@ notes · GitHub: %@ issues, %@ PRs · %@ new or changed · %.1f s",
                                        grouped(vault.count), grouped(gh.issues), grouped(gh.prs), grouped(sideNew), Date().timeIntervalSince(tv)))
        if stopRequested { progress = "stopped while reading — the index is unchanged"; HubLog.shared.add(.info, progress); return }
        // pieces embedded in an older form (the session title inside every piece): the same pieces, embedded again
        let hist = docs.filter { $0.kind == "history" }
        let stale = hist.indices.filter { !(hist[$0].text ?? "").hasPrefix("title: none |") }
        var fresh = hist + side + newPieces
        let staleTexts = stale.map { fresh[$0].text }
        for i in stale {
            let body = (fresh[i].text ?? "").components(separatedBy: " | text: ").dropFirst().joined(separator: " | text: ")
            let piece = body.hasPrefix("asked: ") ? String(body.dropFirst(7)) : body.hasPrefix("answered: ") ? String(body.dropFirst(10)) : body
            fresh[i].text = SessionHistory.embedText(piece)
        }
        let sideTodo = (hist.count..<(hist.count + side.count)).filter { fresh[$0].vec.isEmpty }
        let need = stale + sideTodo + Array((hist.count + side.count)..<fresh.count)   // older pieces, notes/issues/PRs, then new pieces
        // the plan: every piece hashed and looked up first — what the cache has is reused, only the rest is embedded
        guard embed else {
            let hits = await cacheHits(need.map { fresh[$0].text ?? "" }, space: space ?? bundled()?.space ?? serviceSpace)
            let left = need.count - hits
            pending = left; plan = (need.count, hits)
            let est = Double(left) / max(rateHistory.last ?? 0, lastRateEstimate)
            progress = need.isEmpty ? "scan: up to date — nothing new"
                : "scan: \(grouped(need.count)) to place (\(grouped(newPieces.count)) session pieces, \(grouped(sideNew)) notes/issues/PRs\(stale.isEmpty ? "" : ", \(grouped(stale.count)) older pieces")) · \(grouped(hits)) from the vector cache · \(grouped(left)) to embed\(left > 0 ? ", ~\(Self.duration(est))" : "")"
            HubLog.shared.add(.info, progress)
            return
        }
        if need.isEmpty {   // nothing to embed; notes, issues or PRs that are gone leave the index
            docs = fresh; ledger = r.ledger; built = Date(); save(); pending = 0
            progress = "up to date — nothing new in \(repo)'s memory"; HubLog.shared.add(.info, progress); return
        }
        guard await alive() else { problem = noEmbedderProblem(); HubLog.shared.add(.error, problem ?? ""); progress = ""; return }
        let runSpace = bundled()?.space ?? serviceSpace
        if let sp = space, let rs = runSpace, sp != rs, !docs.isEmpty {
            problem = "this index is in another vector space (\(sp.prefix(32))…) — press Re-embed all"; HubLog.shared.add(.error, problem ?? ""); return
        }
        if !stale.isEmpty { HubLog.shared.add(.info, "\(grouped(stale.count)) session pieces were embedded with their session title — placing them again, alone") }
        let (todo, hits) = await fromCache(&fresh, need, space: space ?? runSpace)
        plan = (need.count, hits)
        HubLog.shared.add(.info, "\(grouped(need.count)) to place: \(grouped(hits)) from the vector cache (embedded before, by any app) · \(grouped(todo.count)) to embed")
        phase = "embedding"; textTotal = todo.count; repoDone = repoTotal
        let t1 = Date()
        let done = await embedChunks(&fresh, todo, want: space ?? runSpace)
        let unreached = Set(todo[min(done, todo.count)...])
        for (k, i) in stale.enumerated() where unreached.contains(i) { fresh[i].text = staleTexts[k] }   // still the old form: found again next run
        docs = fresh.filter { !$0.vec.isEmpty }
        pending = fresh.count - docs.count
        if let rs = runSpace, space == nil { space = rs }
        if done == todo.count { ledger = r.ledger; built = Date() }   // a stopped run reads the same lines again next time
        save()
        let secs = Date().timeIntervalSince(t1)
        lastRateEstimate = secs > 1 ? Double(done) / secs : lastRateEstimate
        progress = done == todo.count
            ? "embedded \(grouped(done)) in \(String(format: "%.1f", secs)) s (\(Int(Double(done) / max(secs, 0.001))) texts/s, \(via))"
            : "\(stopRequested ? "stopped" : "stopped early") after \(grouped(done))/\(grouped(todo.count)) — kept; the rest next run"
        HubLog.shared.add(.info, "memory batch done — " + progress)
    }

    // MARK: the shared vector cache

    /// Fills what the shared vector cache already has for `todo` (in `space`) and returns what is left to embed.
    /// Hashing and lookup run off the main actor.
    private func fromCache(_ fresh: inout [IndexDoc], _ todo: [Int], space: String?) async -> (left: [Int], hits: Int) {
        guard let space, !todo.isEmpty else { return (todo, 0) }
        let texts = todo.map { fresh[$0].text ?? fresh[$0].title }
        let hit = await Task.detached(priority: .userInitiated) { VectorCache.shared.get(space, texts) }.value
        var left: [Int] = []
        for (k, i) in todo.enumerated() { if let v = hit[texts[k]], !v.isEmpty { fresh[i].vec = v } else { left.append(i) } }
        return (left, todo.count - left.count)
    }
    /// How many of these texts the cache already has — the scan's count; nothing changes.
    private func cacheHits(_ texts: [String], space: String?) async -> Int {
        guard let space, !texts.isEmpty else { return 0 }
        let hit = await Task.detached(priority: .userInitiated) { VectorCache.shared.get(space, texts) }.value
        return texts.reduce(0) { $0 + (hit[$1] == nil ? 0 : 1) }
    }

    /// Embed every item again, on this Mac's ANE once the bundled model has loaded — the way to rebuild every vector,
    /// and to watch the Neural Engine work. No GitHub calls when the index carries the embedded text (batches since
    /// 2026-10-07 store it); an older index reads the repos first.
    public func reembedAll(repos slugs: [String], vaults: [String] = []) async {
        guard !docs.isEmpty, docs.allSatisfy({ $0.text != nil }) else {
            await index(repos: slugs, vaults: vaults, why: "Re-embed all (the index has no stored text yet, so read the repos first)", reembed: true)
            return
        }
        guard !running else { HubLog.shared.add(.info, "a batch is already running — Re-embed all skipped"); return }
        running = true; stopRequested = false; problem = nil
        defer { endRun() }
        HubLog.shared.add(.info, "re-embed all: \(grouped(docs.count)) stored items, no GitHub calls")
        guard await alive() else {
            problem = noEmbedderProblem(); HubLog.shared.add(.error, problem ?? ""); progress = ""; return
        }
        phase = "embedding"; repoTotal = 0; repoDone = 0; textDone = 0; textTotal = docs.count; rateHistory = []
        defer { phase = "idle" }
        let runSpace = bundled()?.space ?? serviceSpace
        let moved = space != nil && runSpace != nil && space != runSpace
        var fresh = docs
        let t0 = Date()
        let done = await embedChunks(&fresh, Array(fresh.indices), want: runSpace)
        let complete = done == fresh.count
        if !complete && moved { fresh = Array(fresh.prefix(done)) }   // never keep vectors of two spaces side by side
        pending = docs.count - fresh.count
        docs = fresh
        if let runSpace, complete || moved { space = runSpace }
        if complete { built = Date() }
        save()
        let secs = Date().timeIntervalSince(t0)
        progress = complete ? "re-embedded \(grouped(done)) in \(String(format: "%.1f", secs)) s (\(Int(Double(done) / max(secs, 0.001))) texts/s, \(via))"
                            : "\(stopRequested ? "stopped" : "stopped early") after \(grouped(done))/\(grouped(fresh.count + pending)) re-embedded"
        HubLog.shared.add(.info, "re-embed done — " + progress)
    }

    /// Embeds the docs at `todo`, 32 per call, one log line per call, every vector in the space `want` (when known);
    /// stops at Stop. Returns how many got a vector — the first `done` of `todo`, in order.
    private func embedChunks(_ fresh: inout [IndexDoc], _ todo: [Int], want: String?) async -> Int {
        let t0 = Date()
        let before = bundled()?.activity()
        defer { logSplit(from: before) }
        var done = 0
        let chunks = stride(from: 0, to: todo.count, by: 32).map { Array(todo[$0..<min($0 + 32, todo.count)]) }
        for (n, chunk) in chunks.enumerated() {
            if stopRequested { break }
            let inputs = chunk.map { fresh[$0].text ?? fresh[$0].title }
            guard let vecs = await embed(inputs, log: "call \(n + 1)/\(chunks.count)", want: want), vecs.count == chunk.count else {
                problem = refusal ?? "embedding stopped after \(done)/\(todo.count) — " + noEmbedderProblem()
                break
            }
            for (k, idx) in chunk.enumerated() { fresh[idx].vec = vecs[k] }
            if let cs = want ?? (via.hasPrefix("in-process") ? bundled()?.space : serviceSpace) {   // never computed again, by any app
                let items = zip(inputs, vecs).map { (text: $0.0, vec: $0.1) }
                Task.detached(priority: .utility) { VectorCache.shared.put(cs, items) }
            }
            done += chunk.count
            let rate = Double(done) / max(0.001, Date().timeIntervalSince(t0))
            textDone = done; rateHistory.append(rate); if rateHistory.count > 60 { rateHistory.removeFirst() }
            progress = "embedding \(via.hasPrefix("in-process") ? via : "via 127.0.0.1:11435") \(done)/\(todo.count) · \(Int(rate)) texts/s"
        }
        return done
    }

    /// Where the in-process time of a run went, summed over the workers: the Neural Engine's predict calls versus the
    /// CPU work around them (staging the inputs, pooling the outputs) — says whether the ANE or the CPU is the limit.
    private func logSplit(from before: EmbedActivity?) {
        guard let before, let after = bundled()?.activity(), after.calls > before.calls else { return }
        let predict = after.predictSeconds - before.predictSeconds, stage = after.stageSeconds - before.stageSeconds
        let pool = after.poolSeconds - before.poolSeconds, total = max(predict + stage + pool, 0.001)
        HubLog.shared.add(.info, String(format: "time split over %d calls: predict %.1f s (%.0f%%) · CPU staging %.1f s (%.0f%%) · pooling %.1f s (%.0f%%) · %.0f ms predict per call",
                                        after.calls - before.calls, predict, predict / total * 100, stage, stage / total * 100,
                                        pool, pool / total * 100, predict / Double(after.calls - before.calls) * 1000))
    }
}
