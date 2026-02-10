import Foundation
import Diagnostics

public struct AppPaths {
    public static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TahoeProxy", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    public static func fileURL(_ name: String) -> URL {
        appSupport.appendingPathComponent(name)
    }
}

public struct JSONStore {
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
        AppLogger.shared.record("Saved \(url.lastPathComponent)", category: .system)
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }
}

public struct StoredSettings: Codable {
    public var socksPort: UInt16
    public var httpPort: UInt16
    public var pacPort: UInt16
    public var bypassList: [String]
    public var autoConnect: Bool
    public var refreshIntervalHours: Int
    public var useAutomaticServices: Bool
    public var selectedServices: [String]

    public init(socksPort: UInt16, httpPort: UInt16, pacPort: UInt16, bypassList: [String], autoConnect: Bool, refreshIntervalHours: Int, useAutomaticServices: Bool, selectedServices: [String]) {
        self.socksPort = socksPort
        self.httpPort = httpPort
        self.pacPort = pacPort
        self.bypassList = bypassList
        self.autoConnect = autoConnect
        self.refreshIntervalHours = refreshIntervalHours
        self.useAutomaticServices = useAutomaticServices
        self.selectedServices = selectedServices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        socksPort = try container.decodeIfPresent(UInt16.self, forKey: .socksPort) ?? 7891
        httpPort = try container.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? 7890
        pacPort = try container.decodeIfPresent(UInt16.self, forKey: .pacPort) ?? 7892
        bypassList = try container.decodeIfPresent([String].self, forKey: .bypassList) ?? ["localhost", "127.0.0.1"]
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        refreshIntervalHours = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalHours) ?? 12
        useAutomaticServices = try container.decodeIfPresent(Bool.self, forKey: .useAutomaticServices) ?? true
        selectedServices = try container.decodeIfPresent([String].self, forKey: .selectedServices) ?? []
    }

    public static let `default` = StoredSettings(
        socksPort: 7891,
        httpPort: 7890,
        pacPort: 7892,
        bypassList: ["localhost", "127.0.0.1", "*.local", "10.0.0.0/8", "192.168.0.0/16"],
        autoConnect: false,
        refreshIntervalHours: 12,
        useAutomaticServices: true,
        selectedServices: []
    )
}
