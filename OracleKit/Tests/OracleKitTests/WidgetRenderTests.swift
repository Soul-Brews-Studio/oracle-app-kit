#if canImport(WidgetKit) && os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import OracleKit

/// RENDER_WIDGETS=<dir> swift test --filter WidgetRenderTests → PNG previews of every size, colour + tinted.
@MainActor
final class WidgetRenderTests: XCTestCase {
    func testRenderPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_WIDGETS"] else { throw XCTSkip("set RENDER_WIDGETS") }
        let icon = ProcessInfo.processInfo.environment["RENDER_ICON"].flatMap { NSImage(contentsOfFile: $0) }.map { Image(nsImage: $0) }
        let now = Date()
        var busy = OracleSnapshot.placeholder(OracleConfig(name: "Neo", tagline: "", repoSlug: "", localPath: "", colorHex: "#64b5f6", symbol: "chevron.left.forwardslash.chevron.right"))
        busy.needsYou = 1
        busy.working = 2
        busy.activity = [
            .init(title: "FIDO key: presence wiring on P18", status: "blocked", place: "a", since: now.addingTimeInterval(-2400)),
            .init(title: "Oracle widgets: restyle per Pigment", status: "working", place: "b", since: now.addingTimeInterval(-720)),
            .init(title: "relic3 widget history", status: "working", place: "c", since: now.addingTimeInterval(-180)),
            .init(title: "Reviewing PR #115 carry", status: "idle", place: "d", since: now.addingTimeInterval(-5400)),
        ]
        busy.prs = 2; busy.prTitles = ["#135 kit: per-oracle widgets", "#134 rescue: vad-torch lab", "#133 rescue: launch-detached"]
        busy.issues = 3; busy.inboxNew = 2; busy.latestHandoff = "fido key blocked on hardware"
        var quiet = busy; quiet.needsYou = 0; quiet.working = 0
        quiet.activity = [.init(title: "neo main", status: "idle", place: "a", since: now.addingTimeInterval(-5400))]
        let cases: [(String, OracleSnapshot)] = [("busy", busy), ("quiet", quiet)]
        let sizes: [(OracleWidgetContent.Size, CGSize, String)] = [(.small, .init(width: 164, height: 164), "small"),
                                                                  (.medium, .init(width: 344, height: 164), "medium"),
                                                                  (.large, .init(width: 344, height: 344), "large")]
        for (label, snap) in cases {
            for (size, dim, sname) in sizes {
                for tinted in [false, true] {
                    let view = OracleWidgetContent(snap: snap, size: size, tinted: tinted, now: now, stale: false, emblem: icon)
                        .padding(16)
                        .frame(width: dim.width, height: dim.height, alignment: .topLeading)
                        .background(OracleWidgetContent.background)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .environment(\.colorScheme, .dark)
                    let r = ImageRenderer(content: view); r.scale = 2
                    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { XCTFail("render"); continue }
                    try png.write(to: URL(fileURLWithPath: "\(dir)/\(label)-\(sname)\(tinted ? "-tinted" : "").png"))
                }
            }
        }
    }
}
#endif
