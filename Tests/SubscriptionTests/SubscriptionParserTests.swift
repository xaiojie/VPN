import XCTest
@testable import Subscription

final class SubscriptionParserTests: XCTestCase {
    func testParseLines() throws {
        let text = """
        # comment
        socks5://example.com:1080#NodeA
        http://proxy.local:8080#NodeB
        """
        let nodes = try SubscriptionParser.parseLines(text)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].name, "NodeA")
        XCTAssertEqual(nodes[1].type, .http)
    }
}
