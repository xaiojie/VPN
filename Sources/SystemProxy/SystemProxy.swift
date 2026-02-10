import Foundation
import SystemConfiguration
import Diagnostics
import Persistence

public enum SystemProxyError: Error {
    case unableToCreatePreferences
    case unableToCommit
    case unableToApply
    case serviceNotFound
}

public struct ProxySnapshot: Codable {
    public struct ServiceSnapshot: Codable, Identifiable {
        public let id: UUID
        public let name: String
        public let proxies: [String: ProxyValue]

        public init(name: String, proxies: [String: ProxyValue]) {
            self.id = UUID()
            self.name = name
            self.proxies = proxies
        }
    }

    public var services: [ServiceSnapshot]

    public init(services: [ServiceSnapshot]) {
        self.services = services
    }
}

public enum ProxyValue: Codable {
    case string(String)
    case number(Int)
    case bool(Bool)

    public init?(any: Any) {
        switch any {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = .number(value.intValue)
        case let value as Bool:
            self = .bool(value)
        default:
            return nil
        }
    }

    public var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        }
    }
}

public final class SystemProxyManager {
    private let snapshotURL = AppPaths.fileURL("system_proxy_snapshot.json")

    public init() {}

    public func detectActiveServices() -> [String] {
        guard let prefs = SCPreferencesCreate(nil, "TahoeProxy" as CFString, nil) else { return [] }
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            let name = SCNetworkServiceGetName(service) as String?
            return name
        }
    }

    public func captureSnapshot(services: [String]) throws -> ProxySnapshot {
        guard let prefs = SCPreferencesCreate(nil, "TahoeProxy" as CFString, nil) else { throw SystemProxyError.unableToCreatePreferences }
        guard let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw SystemProxyError.serviceNotFound }

        var snapshots: [ProxySnapshot.ServiceSnapshot] = []
        for service in allServices {
            guard let name = SCNetworkServiceGetName(service) as String?, services.contains(name) else { continue }
            guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let config = SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any] ?? [:]
            var proxies: [String: ProxyValue] = [:]
            for (key, value) in config {
                if let wrapped = ProxyValue(any: value) {
                    proxies[key] = wrapped
                }
            }
            snapshots.append(.init(name: name, proxies: proxies))
        }
        let snapshot = ProxySnapshot(services: snapshots)
        try JSONStore.save(snapshot, to: snapshotURL)
        AppLogger.shared.record("Captured system proxy snapshot", category: .system)
        return snapshot
    }

    public func loadSnapshot() -> ProxySnapshot? {
        try? JSONStore.load(ProxySnapshot.self, from: snapshotURL)
    }

    public func applyManualProxy(services: [String], httpPort: UInt16, socksPort: UInt16, bypassList: [String]) throws {
        guard let prefs = SCPreferencesCreate(nil, "TahoeProxy" as CFString, nil) else { throw SystemProxyError.unableToCreatePreferences }
        guard let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw SystemProxyError.serviceNotFound }
        for service in allServices {
            guard let name = SCNetworkServiceGetName(service) as String?, services.contains(name) else { continue }
            guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            var config = SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any] ?? [:]
            config[kSCPropNetProxiesHTTPEnable as String] = 1
            config[kSCPropNetProxiesHTTPProxy as String] = "127.0.0.1"
            config[kSCPropNetProxiesHTTPPort as String] = Int(httpPort)
            config[kSCPropNetProxiesHTTPSEnable as String] = 1
            config[kSCPropNetProxiesHTTPSProxy as String] = "127.0.0.1"
            config[kSCPropNetProxiesHTTPSPort as String] = Int(httpPort)
            config[kSCPropNetProxiesSOCKSEnable as String] = 1
            config[kSCPropNetProxiesSOCKSProxy as String] = "127.0.0.1"
            config[kSCPropNetProxiesSOCKSPort as String] = Int(socksPort)
            config[kSCPropNetProxiesExceptionsList as String] = bypassList
            SCNetworkProtocolSetConfiguration(protocolRef, config as CFDictionary)
        }
        if !SCPreferencesCommitChanges(prefs) || !SCPreferencesApplyChanges(prefs) {
            try applyManualProxyFallback(services: services, httpPort: httpPort, socksPort: socksPort, bypassList: bypassList)
        }
        AppLogger.shared.record("Applied manual proxy", category: .system)
    }

    public func applyPAC(services: [String], pacURL: URL, bypassList: [String]) throws {
        guard let prefs = SCPreferencesCreate(nil, "TahoeProxy" as CFString, nil) else { throw SystemProxyError.unableToCreatePreferences }
        guard let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw SystemProxyError.serviceNotFound }
        for service in allServices {
            guard let name = SCNetworkServiceGetName(service) as String?, services.contains(name) else { continue }
            guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            var config = SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any] ?? [:]
            config[kSCPropNetProxiesProxyAutoConfigEnable as String] = 1
            config[kSCPropNetProxiesProxyAutoConfigURLString as String] = pacURL.absoluteString
            config[kSCPropNetProxiesExceptionsList as String] = bypassList
            SCNetworkProtocolSetConfiguration(protocolRef, config as CFDictionary)
        }
        if !SCPreferencesCommitChanges(prefs) || !SCPreferencesApplyChanges(prefs) {
            try applyPACFallback(services: services, pacURL: pacURL, bypassList: bypassList)
        }
        AppLogger.shared.record("Applied PAC proxy", category: .system)
    }

    public func restore(snapshot: ProxySnapshot) throws {
        guard let prefs = SCPreferencesCreate(nil, "TahoeProxy" as CFString, nil) else { throw SystemProxyError.unableToCreatePreferences }
        guard let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { throw SystemProxyError.serviceNotFound }
        for entry in snapshot.services {
            guard let service = allServices.first(where: { SCNetworkServiceGetName($0) as String? == entry.name }) else { continue }
            guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            var config: [String: Any] = [:]
            for (key, value) in entry.proxies {
                config[key] = value.anyValue
            }
            SCNetworkProtocolSetConfiguration(protocolRef, config as CFDictionary)
        }
        if !SCPreferencesCommitChanges(prefs) || !SCPreferencesApplyChanges(prefs) {
            try restoreFallback(services: snapshot.services.map { $0.name })
        }
        AppLogger.shared.record("Restored system proxy", category: .system)
    }

    public func isProxyPointingToLocal(services: [String], httpPort: UInt16, socksPort: UInt16) -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "TahoeProxy" as CFString, nil) else { return false }
        guard let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return false }
        for service in allServices {
            guard let name = SCNetworkServiceGetName(service) as String?, services.contains(name) else { continue }
            guard let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let config = SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any] ?? [:]
            let httpProxy = config[kSCPropNetProxiesHTTPProxy as String] as? String
            let httpPortValue = config[kSCPropNetProxiesHTTPPort as String] as? Int
            let socksProxy = config[kSCPropNetProxiesSOCKSProxy as String] as? String
            let socksPortValue = config[kSCPropNetProxiesSOCKSPort as String] as? Int
            if httpProxy == "127.0.0.1", httpPortValue == Int(httpPort) { return true }
            if socksProxy == "127.0.0.1", socksPortValue == Int(socksPort) { return true }
        }
        return false
    }

    private func applyManualProxyFallback(services: [String], httpPort: UInt16, socksPort: UInt16, bypassList: [String]) throws {
        for service in services {
            try runNetworkSetup(["-setwebproxy", service, "127.0.0.1", "\(httpPort)"])
            try runNetworkSetup(["-setsecurewebproxy", service, "127.0.0.1", "\(httpPort)"])
            try runNetworkSetup(["-setsocksfirewallproxy", service, "127.0.0.1", "\(socksPort)"])
            try runNetworkSetup(["-setproxybypassdomains", service] + bypassList)
            try runNetworkSetup(["-setwebproxystate", service, "on"])
            try runNetworkSetup(["-setsecurewebproxystate", service, "on"])
            try runNetworkSetup(["-setsocksfirewallproxystate", service, "on"])
        }
    }

    private func applyPACFallback(services: [String], pacURL: URL, bypassList: [String]) throws {
        for service in services {
            try runNetworkSetup(["-setautoproxyurl", service, pacURL.absoluteString])
            try runNetworkSetup(["-setproxybypassdomains", service] + bypassList)
            try runNetworkSetup(["-setautoproxystate", service, "on"])
        }
    }

    private func restoreFallback(services: [String]) throws {
        for service in services {
            try runNetworkSetup(["-setwebproxystate", service, "off"])
            try runNetworkSetup(["-setsecurewebproxystate", service, "off"])
            try runNetworkSetup(["-setsocksfirewallproxystate", service, "off"])
            try runNetworkSetup(["-setautoproxystate", service, "off"])
        }
    }

    private func runNetworkSetup(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = args
        try process.run()
        process.waitUntilExit()
    }
}
