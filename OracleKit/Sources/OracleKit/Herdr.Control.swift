#if os(macOS)
import Foundation

// MARK: - The oracle app opens and closes its own agents and sessions (#116 follow-up, Nat 2026-10-09:
// "neo should can open and close … ourself that neo and session")
//
//   Close  a LIVE pane      → herdr closes it; the agent quits, its conversation stays and shows under RESUMABLE
//   Open   a RESUMABLE one  → ticket.sh open <worktree>: the worktree's own claude session, resumed in a pane
//   Stop   a running session→ herdr session stop: every pane in it ends; Start brings back the agents it saved
// Every call answers nil when it worked, else what failed with the command to run.

public enum HerdrControl {
    /// "laris-co:w22:p1" → ("laris-co", "w22:p1"); a place without a session prefix → nil.
    public static func split(place: String) -> (session: String, pane: String)? {
        let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].contains(":") else { return nil }
        return (parts[0], parts[1])
    }

    /// Close one pane: its agent quits; the conversation stays in its transcript and can be opened again.
    public static func closePane(place: String) async -> String? {
        guard let (s, p) = split(place: place) else { return "cannot tell the session of \(place) — run:  herdr pane close <pane>" }
        let cmd = "herdr --session \(s) pane close \(p)"
        return await Shell.run("herdr", ["--session", s, "pane", "close", p], timeout: 15) != nil ? nil : "herdr did not close \(place) — run:  \(cmd)"
    }

    /// Stop a whole session: its server and every pane in it.
    public static func stopSession(_ name: String) async -> String? {
        await Shell.run("herdr", ["session", "stop", name], timeout: 20) != nil
            ? nil : "herdr could not stop \(name) — run it in a terminal to see why:  herdr session stop \(name)"
    }

    /// Open a resumable worktree: `ticket.sh open <worktree> --json` resumes its own claude session in a pane
    /// (and refuses when that session is open somewhere else: no second writer).
    public static func open(worktree path: String, repo: String) async -> String? {
        let cmd = "maw herdr ticket open \(path) --repo \(repo)"
        guard let r = await ticket(["open", path, "--repo", repo, "--json"]) else {
            return "neither `maw herdr ticket` nor the /herdr-ticket script answered — run:  \(cmd)"
        }
        return outcome(status: r.status, json: r.out, command: cmd)
    }

    /// The old home of /herdr-ticket's script: the fallback while an installed maw lacks the `herdr ticket` verb.
    static var ticketScript: String { NSHomeDirectory() + "/.claude/skills/herdr-ticket/ticket.sh" }

    /// Run /herdr-ticket with these arguments: `maw herdr ticket …` (the script ships with maw-herdr-plugin), else
    /// the old script by path. With `--json` either answers one JSON object on stdout; an answer that is not one
    /// (an older maw: "unknown command") falls through to the script. nil when neither ran.
    public static func ticket(_ args: [String], timeout: TimeInterval = 60) async -> (status: Int32, out: String)? {
        if let r = await Shell.capture("maw", ["herdr", "ticket"] + args, timeout: timeout),
           r.out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return (r.status, r.out)
        }
        guard FileManager.default.fileExists(atPath: ticketScript),
              let r = await Shell.capture("bash", [ticketScript] + args, timeout: timeout) else { return nil }
        return (r.status, r.out)
    }

    /// ticket.sh's --json answer → nil on {"ok":true}, else its error and first fix (or the command).
    public static func outcome(status: Int32, json: String, command: String) -> String? {
        let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        if status == 0, d["ok"] as? Bool ?? true { return nil }
        let why = d["error"] as? String ?? "ticket.sh exited \(status) without saying why"
        let fix = (d["fix"] as? [String])?.first ?? command
        return "\(why) — run:  \(fix)"
    }
}
#endif
