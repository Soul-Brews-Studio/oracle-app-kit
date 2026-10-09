#if os(macOS)
import Foundation

// MARK: - After a reboot, start the sessions that were running (#116)
//
// Only the hub does this, so seven oracle apps never race on one session; an oracle app's Start is a human's click.
// Once per launch, only within 30 minutes of boot, only sessions whose session.json was written as the Mac went down,
// and never one whose saved agents are already live: herdr would resume them a second time, so those wait for a human
// and are listed with the command.

extension HubStore {
    /// Runs once per hub launch. Returns what it held back, for `problems`.
    func autostartAfterReboot() async -> [String] {
        guard let boot = HerdrPlaces.bootTime(), Date().timeIntervalSince(boot) < 30 * 60,
              let t = await Shell.run("herdr", ["session", "list", "--json"]) else { return [] }
        let sessions = HubParse.sessions(Data(t.utf8))
        var savedAt: [String: Date] = [:]
        for s in sessions where !s.running {
            if let dir = s.dir, let d = HerdrPlaces.modified(dir + "/session.json") { savedAt[s.name] = d }
        }
        let live = await HerdrPlaces.liveNow(sessions)
        var held: [String] = []
        for name in HerdrPlaces.runningAtShutdown(stopped: savedAt, boot: boot) {
            guard let dir = sessions.first(where: { $0.name == name })?.dir,
                  let data = FileManager.default.contents(atPath: dir + "/session.json") else { continue }
            let dups = HerdrPlaces.duplicates(HerdrPlaces.parse(sessionJSON: data, roots: nil).agents, live: live)
            if dups.isEmpty {
                if let err = await HerdrPlaces.start(name) { held.append(err) }
            } else {
                held.append("\(name) was running before the reboot but holds \(dups.count) agent(s) already live elsewhere; "
                            + "start it by hand when that is fine — run:  herdr --session \(name) server")
            }
        }
        return held
    }
}
#endif
