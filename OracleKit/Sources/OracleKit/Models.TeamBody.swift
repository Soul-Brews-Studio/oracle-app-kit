import Foundation

/// An oracle's team bodies. Home is `config.localPath`, the oracle's own repo; a team body is a checkout of another
/// repo (often a worktree of a team desk) whose root `CLAUDE.local.md` imports the oracle's own CLAUDE.md with a line
/// `@<home>/CLAUDE.md`. An agent working there is this oracle, so the Work page counts its panes too.
public enum TeamBody {
    /// The file a body reads at its root, keyed by path: its mtime and whether it imports a home (nil: no file).
    nonisolated(unsafe) static var cache: [String: (mtime: Date?, text: String?)] = [:]
    static let lock = NSLock()

    /// The checkout's own `CLAUDE.local.md`, read again only when its mtime changes (a machine has hundreds of trees).
    static func localFile(_ checkout: String) -> String? {
        let path = checkout + "/CLAUDE.local.md"
        var st = stat()   // plain stat: FileManager's attributes cost ~5x more over hundreds of trees
        let mtime = stat(path, &st) == 0
            ? Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9) : nil
        lock.lock(); defer { lock.unlock() }
        if let c = cache[path], c.mtime == mtime { return c.text }
        let text = mtime == nil ? nil : (try? String(contentsOfFile: path, encoding: .utf8))
        cache[path] = (mtime, text)
        return text
    }

    /// A path with its symlinks resolved, so a symlinked checkout root still matches.
    static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// True when the checkout's `CLAUDE.local.md` has a line importing `<home>/CLAUDE.md` (`@~/…` is read as the home dir).
    /// Both sides are compared with their symlinks resolved.
    public static func imports(checkout: String, home: String) -> Bool {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, !checkout.isEmpty, checkout != home, !checkout.hasPrefix(home + "/"), let text = localFile(checkout) else { return false }
        let lines = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var l = raw.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("@"), l.hasSuffix("/CLAUDE.md") else { return nil }
            l.removeFirst(); l.removeLast("/CLAUDE.md".count)   // the folder: it resolves even when the file is missing
            return l.isEmpty ? nil : l.hasPrefix("~/") ? NSHomeDirectory() + l.dropFirst() : l
        }
        guard !lines.isEmpty else { return false }
        let want = real(home)
        return lines.contains { real($0) == want }
    }

    /// Every body among the worktrees `maw herdr ls --json` lists, stopped ones too, so a stopped body keeps its Resume.
    public static func bodies(ls: Data, home: String) -> [String] {
        guard let l = try? JSONSerialization.jsonObject(with: ls) as? [String: Any] else { return [] }
        return (l["worktrees"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            .filter { imports(checkout: $0, home: home) }
    }

    /// True when `path` is one of `roots` or inside one.
    public static func under(_ path: String, roots: [String]) -> Bool {
        roots.contains { !$0.isEmpty && (path == $0 || path.hasPrefix($0 + "/")) }
    }
}
