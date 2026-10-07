import XCTest
@testable import OracleKit

/// The MCP server's HTTP reader: a request it can never read is refused, never sliced with — a negative
/// Content-Length used to crash the app (any local process could send one).
final class MCPParseTests: XCTestCase {
    private func req(_ s: String) -> Data { Data(s.utf8) }

    func testAGoodRequest() {
        let r = MCPServer.parse(req("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"))
        XCTAssertNil(r?.bad)
        XCTAssertEqual(r?.method, "POST"); XCTAssertEqual(r?.path, "/mcp"); XCTAssertEqual(r?.body, Data("{}".utf8))
    }

    func testIncompleteWaits() {
        XCTAssertNil(MCPServer.parse(req("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}")))   // body still coming
        XCTAssertNil(MCPServer.parse(req("POST /mcp HTTP/1.1\r\nContent-Le")))                    // headers still coming
    }

    func testNegativeLengthIsRefusedNotSliced() {
        XCTAssertNotNil(MCPServer.parse(req("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n"))?.bad)
    }

    func testHugeOrBrokenLengthIsRefused() {
        XCTAssertNotNil(MCPServer.parse(req("POST /mcp HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n"))?.bad)
        XCTAssertNotNil(MCPServer.parse(req("POST /mcp HTTP/1.1\r\nContent-Length: ten\r\n\r\n"))?.bad)
    }

    func testEndlessHeadersAreRefused() {
        let long = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: MCPServer.maxHeader + 10)
        XCTAssertNotNil(MCPServer.parse(req(long))?.bad)
    }

    func testNoRequestLineIsRefused() {
        XCTAssertNotNil(MCPServer.parse(req("garbage\r\n\r\n"))?.bad)
    }
}
