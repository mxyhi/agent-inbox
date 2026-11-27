import Foundation

/// Per-client install instructions for the setup window. One entry per popular MCP client; adding a
/// client is one array element. Every client spawns the same `Tic --mcp`, so the only thing that
/// varies is where the snippet goes (a config file to paste into, or a CLI command to run) and its
/// format (JSON `mcpServers`, VS Code / Zed shapes, or Codex TOML).
struct MCPClient: Identifiable, Sendable {
    enum Install: Sendable {
        case configFile(path: String)   // snippet is pasted into this file (path may start with ~)
        case command                     // snippet is a shell command to run
    }

    let id: String            // also the display name
    let detail: String        // the one-line "how"
    let install: Install
    let snippet: String
    /// A one-click "Add to <app>" URL, for clients that support an install deeplink.
    var deeplink: String? = nil

    var name: String { id }
    var configPath: String? { if case let .configFile(path) = install { return path } else { return nil } }
}

enum MCPClients {
    /// Percent-encodes a query value, escaping everything but the URL-unreserved set (so base64
    /// `+`/`/`/`=` and JSON punctuation survive the round trip).
    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// All clients, with the live executable path baked into each snippet.
    static func all(executablePath exe: String) -> [MCPClient] {
        let mcpServers = """
        {
          "mcpServers": {
            "tic": {
              "command": "\(exe)",
              "args": ["--mcp"]
            }
          }
        }
        """

        // One-click install URLs. Cursor takes base64 of the inner server config; VS Code takes the
        // URL-encoded server object. Both open the app and pre-fill the config.
        let cursorConfig = "{\"command\":\"\(exe)\",\"args\":[\"--mcp\"]}"
        let cursorLink = "cursor://anysphere.cursor-deeplink/mcp/install?name=tic&config="
            + urlEncode(Data(cursorConfig.utf8).base64EncodedString())
        let vscodeObject = "{\"name\":\"tic\",\"command\":\"\(exe)\",\"args\":[\"--mcp\"]}"
        let vscodeLink = "vscode:mcp/install?" + urlEncode(vscodeObject)

        return [
            MCPClient(id: "Claude Desktop",
                detail: "Add this to your Claude Desktop config, then restart Claude.",
                install: .configFile(path: "~/Library/Application Support/Claude/claude_desktop_config.json"),
                snippet: mcpServers),

            MCPClient(id: "Claude Code",
                detail: "Run this once in your terminal.",
                install: .command,
                snippet: "claude mcp add tic -- \"\(exe)\" --mcp"),

            MCPClient(id: "Cursor",
                detail: "Click Add to Cursor, or paste this into Cursor's MCP config.",
                install: .configFile(path: "~/.cursor/mcp.json"),
                snippet: mcpServers, deeplink: cursorLink),

            MCPClient(id: "VS Code",
                detail: "Click Add to VS Code, or run this once in a terminal.",
                install: .command,
                snippet: "code --add-mcp '{\"name\":\"tic\",\"command\":\"\(exe)\",\"args\":[\"--mcp\"]}'",
                deeplink: vscodeLink),

            MCPClient(id: "Codex CLI",
                detail: "Add this block to your Codex config.",
                install: .configFile(path: "~/.codex/config.toml"),
                snippet: """
                [mcp_servers.tic]
                command = "\(exe)"
                args = ["--mcp"]
                """),

            MCPClient(id: "Gemini CLI",
                detail: "Add this to your Gemini CLI settings.",
                install: .configFile(path: "~/.gemini/settings.json"),
                snippet: mcpServers),

            MCPClient(id: "Windsurf",
                detail: "Add this to Windsurf's MCP config, then refresh.",
                install: .configFile(path: "~/.codeium/windsurf/mcp_config.json"),
                snippet: mcpServers),

            MCPClient(id: "Zed",
                detail: "Add this to your Zed settings.",
                install: .configFile(path: "~/.config/zed/settings.json"),
                snippet: """
                {
                  "context_servers": {
                    "tic": {
                      "command": { "path": "\(exe)", "args": ["--mcp"] }
                    }
                  }
                }
                """),

            MCPClient(id: "Other (JSON)",
                detail: "Most clients accept this standard MCP server block.",
                install: .command,
                snippet: mcpServers),
        ]
    }
}
