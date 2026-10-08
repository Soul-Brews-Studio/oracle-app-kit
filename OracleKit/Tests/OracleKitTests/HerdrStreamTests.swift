import XCTest
@testable import OracleKit

/// herdr's terminal stream protocol, as measured on m5 (2026-10-08): the lines it writes, the lines a control
/// stream reads, and the arguments.
final class HerdrStreamTests: XCTestCase {
    func testObserveTakesNoTakeover() {
        XCTAssertEqual(HerdrStreamWire.arguments(session: "laris-co", pane: "w22:pD", mode: .observe, cols: 99, rows: 27, takeover: true),
                       ["--session", "laris-co", "terminal", "session", "observe", "w22:pD", "--cols", "99", "--rows", "27"])
    }

    func testControlCarriesTheTakeover() {
        XCTAssertEqual(HerdrStreamWire.arguments(session: nil, pane: "w5:p1", mode: .control, cols: 212, rows: 61, takeover: true),
                       ["terminal", "session", "control", "w5:p1", "--takeover", "--cols", "212", "--rows", "61"])
        XCTAssertEqual(HerdrStreamWire.arguments(session: "", pane: "w5:p1", mode: .control, cols: 0, rows: -3),
                       ["terminal", "session", "control", "w5:p1", "--cols", "1", "--rows", "1"])
    }

