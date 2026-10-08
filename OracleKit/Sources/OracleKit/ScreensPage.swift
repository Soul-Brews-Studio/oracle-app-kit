#if os(macOS)
import SwiftUI
import AppKit

/// The hub's Screens page (#62): Nat's displays as macOS arranges them, where the hub itself is, and where each
/// running herdr session's WezTerm window is. Live: a display plugged, unplugged or rearranged redraws at once
/// (didChangeScreenParameters); windows are read again every 2 s. A click on a session's window runs Show in herdr.
public struct ScreensPage: View {
    @ObservedObject var store: HubStore
    let accent: Color
    @State private var displays: [ScreenMap.Display] = []
    @State private var hub: CGRect?
    @State private var windows: [Placed] = []
    public init(store: HubStore, accent: Color) { self.store = store; self.accent = accent }

    struct Placed: Identifiable, Equatable { let id: Int; let session: String; let rect: CGRect; let front: Bool }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("SCREENS").font(.caption.weight(.bold)).tracking(2).foregroundStyle(accent)
                Text("Where everything is").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(summary).font(.callout).foregroundStyle(.secondary)
                GeometryReader { geo in
                    let f = ScreenMap.fit(displays, into: geo.size)
                    ZStack(alignment: .topLeading) {
                        ForEach(displays) { d in
                            let r = ScreenMap.place(d.frame, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(d.main ? Color(red: 0.89, green: 0.70, blue: 0.24) : Color(white: 0.3), lineWidth: d.main ? 2 : 1))
                                .overlay(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.name).font(.caption.weight(.semibold))
                                        Text(verbatim: "\(Int(d.frame.width))×\(Int(d.frame.height))\(d.main ? " · main" : "")").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }.padding(6)
                                }
                                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        }
                        ForEach(windows) { w in
                            let r = ScreenMap.place(w.rect, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 3).fill((w.front ? Color.green : Color.secondary).opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(w.front ? Color.green : Color.secondary, lineWidth: 1.5))
                                .overlay { Text("herdr \(w.session)\(w.front ? "" : " · behind")").font(.caption2.weight(.semibold)).padding(3) }
                                .frame(width: max(r.width, 24), height: max(r.height, 14)).offset(x: r.minX, y: r.minY)
                                .onTapGesture { store.openSession(w.session) }
                                .help("Show \(w.session) in herdr")
                        }
                        if let hub {
                            let r = ScreenMap.place(hub, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.28))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(accent, lineWidth: 2))
                                .overlay { Text("ARRA Oracles (here)").font(.caption2.weight(.bold)).padding(3) }
                                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 360)
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Screens")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in readDisplays() }
        .task {
            readDisplays()
            while !Task.isCancelled { await readWindows(); try? await Task.sleep(for: .seconds(2)) }
        }
    }

    /// "The hub is on DELL U2719DC · laris-co's herdr window is on DELL S2725QS (front)".
    private var summary: String {
        var parts: [String] = []
        if let hub, let d = ScreenMap.display(of: hub, in: displays) { parts.append("The hub is on \(d.name)") }
        for w in windows {
            parts.append("\(w.session)'s herdr window is on \(ScreenMap.display(of: w.rect, in: displays)?.name ?? "no screen") (\(w.front ? "front" : "behind"))")
        }
        return parts.isEmpty ? "Reading the screens…" : parts.joined(separator: " · ")
    }

    private func readDisplays() {
        let screens = NSScreen.screens
        let mainH = screens.first?.frame.height ?? 0
        displays = screens.enumerated().map { i, s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? i
            return ScreenMap.Display(id: id, name: s.localizedName, frame: ScreenMap.topLeft(s.frame, mainHeight: mainH), main: i == 0)
        }
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { hub = ScreenMap.topLeft(w.frame, mainHeight: mainH) }
    }

    private func readWindows() async {
        readDisplays()   // the hub window may have moved
        var out: [Placed] = []
        for s in store.sessions where s.running {
            switch await WezTerm.clientWindow(session: s.name) {
            case .front(let id, _), .behind(let id, _):
                guard let w = await WezTerm.yabaiJSON(["--windows", "--window", String(id)]) as? [String: Any],
                      let f = w["frame"] as? [String: Double] else { continue }
                let rect = CGRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["w"] ?? 0, height: f["h"] ?? 0)
                if case .front = await WezTerm.clientWindow(session: s.name) { out.append(.init(id: id, session: s.name, rect: rect, front: true)) }
                else { out.append(.init(id: id, session: s.name, rect: rect, front: false)) }
            case .none:
                continue
            }
        }
        if out != windows { windows = out }
    }
}
#endif
