import Foundation
import Network
import Diagnostics
import Subscription
import Persistence

public enum ProxyCoreError: Error {
    case listenerFailed
    case unsupportedCommand
    case invalidHandshake
}

public struct ProxyStats {
    public var activeConnections: Int = 0
    public var uploadBytes: UInt64 = 0
    public var downloadBytes: UInt64 = 0
    public var lastError: String?

    public init(activeConnections: Int = 0, uploadBytes: UInt64 = 0, downloadBytes: UInt64 = 0, lastError: String? = nil) {
        self.activeConnections = activeConnections
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.lastError = lastError
    }
}

public actor ProxyCore {
    public static let shared = ProxyCore()

    private var socksListener: NWListener?
    private var httpListener: NWListener?
    private var pacListener: NWListener?

    public private(set) var socksPort: UInt16 = 7891
    public private(set) var httpPort: UInt16 = 7890
    public private(set) var pacPort: UInt16 = 7892

    public private(set) var stats = ProxyStats()
    public var activeNode: ProxyNode?
    public var pacContent: String = ""

    public init() {}

    public func configurePorts(socks: UInt16, http: UInt16, pac: UInt16) {
        socksPort = socks
        httpPort = http
        pacPort = pac
    }

    public func start() async throws {
        try await startSocks()
        try await startHTTP()
        try await startPAC()
    }

    public func stop() {
        socksListener?.cancel()
        httpListener?.cancel()
        pacListener?.cancel()
    }

    private func startSocks() async throws {
        let portValue = try findAvailablePort(start: socksPort)
        socksPort = portValue
        let port = NWEndpoint.Port(rawValue: socksPort) ?? 7891
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handleSocks(connection: connection)
        }
        listener.start(queue: .global())
        socksListener = listener
        AppLogger.shared.record("SOCKS5 listening on \(socksPort)", category: .core)
    }

    private func startHTTP() async throws {
        let portValue = try findAvailablePort(start: httpPort)
        httpPort = portValue
        let port = NWEndpoint.Port(rawValue: httpPort) ?? 7890
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handleHTTP(connection: connection)
        }
        listener.start(queue: .global())
        httpListener = listener
        AppLogger.shared.record("HTTP proxy listening on \(httpPort)", category: .core)
    }

    private func startPAC() async throws {
        let portValue = try findAvailablePort(start: pacPort)
        pacPort = portValue
        let port = NWEndpoint.Port(rawValue: pacPort) ?? 7892
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handlePAC(connection: connection)
        }
        listener.start(queue: .global())
        pacListener = listener
    }

    private func findAvailablePort(start: UInt16) throws -> UInt16 {
        var port = start
        for _ in 0..<20 {
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
                listener.cancel()
                return port
            } catch {
                port += 1
            }
        }
        throw ProxyCoreError.listenerFailed
    }

    private func handlePAC(connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
            guard let self else { return }
            let responseBody = self.pacContent
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: \(responseBody.utf8.count)\r\n\r\n"
            let payload = headers + responseBody
            connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handleSocks(connection: NWConnection) {
        connection.start(queue: .global())
        Task {
            do {
                stats.activeConnections += 1
                let greeting = try await receiveExactly(connection: connection, length: 2)
                guard greeting.count == 2 else { throw ProxyCoreError.invalidHandshake }
                let nMethods = Int(greeting[1])
                _ = try await receiveExactly(connection: connection, length: nMethods)
                try await send(connection: connection, data: Data([0x05, 0x00]))
                let header = try await receiveExactly(connection: connection, length: 4)
                guard header.count == 4 else { throw ProxyCoreError.invalidHandshake }
                guard header[1] == 0x01 else { throw ProxyCoreError.unsupportedCommand }
                let addrType = header[3]
                let targetHost: String
                switch addrType {
                case 0x01:
                    let addr = try await receiveExactly(connection: connection, length: 4)
                    targetHost = addr.map { String($0) }.joined(separator: ".")
                case 0x03:
                    let len = try await receiveExactly(connection: connection, length: 1)
                    let name = try await receiveExactly(connection: connection, length: Int(len[0]))
                    targetHost = String(decoding: name, as: UTF8.self)
                default:
                    throw ProxyCoreError.unsupportedCommand
                }
                let portData = try await receiveExactly(connection: connection, length: 2)
                let port = UInt16(portData[0]) << 8 | UInt16(portData[1])
                let upstream = try await connectUpstream(targetHost: targetHost, targetPort: port)
                try await send(connection: connection, data: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                try await relayBidirectional(client: connection, upstream: upstream)
            } catch {
                stats.lastError = error.localizedDescription
                AppLogger.shared.record("SOCKS error: \(error)", level: .error, category: .core)
                connection.cancel()
            }
            stats.activeConnections -= 1
        }
    }

    private func handleHTTP(connection: NWConnection) {
        connection.start(queue: .global())
        Task {
            do {
                stats.activeConnections += 1
                let head = try await receiveUntilDoubleCRLF(connection: connection)
                let headString = String(decoding: head, as: UTF8.self)
                if headString.uppercased().hasPrefix("CONNECT") {
                    let parts = headString.components(separatedBy: " ")
                    guard parts.count > 1 else { throw ProxyCoreError.invalidHandshake }
                    let hostPort = parts[1]
                    let hp = hostPort.split(separator: ":")
                    guard hp.count == 2, let port = UInt16(hp[1]) else { throw ProxyCoreError.invalidHandshake }
                    let upstream = try await connectUpstream(targetHost: String(hp[0]), targetPort: port)
                    let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                    try await send(connection: connection, data: response.data(using: .utf8)!)
                    try await relayBidirectional(client: connection, upstream: upstream)
                } else {
                    let response = "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n"
                    try await send(connection: connection, data: response.data(using: .utf8)!)
                }
            } catch {
                stats.lastError = error.localizedDescription
                AppLogger.shared.record("HTTP proxy error: \(error)", level: .error, category: .core)
                connection.cancel()
            }
            stats.activeConnections -= 1
        }
    }

    private func connectUpstream(targetHost: String, targetPort: UInt16) async throws -> NWConnection {
        guard let node = activeNode else {
            throw ProxyCoreError.invalidHandshake
        }
        let upstream = NWConnection(host: NWEndpoint.Host(node.host), port: NWEndpoint.Port(rawValue: node.port)!, using: .tcp)
        upstream.start(queue: .global())
        switch node.type {
        case .socks5:
            let password = node.passwordRef.flatMap { KeychainStore.load(account: $0) }
            try await performSocksClientHandshake(connection: upstream, targetHost: targetHost, targetPort: targetPort, username: node.username, password: password)
        case .http:
            let password = node.passwordRef.flatMap { KeychainStore.load(account: $0) }
            try await performHTTPConnect(connection: upstream, targetHost: targetHost, targetPort: targetPort, username: node.username, password: password)
        }
        return upstream
    }

    private func performSocksClientHandshake(connection: NWConnection, targetHost: String, targetPort: UInt16, username: String?, password: String?) async throws {
        if let username, let password {
            try await send(connection: connection, data: Data([0x05, 0x01, 0x02]))
        } else {
            try await send(connection: connection, data: Data([0x05, 0x01, 0x00]))
        }
        let response = try await receiveExactly(connection: connection, length: 2)
        if response.count == 2, response[1] == 0x02, let username, let password {
            var auth = Data([0x01, UInt8(username.utf8.count)])
            auth.append(Data(username.utf8))
            auth.append(UInt8(password.utf8.count))
            auth.append(Data(password.utf8))
            try await send(connection: connection, data: auth)
            _ = try await receiveExactly(connection: connection, length: 2)
        }
        var request = Data([0x05, 0x01, 0x00, 0x03])
        let hostData = Data(targetHost.utf8)
        request.append(UInt8(hostData.count))
        request.append(hostData)
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 0xFF))
        try await send(connection: connection, data: request)
        _ = try await receiveExactly(connection: connection, length: 10)
    }

    private func performHTTPConnect(connection: NWConnection, targetHost: String, targetPort: UInt16, username: String?, password: String?) async throws {
        var request = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n"
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        try await send(connection: connection, data: request.data(using: .utf8)!)
        _ = try await receiveUntilDoubleCRLF(connection: connection)
    }

    private func relayBidirectional(client: NWConnection, upstream: NWConnection) async throws {
        async let forward = relay(from: client, to: upstream, countAsUpload: true)
        async let backward = relay(from: upstream, to: client, countAsUpload: false)
        _ = try await (forward, backward)
        client.cancel()
        upstream.cancel()
    }

    private func relay(from: NWConnection, to: NWConnection, countAsUpload: Bool) async throws {
        while true {
            let data = try await receive(connection: from)
            if data.isEmpty { break }
            try await send(connection: to, data: data)
            if countAsUpload {
                stats.uploadBytes += UInt64(data.count)
            } else {
                stats.downloadBytes += UInt64(data.count)
            }
        }
    }

    private func receive(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func receiveExactly(connection: NWConnection, length: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            let data = try await receive(connection: connection)
            if data.isEmpty { break }
            buffer.append(data)
        }
        return buffer
    }

    private func receiveUntilDoubleCRLF(connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let data = try await receive(connection: connection)
            if data.isEmpty { break }
            buffer.append(data)
            if let range = buffer.range(of: Data([13, 10, 13, 10])) {
                return buffer.subdata(in: 0..<range.upperBound)
            }
        }
        return buffer
    }

    private func send(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}
