import Foundation
import MCP
import Network
import Testing
@testable import AgentInboxApp

/// The socket end to end: an SDK `Client` connects to `MCPService` over the Unix socket, completes
/// the handshake, lists tools, and its disconnect is noticed (the session count drops).
@Suite("MCP service")
struct MCPServiceTests {
    @Test("a client completes the handshake over the Unix socket, and leaving is noticed")
    func handshakeOverSocket() async throws {
        let path = NSTemporaryDirectory() + "tic-\(UUID().uuidString.prefix(8)).sock"
        let service = MCPService(database: try AppDatabase.makeInMemory(), socketPath: path)
        try service.start()
        defer { service.stop() }

        let client = Client(name: "test", version: "0")
        let transport = NetworkTransport(
            connection: NWConnection(to: .unix(path: path), using: .tcp),
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .init(enabled: false)
        )
        let handshake = try await client.connect(transport: transport)
        #expect(handshake.serverInfo.name == "Tic")
        #expect(service.connectionCount == 1)

        let listed = try await client.listTools()
        #expect(listed.tools.contains { $0.name == "create_note" })
        #expect(listed.tools.contains { $0.name == "get_note" })

        await client.disconnect()
        for _ in 0..<40 where service.connectionCount != 0 {   // EOF reaches the server asynchronously
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(service.connectionCount == 0)
    }

    @Test("stop removes the socket so a proxy fails fast")
    func stopRemovesSocket() throws {
        let path = NSTemporaryDirectory() + "tic-\(UUID().uuidString.prefix(8)).sock"
        let service = MCPService(database: try AppDatabase.makeInMemory(), socketPath: path)
        try service.start()
        #expect(FileManager.default.fileExists(atPath: path))
        service.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
