import Foundation
import Diagnostics
import Persistence

public enum ProxyNodeType: String, Codable, CaseIterable {
    case http
    case socks5
}

public struct ProxyNode: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var type: ProxyNodeType
    public var host: String
    public var port: UInt16
    public var username: String?
    public var passwordRef: String?
    public var groupTag: String?
    public var lastLatencyMs: Int?
    public var isFavorite: Bool

    public init(id: UUID = UUID(), name: String, type: ProxyNodeType, host: String, port: UInt16, username: String? = nil, passwordRef: String? = nil, groupTag: String? = nil, lastLatencyMs: Int? = nil, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.passwordRef = passwordRef
        self.groupTag = groupTag
        self.lastLatencyMs = lastLatencyMs
        self.isFavorite = isFavorite
    }
}

public struct Subscription: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var url: String
    public var lastUpdated: Date?

    public init(id: UUID = UUID(), name: String, url: String, lastUpdated: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdated = lastUpdated
    }
}

public enum SubscriptionError: Error {
    case invalidLine
    case invalidURL
}

public struct SubscriptionParser {
    public static func parseLines(_ text: String, group: String? = nil) throws -> [ProxyNode] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var nodes: [ProxyNode] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let url = URL(string: trimmed) else { throw SubscriptionError.invalidURL }
            guard let scheme = url.scheme?.lowercased() else { throw SubscriptionError.invalidURL }
            let type: ProxyNodeType
            if scheme == "socks5" {
                type = .socks5
            } else if scheme == "http" {
                type = .http
            } else {
                throw SubscriptionError.invalidLine
            }
            guard let host = url.host, let port = url.port else { throw SubscriptionError.invalidLine }
            let user = url.user
            let password = url.password
            var passwordRef: String? = nil
            if let password {
                let account = UUID().uuidString
                try? KeychainStore.save(password: password, account: account)
                passwordRef = account
            }
            let name = url.fragment?.removingPercentEncoding ?? "\(host):\(port)"
            let node = ProxyNode(name: name, type: type, host: host, port: UInt16(port), username: user, passwordRef: passwordRef, groupTag: group)
            nodes.append(node)
        }
        return nodes
    }
}

public struct PacRules: Codable, Hashable {
    public var directDomains: [String]
    public var directKeywords: [String]
    public var bypassLocalNetworks: Bool

    public static let `default` = PacRules(directDomains: ["apple.com"], directKeywords: ["github"], bypassLocalNetworks: true)
}

public struct PacGenerator {
    public static func generate(rules: PacRules, socksPort: UInt16, httpPort: UInt16) -> String {
        var lines: [String] = []
        lines.append("function FindProxyForURL(url, host) {")
        if rules.bypassLocalNetworks {
            lines.append("  if (isPlainHostName(host) || shExpMatch(host, '*.local')) return 'DIRECT';")
            lines.append("  if (isInNet(host, '10.0.0.0', '255.0.0.0')) return 'DIRECT';")
            lines.append("  if (isInNet(host, '192.168.0.0', '255.255.0.0')) return 'DIRECT';")
        }
        for domain in rules.directDomains where !domain.isEmpty {
            let pattern = domain.hasPrefix(".") ? "*\(domain)" : "*\(domain)"
            lines.append("  if (shExpMatch(host, '\(pattern)')) return 'DIRECT';")
        }
        for keyword in rules.directKeywords where !keyword.isEmpty {
            lines.append("  if (shExpMatch(host, '*\(keyword)*')) return 'DIRECT';")
        }
        lines.append("  return 'SOCKS5 127.0.0.1:\(socksPort); PROXY 127.0.0.1:\(httpPort)';")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

public actor SubscriptionStore {
    private let subscriptionsURL = AppPaths.fileURL("subscriptions.json")
    private let nodesURL = AppPaths.fileURL("nodes_cache.json")

    public private(set) var subscriptions: [Subscription] = []
    public private(set) var nodes: [ProxyNode] = []

    public init() {
        if let loaded = try? JSONStore.load([Subscription].self, from: subscriptionsURL) {
            subscriptions = loaded
        }
        if let loaded = try? JSONStore.load([ProxyNode].self, from: nodesURL) {
            nodes = loaded
        }
    }

    public func save() async throws {
        try JSONStore.save(subscriptions, to: subscriptionsURL)
        try JSONStore.save(nodes, to: nodesURL)
    }

    public func importText(_ text: String, group: String?) async throws {
        let parsed = try SubscriptionParser.parseLines(text, group: group)
        nodes.append(contentsOf: parsed)
        try await save()
        AppLogger.shared.record("Imported \(parsed.count) nodes", category: .subscription)
    }

    public func addSubscription(name: String, url: String) async throws {
        subscriptions.append(Subscription(name: name, url: url, lastUpdated: nil))
        try await save()
    }

    public func removeSubscription(_ subscription: Subscription) async throws {
        subscriptions.removeAll { $0.id == subscription.id }
        nodes.removeAll { $0.groupTag == subscription.name }
        try await save()
    }

    public func refresh(subscription: Subscription) async throws {
        guard let url = URL(string: subscription.url) else { throw SubscriptionError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let parsed = try SubscriptionParser.parseLines(text, group: subscription.name)
        nodes.removeAll { $0.groupTag == subscription.name }
        nodes.append(contentsOf: parsed)
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index].lastUpdated = Date()
        }
        try await save()
    }

    public func refreshAll() async throws {
        for subscription in subscriptions {
            try await refresh(subscription: subscription)
        }
    }
}
