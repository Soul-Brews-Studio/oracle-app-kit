#if os(macOS)
import Foundation

/// Who asked over MCP — measured, not claimed: the client's own name (clientInfo at initialize, else its
/// User-Agent), and the process on the other end of the loopback connection: its repo (from its working
/// directory, so the oracle), its herdr pane, its command. `said` is what the caller called itself (`from`).
public struct MCPCaller: Sendable, Equatable {
    public var client = ""      // "claude-code 2.1.4"
    public var pid: Int32 = 0
    public var command = ""     // claude · codex · node (via claude)
    public var repo = ""        // laris-co/neo-oracle
    public var pane = ""        // herdr: "laris-co w22:pA"
    public var said = ""

    /// "Neo · claude-code 2.1.4 · laris-co w22:pA" — the oracle first, then the system, then where it sits.
    public var label: String {
        let oracle = repo.split(separator: "/").last.map { HubParse.displayName(String($0)) } ?? ""
        let known = [oracle, repo, String(repo.split(separator: "/").last ?? "")].map { $0.lowercased() }
        let saidNew = !said.isEmpty && !known.contains(said.lowercased())
        return [oracle.isEmpty ? command : oracle, client, pane, saidNew ? "says \(said)" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The process holding the client end of a loopback TCP connection whose client port is `port`.
    static func resolve(port: UInt16) async -> MCPCaller {
        var c = MCPCaller()
        let me = ProcessInfo.processInfo.processIdentifier
        guard let out = await Shell.run("lsof", ["-nP", "-iTCP:\(port)", "-sTCP:ESTABLISHED", "-Fp"], timeout: 3),
              let pid = out.split(separator: "\n").compactMap({ $0.hasPrefix("p") ? Int32($0.dropFirst()) : nil }).first(where: { $0 != me })
        else { return c }
        c.pid = pid
        if let cwd = await Shell.run("lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 3)?
            .split(separator: "\n").first(where: { $0.hasPrefix("n") })?.dropFirst() {
            c.repo = SessionHistory.repoKey(String(cwd)) ?? ""
        }
        // `ps eww`: the command line, then its environment — where a herdr pane names itself. A system binary
        // (curl) shows no environment, so ask its parents too, up to the pane's shell.
        var p = pid
        for depth in 0..<4 {
            guard let ps = await Shell.run("ps", ["eww", "-o", "ppid=,command=", "-p", "\(p)"], timeout: 3) else { break }
            let words = ps.split(separator: " ")
            if depth == 0, words.count > 1 { c.command = String(words[1].split(separator: "/").last ?? words[1]) }
            func env(_ k: String) -> String? { words.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
            if let s = env("HERDR_SESSION"), let pane = env("HERDR_PANE_ID") { c.pane = "\(s) \(pane)"; break }
            guard let up = words.first.flatMap({ Int32($0) }), up > 1 else { break }
            p = up
        }
        // a bridge (node, bun, python) speaks for the agent that started it: name that agent too
        if ["node", "bun", "npx", "uvx", "python", "python3"].contains(c.command),
           let pp = await Shell.run("ps", ["-o", "ppid=", "-p", "\(pid)"], timeout: 3)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parent = await Shell.run("ps", ["-o", "comm=", "-p", pp], timeout: 3)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            c.command += " (via \(parent.split(separator: "/").last.map(String.init) ?? parent))"
        }
        return c
    }
}
#endif
