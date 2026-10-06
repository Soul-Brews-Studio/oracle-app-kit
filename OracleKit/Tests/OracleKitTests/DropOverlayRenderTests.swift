import XCTest
import SwiftUI
@testable import OracleKit

/// `RENDER_DROP=<dir> swift test --filter DropOverlayRenderTests` → PNGs of the two drop zones: idle, Inbox hot,
/// New issue hot. (The live overlay sits on .ultraThinMaterial and adds .dropDestination, which renders blank here.)
final class DropOverlayRenderTests: XCTestCase {
    @MainActor func testRenderDropZones() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DROP"] else { throw XCTSkip("set RENDER_DROP=<dir>") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let accent = Color(hex: "#64b5f6")
        for (name, inbox, issue) in [("idle", false, false), ("inbox-hot", true, false), ("issue-hot", false, true)] {
            let v = HStack(spacing: 16) {
                DropZone.inbox(hot: inbox, accent: accent)
                DropZone.issue(repo: "laris-co/neo-oracle", hot: issue, accent: accent)
            }
            .padding(18).frame(width: 900, height: 360)
            .background(Color(red: 0.13, green: 0.13, blue: 0.15)).environment(\.colorScheme, .dark)
            try write(v, to: "\(dir)/drop-\(name).png")
        }
    }
}

/// `RENDER_LAYOUT=<dir> SNAPSHOT=<herdr api snapshot json> SPACE=w22 swift test --filter LayoutRenderTests`
/// → one PNG per tab of that space, drawn the way the Work view draws it.
final class LayoutRenderTests: XCTestCase {
    @MainActor func testRenderSpaceTabs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["RENDER_LAYOUT"], let snap = env["SNAPSHOT"], let ws = env["SPACE"] else { throw XCTSkip("set RENDER_LAYOUT, SNAPSHOT, SPACE") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let parsed = HerdrSnapshot.parse(try Data(contentsOf: URL(fileURLWithPath: snap)), session: "laris-co")
        guard let space = parsed.spaces.first(where: { $0.workspaceId == ws }) else { return XCTFail("no space \(ws)") }
        for t in space.tabs {
            let v = LayoutCanvas(tab: t, acts: [:], twins: [:], home: "laris-co", accent: Color(hex: "#64b5f6"))
                .frame(width: 900).padding(16).background(Color(red: 0.12, green: 0.12, blue: 0.13)).environment(\.colorScheme, .dark)
            try write(v, to: "\(dir)/\(t.tabId.replacingOccurrences(of: ":", with: "-")).png")
        }
    }
}

@MainActor private func write<V: View>(_ v: V, to path: String) throws {
    let r = ImageRenderer(content: v); r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: path))
}
