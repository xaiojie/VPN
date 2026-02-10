import Foundation
import Network
import Subscription
import Persistence

struct NodeTester {
    static func measure(node: ProxyNode) async -> Int? {
        let start = Date()
        do {
            let connection = NWConnection(host: NWEndpoint.Host(node.host), port: NWEndpoint.Port(rawValue: node.port)!, using: .tcp)
            connection.start(queue: .global())
            let password = node.passwordRef.flatMap { KeychainStore.load(account: $0) }
            switch node.type {
            case .socks5:
                try await socksHandshake(connection: connection, targetHost: "example.com", targetPort: 80, username: node.username, password: password)
            case .http:
                try await httpConnect(connection: connection, targetHost: "example.com", targetPort: 80, username: node.username, password: password)
            }
            let head = "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
            try await send(connection: connection, data: head.data(using: .utf8)!)
            _ = try await receive(connection: connection)
            connection.cancel()
            return Int(Date().timeIntervalSince(start) * 1000)
        } catch {
            return nil
        }
    }

    private static func socksHandshake(connection: NWConnection, targetHost: String, targetPort: UInt16, username: String?, password: String?) async throws {
        if username != nil && password != nil {
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

    private static func httpConnect(connection: NWConnection, targetHost: String, targetPort: UInt16, username: String?, password: String?) async throws {
        var request = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n"
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        try await send(connection: connection, data: request.data(using: .utf8)!)
        _ = try await receive(connection: connection)
    }

    private static func receive(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private static func receiveExactly(connection: NWConnection, length: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            let data = try await receive(connection: connection)
            if data.isEmpty { break }
            buffer.append(data)
        }
        return buffer
    }

    private static func send(connection: NWConnection, data: Data) async throws {
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
