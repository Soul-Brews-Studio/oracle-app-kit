#if os(macOS)
import Foundation

/// Stop herdr sessions on another machine from the Network page (#100): one, or every running one on a machine.
/// Before the confirmation, the same check as a local Stop, read over ssh: which agents herdr resumes on reopen and
/// which come back as plain shells (a machine without herdr's claude/codex integration records none). After the
/// stop the machines are probed again, so a stopped session does not stay green (#98).
public typealias ResumeCheck = (resumes: [String: Int], lost: [String])

extension HubStore {
    private static let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]

    /// RemoteSession.id → what reopening it brings back; nil when a machine did not answer.
    public func remoteResume(_ sessions: [RemoteSession]) async -> [String: ResumeCheck]? {
        var all: [String: ResumeCheck] = [:]
        for (target, group) in Dictionary(grouping: sessions.filter(\.isSafe), by: \.target) {
            let cmd = RemoteParse.agentsCommand(sessions: group.map(\.session)) + "; true"
            guard let out = await Shell.run("ssh", Self.ssh + [target, cmd], timeout: 25) else { return nil }
            for (name, r) in RemoteParse.resume(out) { all[RemoteSession(target: target, session: name).id] = r }
        }
        return all
    }

    /// Stops them; nil when every one stopped, else the commands to run for the ones that did not.
    public func stopRemote(_ sessions: [RemoteSession]) async -> String? {
        var failed: [String] = []
        for (target, group) in Dictionary(grouping: sessions.filter(\.isSafe), by: \.target) {
            let names = group.map(\.session)
            let out = await Shell.run("ssh", Self.ssh + [target, RemoteParse.stopCommand(sessions: names)], timeout: 40)
            failed += RemoteParse.stopFailures(out ?? "", asked: names)
                .map { "ssh \(target) 'PATH=$HOME/.local/bin:$PATH; herdr session stop \($0)'" }
        }
        await refresh(remotes: true)
        return failed.isEmpty ? nil : "Did not stop. Run it in a terminal to see why:\n  " + failed.joined(separator: "\n  ")
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
