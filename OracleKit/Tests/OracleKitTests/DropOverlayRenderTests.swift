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

/// `RENDER_CARDS=<dir> swift test --filter GHCardRenderTests` → the PR/issue cards as the app draws them.
final class GHCardRenderTests: XCTestCase {
    @MainActor func testRenderCards() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_CARDS"] else { throw XCTSkip("set RENDER_CARDS=<dir>") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ago = Date().addingTimeInterval(-3600 * 5)
        let pr = GHItem(number: 140, title: "docs(cheatsheet): bring here, per-oracle tray, COLD cleanup plan", author: "nazt",
                        updatedAt: ago, url: nil, isDraft: false, branch: "docs/oracle-apps-bring-tray-cleanup-7oct")
        let issue = GHItem(number: 111, title: "fleet-tui: the fleet server sees one herdr session only", author: "nazt",
                           updatedAt: ago, url: nil, isDraft: false)
        let v = VStack(alignment: .leading, spacing: 18) {
            Text("Pick up a pull request.").font(.custom("Avenir Next", size: 30).weight(.bold)).tracking(-0.5)
            VStack(spacing: 8) {
                GHCard(item: pr, status: ("open", .green), detail: "nazt · 5 hours ago · docs/oracle-apps-bring-tray-cleanup-7oct")
                GHCard(item: issue, status: ("no worktree yet", Color(hex: "#64b5f6")), detail: "nazt · 5 hours ago")
            }
        }
        .padding(28).frame(width: 900).background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: v); r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("render") }
        try png.write(to: URL(fileURLWithPath: "\(dir)/cards.png"))
    }

    /// The one-shot pill under the pointer: Pick up on an issue no worktree names, Continue once one does.
    @MainActor func testRenderPickUpPills() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_CARDS"] else { throw XCTSkip("set RENDER_CARDS=<dir>") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ago = Date().addingTimeInterval(-3600 * 24 * 14)
        let open = GHItem(number: 4, title: "[Parity] Recipes: full editor, actions, and calculation accuracy", author: "nazt",
                          updatedAt: ago, url: nil, isDraft: false)
        let taken = GHItem(number: 7, title: "[Parity] Audit all pages and navigation", author: "nazt", updatedAt: ago, url: nil, isDraft: false)
        let accent = Color(hex: "#f5b041")
        func picks(_ n: Int, _ inWorktree: Bool) -> [GHCard.Pick] {
            PickUp.actions(inWorktree: inWorktree).map { GHCard.Pick(label: $0.label, command: PickUp.command($0.action, issue: n)) {} }
        }
        let v = VStack(alignment: .leading, spacing: 18) {
            Text("Pick up an issue.").font(.custom("Avenir Next", size: 30).weight(.bold)).tracking(-0.5)
            VStack(spacing: 8) {
                GHCard(item: open, status: ("no worktree yet", accent), detail: "nazt · 2 weeks ago", picks: picks(4, false), hover: true)
                GHCard(item: open, status: ("starting…", accent), detail: "nazt · 2 weeks ago · after the click", busy: true)
                GHCard(item: taken, status: ("in a worktree", .green), detail: "nazt · 2 weeks ago · worktree audit-pages",
                       picks: picks(7, true), hover: true)
                GHCard(item: taken, status: ("couldn't start", .red), detail: "nazt · 2 weeks ago · why is in the tooltip",
                       failure: "cannot read issue #7\ngh issue view 7 -R o/r")
                GHCard(item: open, status: ("no worktree yet", accent), detail: "nazt · 2 weeks ago · pointer elsewhere", picks: picks(4, false))
            }
        }
        .padding(28).frame(width: 900).background(Color(red: 0.11, green: 0.11, blue: 0.12)).environment(\.colorScheme, .dark)
        try write(v, to: "\(dir)/pickup-pills.png")
    }
}
