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

@MainActor private func write<V: View>(_ v: V, to path: String) throws {
    let r = ImageRenderer(content: v); r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: URL(fileURLWithPath: path))
}
