#if os(macOS)
import Foundation

// MARK: - The oracle app opens and closes its own agents and sessions (#116 follow-up, Nat 2026-10-09:
// "neo should can open and close … ourself that neo and session")
//
//   Close  a LIVE pane      → herdr closes it; the agent quits, its conversation stays and shows under RESUMABLE
//                             (a space's last pane, when the space holds worktrees: only the agent ends)
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
    /// herdr will not close the last pane of a space that has linked worktrees ("closing this pane would close a
    /// worktree group", and `pane close` has no way to confirm): there only the agent ends, and the pane stays a shell.
    public static func closePane(place: String) async -> String? {
        guard let (s, p) = split(place: place) else { return "cannot tell the session of \(place) — run:  herdr pane close <pane>" }
        let cmd = "herdr --session \(s) pane close \(p)"
        guard let r = await Shell.capture("herdr", ["--session", s, "pane", "close", p], stderr: true, timeout: 15) else {
            return "herdr did not answer — run:  \(cmd)"
        }
        if r.status == 0 { return nil }
        let e = herdrError(r.out)
        if e?.code == "confirmation_required" { return await endAgent(place: place) }
        return "herdr did not close \(place)\(e.map { ": " + $0.message } ?? "") — run:  \(cmd)"
    }

    /// End a pane's agent and keep the pane: SIGHUP to its foreground process group (what closing the pane sends it),
    /// so the shell under it stays. Only when that group is led by an agent, never the shell itself.
    public static func endAgent(place: String) async -> String? {
        guard let (s, p) = split(place: place) else { return "cannot tell the session of \(place)" }
        let look = "herdr --session \(s) pane process-info --pane \(p)"
        guard let json = await Shell.run("herdr", ["--session", s, "pane", "process-info", "--pane", p], timeout: 10) else {
            return "herdr did not say what runs in \(place) — run:  \(look)"
        }
        if foregroundName(processInfo: json) == nil { return nil }   // only the shell: the agent has already ended
        guard let group = agentGroup(processInfo: json) else {
            return "no agent runs in the foreground of \(place) — see what does:  \(look)"
        }
        return kill(-group, SIGHUP) == 0 ? nil : "could not end the agent in \(place) — run:  kill -HUP -\(group)"
    }

    /// After Stop: close this oracle's spaces in `session` that hold nothing but idle shells. Linked worktree spaces go
    /// first, so the parent is no longer a group and closes as well (Nat, 2026-10-09: "it should close group ws").
    /// A space where something still runs in the foreground, such as a server or an editor, stays. Answers what stayed.
    public static func closeIdleSpaces(_ spaces: [HerdrSpace], session: String) async -> String? {
        var kept: [String] = []
        for sp in spaces.filter({ $0.session == session }).sorted(by: { $0.linked && !$1.linked }) {
            var busy: String?
            for pane in sp.panes { if let fg = await foreground(pane.paneId, session: session) { busy = "\(pane.place) runs \(fg)"; break } }
            if let busy { kept.append(busy); continue }
            if await Shell.run("herdr", ["--session", session, "workspace", "close", sp.workspaceId], timeout: 15) == nil {
                kept.append("\(sp.label) — run:  herdr --session \(session) workspace close \(sp.workspaceId)")
            }
        }
        return kept.isEmpty ? nil : "kept open: " + kept.joined(separator: "; ")
    }

    /// What runs in the foreground of a pane, nil for an idle shell. An agent that was just told to end gets 5 s.
    static func foreground(_ pane: String, session: String) async -> String? {
        for _ in 0..<10 {
            guard let json = await Shell.run("herdr", ["--session", session, "pane", "process-info", "--pane", pane], timeout: 10) else {
                return "something herdr would not describe"
            }
            guard let fg = foregroundName(processInfo: json) else { return nil }
            if agentGroup(processInfo: json) == nil { return fg }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "an agent that did not end"
    }

    /// `herdr pane process-info` → the foreground group leader's argv0, nil when the shell itself is in the foreground.
    static func foregroundName(processInfo json: String) -> String? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let info = (d["result"] as? [String: Any])?["process_info"] as? [String: Any],
              let group = (info["foreground_process_group_id"] as? NSNumber)?.int32Value else { return "an unreadable process list" }
        if group == (info["shell_pid"] as? NSNumber)?.int32Value { return nil }
        let leader = (info["foreground_processes"] as? [[String: Any]])?.first { ($0["pid"] as? NSNumber)?.int32Value == group }
        return (leader?["argv0"] as? String).map { ($0 as NSString).lastPathComponent } ?? "process group \(group)"
    }

    /// herdr's JSON error (`{"error":{"code":…,"message":…}}`, on stderr) → its code and message.
    static func herdrError(_ out: String) -> (code: String, message: String)? {
        for line in out.split(separator: "\n") where line.hasPrefix("{") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let e = d["error"] as? [String: Any], let code = e["code"] as? String else { continue }
            return (code, e["message"] as? String ?? code)
        }
        return nil
    }

    /// `herdr pane process-info` → the pane's foreground process group, when its leader is an agent (claude, codex):
    /// nil when the shell is in the foreground or something else runs there.
    static func agentGroup(processInfo json: String) -> pid_t? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let info = (d["result"] as? [String: Any])?["process_info"] as? [String: Any],
              let group = (info["foreground_process_group_id"] as? NSNumber)?.int32Value, group > 1,
              group != (info["shell_pid"] as? NSNumber)?.int32Value,
              let leader = (info["foreground_processes"] as? [[String: Any]])?
                  .first(where: { ($0["pid"] as? NSNumber)?.int32Value == group }),
              let argv0 = leader["argv0"] as? String,
              ["claude", "codex"].contains((argv0 as NSString).lastPathComponent) else { return nil }
        return group
    }

    /// Stop a whole session: its server and every pane in it.
    public static func stopSession(_ name: String) async -> String? {
        await Shell.run("herdr", ["session", "stop", name], timeout: 20) != nil
            ? nil : "herdr could not stop \(name) — run it in a terminal to see why:  herdr session stop \(name)"
    }

    /// Open a resumable worktree: `ticket.sh open <worktree> --json` resumes its own claude session in a pane
    /// (and refuses when that session is open somewhere else: no second writer).
    /// `sessionId`: resume exactly that conversation. The main checkout needs it — without one ticket.sh takes the
    /// newest transcript in the folder, and in a main checkout that can be any session (a one-shot, a signing resume).
    public static func open(worktree path: String, repo: String, sessionId: String? = nil) async -> String? {
        let idArgs = sessionId.map { ["--session-id", $0] } ?? []
        let cmd = (["maw herdr ticket open", path, "--repo", repo] + idArgs).joined(separator: " ")
        guard let r = await ticket(["open", path, "--repo", repo] + idArgs + ["--json"]) else {
            return "neither `maw herdr ticket` nor the /herdr-ticket script answered — run:  \(cmd)"
        }
        return outcome(status: r.status, json: r.out, command: cmd)
    }

    /// Bring back this oracle's saved agents from a stopped session — only them, not the whole session (Nat,
    /// 2026-10-09). Each resumes exactly its own conversation into `target`, a running session:
    /// `maw herdr ticket open <its worktree> --repo <repo> --session <target> --session-id <id>`. ticket.sh refuses one
    /// that is open somewhere else. nil when all came back, else one line per agent that did not.
    public static func resume(_ agents: [SavedAgent], repo: String, into target: String) async -> String? {
        var failed: [String] = []
        for a in agents {
            guard !a.cwd.isEmpty, FileManager.default.fileExists(atPath: a.cwd) else {
                failed.append("\(a.space): its folder is gone (\(a.cwd))"); continue
            }
            let top = (await Shell.run("git", ["-C", a.cwd, "rev-parse", "--show-toplevel"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? a.cwd
            let args = ["open", top, "--repo", repo, "--session", target, "--session-id", a.sessionId, "--json"]
            let cmd = "maw herdr ticket " + args.dropLast().joined(separator: " ")
            guard let r = await ticket(args) else { failed.append("\(a.space): nothing answered — run:  \(cmd)"); continue }
            if let e = outcome(status: r.status, json: r.out, command: cmd) { failed.append("\(a.space): \(e)") }
        }
        return failed.isEmpty ? nil : failed.joined(separator: "\n")
    }

    /// The ticket.sh the installed maw runs (maw-herdr-plugin's own copy).
    static var mawTicketScript: String { NSHomeDirectory() + "/.maw/plugins/herdr/scripts/herdr-ticket/ticket.sh" }

    /// Whether the installed maw's ticket.sh knows `flag`.
    static func mawKnows(_ flag: String) -> Bool {
        (try? String(contentsOfFile: mawTicketScript, encoding: .utf8))?.contains(flag) ?? false
    }

    /// The old home of /herdr-ticket's script: the fallback while an installed maw lacks the `herdr ticket` verb.
    static var ticketScript: String { NSHomeDirectory() + "/.claude/skills/herdr-ticket/ticket.sh" }

    /// Run /herdr-ticket with these arguments: `maw herdr ticket …` (the script ships with maw-herdr-plugin), else
    /// the old script by path. With `--json` either answers one JSON object on stdout; an answer that is not one
    /// (an older maw: "unknown command") falls through to the script. nil when neither ran.
    public static func ticket(_ args: [String], timeout: TimeInterval = 60) async -> (status: Int32, out: String)? {
        // an installed plugin older than maw-herdr-plugin #119 has no --session-id: its ticket.sh would take the id as
        // text and quietly resume the worktree's newest conversation instead — so skip maw for that call
        let usable = !args.contains("--session-id") || mawKnows("--session-id")
        if usable, let r = await Shell.capture("maw", ["herdr", "ticket"] + args, timeout: timeout),
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
