#if os(macOS)
import Foundation

// MARK: - After a reboot, start the sessions that were running (#116)
//
// Only the hub does this, so seven oracle apps never race on one session; an oracle app's Start is a human's click.
// Once per launch, only within 30 minutes of boot, only sessions whose session.json was written as the Mac went down.
// A saved conversation already live elsewhere is skipped — its pane comes back as a shell (session.json is backed up
// first) — instead of holding the whole session back: on 2026-10-09 two live agents kept laris-co's other 15 down.

extension HubStore {
    /// Runs once per hub launch. Returns what it did that a human should know (skips, failures), for `problems`.
    func autostartAfterReboot() async -> [String] {
        guard let boot = HerdrPlaces.bootTime(), Date().timeIntervalSince(boot) < 30 * 60,
              let t = await Shell.run("herdr", ["session", "list", "--json"]) else { return [] }
        let sessions = HubParse.sessions(Data(t.utf8))
        var savedAt: [String: Date] = [:]
        for s in sessions where !s.running {
            if let dir = s.dir, let d = HerdrPlaces.modified(dir + "/session.json") { savedAt[s.name] = d }
        }
        var notes: [String] = []
        for name in HerdrPlaces.runningAtShutdown(stopped: savedAt, boot: boot) {
            let r = await HerdrPlaces.startSkippingLive(name: name, dir: sessions.first(where: { $0.name == name })?.dir)
            if let e = r.error { notes.append(e) }
            if let n = HerdrPlaces.skippedNote(name, r.skipped, backup: r.backup) { notes.append(n) }
        }
        return notes
    }
}
#endif
