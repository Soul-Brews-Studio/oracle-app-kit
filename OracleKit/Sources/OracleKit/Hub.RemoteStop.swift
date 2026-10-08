#if os(macOS)
import Foundation

/// Stop saved herdr machines' sessions from the Network page (#100): one, or every running one on a host. Before the
/// confirmation, the same check as a local Stop, through `herdr --machine <id> agent list`: which agents herdr
/// resumes on reopen and which come back as plain shells (a machine without herdr's claude/codex integration records
/// none). The stop is `herdr --machine <id> server stop`; afterwards the machines are probed again (#98).
public typealias ResumeCheck = (resumes: [String: Int], lost: [String])

extension HubStore {
    /// RemoteSession.id → what reopening it brings back; nil when a machine did not answer.
    public func remoteResume(_ sessions: [RemoteSession]) async -> [String: ResumeCheck]? {
        var all: [String: ResumeCheck] = [:]
        for r in sessions {
            guard let out = await Self.remoteHerdr(r, ["agent", "list"], viaSSH: remoteState[r.id]?.viaSSH == true), out.status == 0,
                  let c = RemoteParse.resume(agentList: out.out) else { return nil }
            all[r.id] = c
        }
        return all
    }

    /// Stops them; nil when every one stopped, else the commands to run for the ones that did not.
    public func stopRemote(_ sessions: [RemoteSession]) async -> String? {
        var failed: [String] = []
        for r in sessions {
            let ssh = remoteState[r.id]?.viaSSH == true
            if await Self.remoteHerdr(r, ["server", "stop"], viaSSH: ssh, timeout: 30)?.status != 0 {
                failed.append(ssh ? "ssh \(r.target) 'herdr --session \(r.session) server stop'" : "herdr --machine \(r.label ?? r.profileId ?? r.host) server stop")
            }
        }
        await refresh(remotes: true)
        return failed.isEmpty ? nil : "Did not stop. Run it in a terminal to see why:\n  " + failed.joined(separator: "\n  ")
    }

    /// Start a saved machine's stopped session: herdr has no `session start`, so, as a local Start does, run its server
    /// in the background (`herdr --session <s> server`) over ssh, then wait for `--machine <id> status server`.
    public func startRemote(_ r: RemoteSession) async -> String? {
        let cmd = "ssh \(r.target) 'PATH=$HOME/.local/bin:$PATH; nohup herdr --session \(r.session) server >/dev/null 2>&1 &'"
        guard r.isSafe, r.profileId != nil else { return nil }
        let start = "export PATH=$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; "
            + "nohup herdr --session \(r.session) server >/dev/null 2>&1 </dev/null & echo started"
        guard await Shell.run("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", r.target, start], timeout: 20) != nil else {
            return "ssh did not answer without a prompt — run:  \(cmd)"
        }
        for _ in 0..<10 {
            if let s = await Self.remoteHerdr(r, ["status", "server"], viaSSH: remoteState[r.id]?.viaSSH == true, timeout: 15), s.status == 0,
               RemoteParse.statusField("status", in: s.out) == "running" {
                await refresh(remotes: true); return nil
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await refresh(remotes: true)
        return "\(r.session) did not answer within 10 s — run:  \(cmd)"
    }

    /// Detach this Mac from a remote session: end the local `herdr --remote` client(s) attached to it. The session
    /// and its agents keep running on the other machine. nil when done, else the command to run.
    public func detachRemote(_ r: RemoteSession) async -> String? {
        let ps = await Shell.run("ps", ["-axo", "pid=,args="]) ?? ""
        let pids = ps.split(separator: "\n").compactMap { line -> Int32? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]),
                  RemoteParse.remote(of: String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces))?.id == r.id else { return nil }
            return pid
        }
        let failed = pids.filter { kill($0, SIGTERM) != 0 }
        await refresh()
        if pids.isEmpty { return "No herdr client here is attached to \(r.session) on \(r.host). Check:  ps -axo pid,args | rg 'herdr --remote'" }
        return failed.isEmpty ? nil : "Could not end the client. Run:  kill " + failed.map(String.init).joined(separator: " ")
    }
}
#endif