    func testTheControlMessagesAreJSONLines() throws {
        let typed = HerdrStreamWire.input(Data("echo hi\r".utf8))
        XCTAssertEqual(typed.last, 0x0A)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: typed.dropLast()) as? [String: Any])
        XCTAssertEqual(o["type"] as? String, "terminal.input")
        XCTAssertEqual(Data(base64Encoded: o["bytes"] as? String ?? ""), Data("echo hi\r".utf8))
        XCTAssertEqual(String(decoding: HerdrStreamWire.resize(cols: 70, rows: 8), as: UTF8.self),
                       "{\"cols\":70,\"rows\":8,\"type\":\"terminal.resize\"}\n")
        XCTAssertEqual(String(decoding: HerdrStreamWire.release, as: UTF8.self), "{\"type\":\"terminal.release\"}\n")
    }

    func testAFrameDecodes() {
        let bytes = Data("\u{1b}[?2026h\u{1b}[2J\u{1b}[1;1Hhello".utf8)
        let line = #"{"encoding":"ansi","full":true,"height":6,"seq":1,"type":"terminal.frame","width":80,"bytes":""#
            + bytes.base64EncodedString() + #""}"#
        XCTAssertEqual(HerdrStreamWire.event(Data(line.utf8)),
                       .frame(HerdrStreamFrame(seq: 1, width: 80, height: 6, full: true, bytes: bytes)))
    }

    func testClosesAndJunk() {
        let held = #"{"reason":"terminal attach failed: terminal term_65d4a0c5151fa42 already has an attached client; retry with --takeover","type":"terminal.closed"}"#
        guard case .closed(let reason)? = HerdrStreamWire.event(Data(held.utf8)) else { return XCTFail("not a close") }
        XCTAssertTrue(HerdrStreamWire.isHeldElsewhere(reason))
        XCTAssertFalse(HerdrStreamWire.wasTakenOver(reason))
        XCTAssertTrue(HerdrStreamWire.wasTakenOver("terminal attach taken over"))
        XCTAssertEqual(HerdrStreamWire.event(Data(#"{"reason":"detached","type":"terminal.closed"}"#.utf8)), .closed("detached"))
        XCTAssertNil(HerdrStreamWire.event(Data("not json".utf8)))
        XCTAssertNil(HerdrStreamWire.event(Data(#"{"type":"terminal.frame","encoding":"utf16","bytes":"aGk="}"#.utf8)))
        XCTAssertNil(HerdrStreamWire.event(Data(#"{"type":"terminal.hello"}"#.utf8)))
    }

    /// A frame line is often split across reads (a full frame is tens of KB); two can arrive in one read.
    func testLinesSurviveAnySplit() {
        let text = "{\"a\":1}\n{\"b\":2}\n\n{\"c\":3}\n{\"partial\""
        let whole = Data(text.utf8)
        for cut in 1..<whole.count {
            var lines = HerdrStreamWire.Lines()
            let got = lines.append(Data(whole.prefix(cut))) + lines.append(Data(whole.dropFirst(cut)))
            XCTAssertEqual(got.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"], "cut at \(cut)")
        }
        var lines = HerdrStreamWire.Lines()
        XCTAssertEqual(lines.append(Data("{\"d\":4}".utf8)), [])
        XCTAssertEqual(lines.append(Data("\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"d\":4}"])
    }

    #if os(macOS)
    /// The real herdr, when this Mac runs one: an observe stream of the test runner's own pane gives a full first
    /// frame at the size asked for. Skipped without herdr or outside a herdr pane.
    func testALiveObserveGivesAFullFrame() throws {
        guard Shell.which("herdr") != nil, let pane = ProcessInfo.processInfo.environment["HERDR_PANE_ID"] else {
            throw XCTSkip("not inside a herdr pane")
        }
        let session = ProcessInfo.processInfo.environment["HERDR_SESSION"]
        let got = expectation(description: "first frame")
        final class Seen: @unchecked Sendable { var first: HerdrStreamFrame? }   // written on the main thread only
        let seen = Seen()
        let s = HerdrStream(session: session, pane: pane, mode: .observe, cols: 40, rows: 5) { e in
            if case .frame(let f) = e, seen.first == nil { seen.first = f; got.fulfill() }
        }
        s.start()
        wait(for: [got], timeout: 5)
        s.stop()
        XCTAssertEqual(seen.first?.width, 40)
        XCTAssertEqual(seen.first?.height, 5)
        XCTAssertEqual(seen.first?.full, true)
        XCTAssertGreaterThan(seen.first?.bytes.count ?? 0, 10)
    }
    #endif
}

/// Observe's font fit against a model of Ghostty's grid with whole-pixel cells (the review found the unbounded
/// version cycling 8.75 → 8.5 → 8.25 → 8.75 for a 110×40 pane in a 620×750 pt drawer at 2x).
final class LiveFitTests: XCTestCase {
    /// cells round up to whole pixels; 8 pt / 6 pt of padding each side, as the live pane configures Ghostty
    private func grid(font f: Float, view: (w: Double, h: Double), scale s: Double) -> (cols: Int, rows: Int) {
        let cw = (0.6 * Double(f) * s).rounded(.up), ch = (1.32 * Double(f) * s).rounded(.up)
        return (Int(((view.w - 16) * s / cw).rounded(.down)), Int(((view.h - 12) * s / ch).rounded(.down)))
    }

    private func settle(pane: (cols: Int, rows: Int), view: (w: Double, h: Double), scale: Double)
        -> (font: Float, steps: Int, step: LiveFit.Step) {
        var font: Float = 13, fits: Float?, tooBig: Float?
        for n in 1...20 {
            let s = LiveFit.next(font: font, grid: grid(font: font, view: view, scale: scale), pane: pane, fits: fits, tooBig: tooBig)
            if s.font == font { return (font, n, s) }
            font = s.font; fits = s.fits; tooBig = s.tooBig
        }
        return (font, 99, LiveFit.Step(font: font, fits: fits, tooBig: tooBig, cropped: false))
    }

    func testTheReviewsCycleSettles() {
        let r = settle(pane: (110, 40), view: (620, 750), scale: 2)
        XCTAssertLessThan(r.steps, 12)
        let g = grid(font: r.font, view: (620, 750), scale: 2)
        XCTAssertTrue(g.cols >= 110 && g.rows >= 40, "\(r.font) pt gives \(g)")
    }

    /// Every drawer, pane and display: it settles within a few steps, on a font that holds the pane (or the
    /// smallest one, cropped), at most 0.75 pt under the best quarter-point font.
    func testEveryCaseSettlesOnAFontThatHolds() {
        var worst: Float = 0, cases = 0
        for scale in [1.0, 2.0] { for view in [(420.0, 500.0), (620, 750), (900, 1000), (1300, 1250)] {
            for cols in [40, 66, 80, 99, 110, 150, 200] { for rows in [3, 20, 27, 40, 43, 60] {
                cases += 1
                let r = settle(pane: (cols, rows), view: view, scale: scale)
                XCTAssertLessThan(r.steps, 12, "pane \(cols)×\(rows) view \(view) @\(scale)x did not settle")
                let holds = { (f: Float) -> Bool in let g = self.grid(font: f, view: view, scale: scale); return g.cols >= cols && g.rows >= rows }
                let best = stride(from: Float(20), through: 6, by: -0.25).first(where: holds)
                if let best {
                    XCTAssertTrue(holds(r.font), "pane \(cols)×\(rows) view \(view) @\(scale)x: \(r.font) pt does not hold it")
                    XCTAssertLessThanOrEqual(best - r.font, 0.75, "pane \(cols)×\(rows) view \(view) @\(scale)x: \(r.font) pt, best \(best)")
                    worst = max(worst, best - r.font)
                } else {
                    XCTAssertEqual(r.font, 6, "pane \(cols)×\(rows) view \(view) @\(scale)x: nothing holds it, so the smallest font")
                    XCTAssertTrue(r.step.cropped)
                }
            } }
        } }
        print("LiveFit: \(cases) cases, worst \(worst) pt under the best quarter-point font")
    }
}
