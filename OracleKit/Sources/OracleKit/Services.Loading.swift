#if os(macOS)
import Foundation

extension OracleStore {
    /// One `maw herdr ls` pair (≈0.6 s for every session) instead of one herdr call per session.
    func loadTree() async -> (rows: [StatusRow], panes: [AgentPane])? {
        async let ls = Shell.run("maw", ["herdr", "ls", "--json"], timeout: 15)
        async let ag = Shell.run("maw", ["herdr", "ls", "--agents", "--json"], timeout: 15)
        if let l = await ls, let a = await ag {
            lastLs = Data(l.utf8)
            let rows = MawParse.rows(ls: Data(l.utf8), agents: Data(a.utf8), localPath: config.localPath)
            let panes = rows.filter { $0.depth == 2 }.map {
                AgentPane(session: "", paneId: $0.id, name: $0.title, agent: "", status: $0.status, cwd: "", title: $0.title) }
            return (rows, panes)
        }
        guard let panes = await loadPanes() else { return nil }      // fallback: herdr directly
        return (panes.map { StatusRow(id: $0.id, depth: 2, glyph: "", live: $0.status == "working",
                                      title: "\($0.agent)  \($0.name)", detail: "\($0.session):\($0.paneId) · \($0.status)", status: $0.status) }, panes)
    }

