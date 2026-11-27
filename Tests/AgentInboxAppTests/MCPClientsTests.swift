import Testing
@testable import AgentInboxApp

@Suite("MCP client instructions")
struct MCPClientsTests {
    @Test("every client embeds the live executable path and launches with --mcp")
    func snippetsCarryTheExecutable() {
        let exe = "/Applications/Tic.app/Contents/MacOS/Tic"
        let clients = MCPClients.all(executablePath: exe)
        #expect(clients.contains { $0.name == "Claude Desktop" })
        #expect(clients.contains { $0.name == "Claude Code" })
        for client in clients {
            #expect(client.snippet.contains(exe), "\(client.name) is missing the executable path")
            #expect(client.snippet.contains("--mcp"), "\(client.name) is missing the --mcp flag")
        }
    }

    @Test("file-based clients name a config path; command-based ones don't")
    func installKinds() {
        let clients = MCPClients.all(executablePath: "/x/Tic")
        let claudeDesktop = clients.first { $0.name == "Claude Desktop" }
        #expect(claudeDesktop?.configPath?.contains("claude_desktop_config.json") == true)
        let claudeCode = clients.first { $0.name == "Claude Code" }
        #expect(claudeCode?.configPath == nil)                       // CLI install
        #expect(claudeCode?.snippet.hasPrefix("claude mcp add agent-inbox") == true)
    }

    @Test("Cursor and VS Code offer install deeplinks; file clients don't")
    func deeplinks() {
        let clients = MCPClients.all(executablePath: "/Applications/Tic.app/Contents/MacOS/Tic")
        let cursor = clients.first { $0.name == "Cursor" }
        #expect(cursor?.deeplink?.hasPrefix("cursor://") == true)
        #expect(cursor?.deeplink?.contains("config=") == true)
        let vscode = clients.first { $0.name == "VS Code" }
        #expect(vscode?.deeplink?.hasPrefix("vscode:mcp/install?") == true)
        #expect(clients.first { $0.name == "Claude Desktop" }?.deeplink == nil)
    }
}
