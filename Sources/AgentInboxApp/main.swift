import Foundation

// `agent-inbox --mcp` is the stdio bridge that MCP clients spawn (see `MCPProxy`); anything else is the app.
// A `main.swift` instead of `@main` so the flag is checked before AppKit ever starts.
if CommandLine.arguments.dropFirst().contains("--mcp") {
    MCPProxy.run()
} else {
    AgentInboxApp.main()
}