    /// Each pane's current task: herdr's terminal title (Claude Code titles a session by its topic).
    /// A pane named after the oracle carries no task, so fall back to its tab label.
    func loadActivity() async -> [OracleSnapshot.Activity] {
        guard let table = await Shell.run("herdr", ["session", "list"]) else { return [] }
        let repoName = (config.localPath as NSString).lastPathComponent
        let herdrWT = NSHomeDirectory() + "/.herdr/worktrees/" + repoName
        var out: [OracleSnapshot.Activity] = []
        var found: [HerdrSpace] = []
        for s in HerdrParse.runningSessions(table: table) {
            // one call per session gives both the agents and herdr's own layout (spaces · tabs · split rects)
            guard let json = await Shell.run("herdr", ["--session", s, "api", "snapshot"]) else { continue }
            let snap = HerdrSnapshot.parse(Data(json.utf8), session: s)
            found += HerdrSnapshot.mine(snap.spaces, roots: [config.localPath, herdrWT])
            for a in snap.agents {
                let cwd = a["cwd"] as? String ?? ""
                guard HerdrParse.belongs(AgentPane(session: s, paneId: "", name: "", agent: "", status: "", cwd: cwd, title: ""), to: config.localPath)
                        || cwd == herdrWT || cwd.hasPrefix(herdrWT + "/") else { continue }
                let pane = a["pane_id"] as? String ?? "?"
                var title = (a["terminal_title_stripped"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let generic = title.isEmpty || title == (a["name"] as? String) || title.lowercased() == repoName.lowercased()
                    || title == "Claude Code" || title == "zsh"
                let sid = (a["agent_session"] as? [String: Any])?["value"] as? String
                if generic {
                    // what was last asked of this pane: its own transcript's last typed prompt
                    if (a["agent"] as? String) == "claude", let sid, let ask = OracleStore.lastPrompt(cwd: cwd, session: sid) {
                        title = ask
                    } else {
                        let inWT = cwd.hasPrefix(config.localPath + "/wt/") || cwd.hasPrefix(herdrWT + "/")
                        let leaf = (cwd as NSString).lastPathComponent
                        title = inWT ? (leaf.hasPrefix("worktree") ? leaf : "worktree " + leaf) : "\(config.name) main"
                    }
                }
                out.append(.init(title: title, status: a["agent_status"] as? String ?? "idle", place: "\(s):\(pane)", cwd: cwd, session: sid))
            }
        }
        spaces = found
        return out
    }

    /// Last prompt a human (or agent) typed into a Claude session: the tail of
    /// ~/.claude/projects/<cwd with / and . as ->/<session>.jsonl, cached by file size.
    nonisolated(unsafe) static var promptCache: [String: (size: UInt64, prompt: String?)] = [:]
    /// One line of what a human asked, or nil for machine traffic (pane reports, agent relays, wrappers).
    nonisolated static func humanAsk(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // a slash command: <command-name>/impeccable</command-name> … <command-args>styling …</command-args>
        if let n = s.range(of: #"<command-name>[^<]*</command-name>"#, options: .regularExpression) {
            let name = s[n].replacingOccurrences(of: #"</?command-name>"#, with: "", options: .regularExpression)
            var args = ""
            if let r = s.range(of: #"<command-args>[\s\S]*?</command-args>"#, options: .regularExpression) {
                args = s[r].replacingOccurrences(of: #"</?command-args>"#, with: "", options: .regularExpression)
            }
            s = (name + " " + args).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // pasted text: keep the inside, unless it is a pane/terminal report
        if s.hasPrefix("<pasted_content") {
            s = s.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let machine = ["<", "PANE ", "TERMINAL ", "[from ", "[reply", "[CHECK-IN", "[checkin", "[SYSTEM", "[Request interrupted",
                       "Caveat:", "[Image", "Another Claude session", "This session is being continued", "Tool loaded",
                       "Base directory for this skill", "(Re-invocation of", "Concise output style"]
        if s.isEmpty || machine.contains(where: { s.hasPrefix($0) }) { return nil }
        s = String(s.split(separator: "\n").first ?? "")
        s = s.replacingOccurrences(of: #"^[❯>$#]\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    nonisolated static func lastPrompt(cwd: String, session: String) -> String? {
        let dir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let path = NSHomeDirectory() + "/.claude/projects/" + dir + "/" + session + ".jsonl"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        if let c = promptCache[path], c.size == size { return c.prompt }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        // Walk back in 2 MB steps (up to 24 MB): a busy session's tail is mostly tool output and screenshots.
        let step: UInt64 = 2 * 1024 * 1024, cap: UInt64 = 24 * 1024 * 1024
        var end = size, found: String?
        var carry = Data()
        while found == nil && end > 0 && size - end < cap {
            let start = end > step ? end - step : 0
            try? fh.seek(toOffset: start)
            var chunk = fh.readData(ofLength: Int(end - start)) + carry
            // keep the partial first line for the next (earlier) chunk
            if start > 0, let nl = chunk.firstIndex(of: 0x0A) {
                carry = chunk.subdata(in: chunk.startIndex..<nl); chunk = chunk.subdata(in: nl..<chunk.endIndex)
            } else { carry = Data() }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"type\":\"user\""), !line.contains("\"tool_result\""),
                      let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let m = o["message"] as? [String: Any] else { continue }
                var t: String?
                if let c = m["content"] as? String { t = c }
                else if let parts = m["content"] as? [[String: Any]] {
                    t = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.first
                }
                guard let raw = t, let s = OracleStore.humanAsk(raw) else { continue }
                found = s.count > 70 ? String(s.prefix(69)) + "…" : s
                break
            }
            end = start
        }
        promptCache[path] = (size, found)
        return found
    }

    private func loadPanes() async -> [AgentPane]? {
        guard let table = await Shell.run("herdr", ["session", "list"]) else { return nil }
        var all: [AgentPane] = []
        for s in HerdrParse.runningSessions(table: table) {
            if let out = await Shell.run("herdr", ["--session", s, "agent", "list"]) {
                all += HerdrParse.agents(json: Data(out.utf8), session: s).filter { HerdrParse.belongs($0, to: config.localPath) }
            }
        }
        return all.sorted { ($0.status, $0.paneId) < ($1.status, $1.paneId) }
    }

    func loadGitHubCLI() async -> ([GHItem], [GHItem])? {
        async let pr = Shell.run("gh", ["pr", "list", "-R", config.repoSlug, "--state", "open", "--limit", "50",
                                        "--json", "number,title,author,updatedAt,url,isDraft,headRefName,closingIssuesReferences"], timeout: 20)
        async let iss = Shell.run("gh", ["issue", "list", "-R", config.repoSlug, "--state", "open", "--limit", "50",
                                         "--json", "number,title,author,updatedAt,url"], timeout: 20)
        guard let a = await pr, let b = await iss else { return nil }
        return (GHParse.items(json: Data(a.utf8)), GHParse.items(json: Data(b.utf8)))
    }

    /// Newest 300 files, at most 2 folders deep. Runs off the main thread: neo's inbox holds 4,000+ entries.
    nonisolated public static func scanInbox(_ root: String) -> [InboxItem] {
        guard !root.isEmpty, let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var items: [InboxItem] = []
        while let rel = e.nextObject() as? String {
            if e.level > 2 { e.skipDescendants(); continue }
            let full = root + "/" + rel
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &dir), !dir.boolValue,
                  !rel.hasPrefix("."), !(rel as NSString).lastPathComponent.hasPrefix(".") else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            let folder = rel.contains("/") ? String(rel.split(separator: "/").first!) : "inbox"
            items.append(InboxItem(path: full, name: (rel as NSString).lastPathComponent, folder: folder,
                                   modified: attrs?[.modificationDate] as? Date ?? .distantPast))
        }
        return items.sorted { $0.modified > $1.modified }.prefix(300).map { $0 }
    }

    nonisolated public static func copyIntoInbox(_ urls: [URL], config: OracleConfig) -> Int {
        guard !config.inboxPath.isEmpty else { return 0 }
        let dest = URL(fileURLWithPath: config.inboxPath + "/dropped")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = f.string(from: Date())
        var n = 0
        for u in urls {
            var target = dest.appendingPathComponent("\(stamp)_\(u.lastPathComponent)")
            var i = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = dest.appendingPathComponent("\(stamp)_\(i)_\(u.lastPathComponent)"); i += 1
            }
            let scheme = (u.scheme ?? "").lowercased()
            guard u.isFileURL || scheme == "http" || scheme == "https" else { continue }   // never our own oracle-* links
            if u.isFileURL {
                if (try? FileManager.default.copyItem(at: u, to: target)) != nil { n += 1 }
            } else {
                // a web link (browser address bar, bookmark, tab): keep it as a small markdown note
                let slug = ((u.host ?? "link") + u.path).replacingOccurrences(of: "/", with: "-")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(80)
                let note = dest.appendingPathComponent("\(stamp)_\(slug).md")
                let body = "# \(u.absoluteString)\n\n- url: <\(u.absoluteString)>\n- dropped: \(stamp)\n- for: \(config.name)\n"
                if (try? body.write(to: note, atomically: true, encoding: .utf8)) != nil { n += 1 }
            }
        }
        return n
    }
}
#endif
