import XCTest
@testable import Subscription

final class PacGeneratorTests: XCTestCase {
    func testGeneratePacIncludesPorts() {
        let rules = PacRules(directDomains: ["apple.com"], directKeywords: ["github"], bypassLocalNetworks: true)
        let pac = PacGenerator.generate(rules: rules, socksPort: 7891, httpPort: 7890)
        XCTAssertTrue(pac.contains("SOCKS5 127.0.0.1:7891"))
        XCTAssertTrue(pac.contains("PROXY 127.0.0.1:7890"))
    }
}
